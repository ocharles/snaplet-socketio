{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
module Snap.Snaplet.SocketIO
  ( SocketIO
  , init

  , emit
  , on
  ) where

import Prelude hiding (init)

import Data.Char (intToDigit)
import Blaze.ByteString.Builder (Builder, toLazyByteString)
import Control.Applicative
import Control.Eff ((:>))
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans.Writer (WriterT)
import Data.Aeson ((.=), (.:))
import Data.Foldable (asum)
import Data.Traversable (forM)
import Data.HashMap.Strict (HashMap)
import Data.Monoid ((<>), mempty)
import Data.Text (Text)
import Data.Typeable (Typeable)

import qualified Blaze.ByteString.Builder as Builder
import qualified Blaze.ByteString.Builder.ByteString as Builder
import qualified Blaze.ByteString.Builder.Char8 as Builder
import qualified Control.Eff as Effect
import qualified Control.Eff.Lift as Effect
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.Attoparsec.Char8 as AttoparsecC8
import qualified Data.Attoparsec.Lazy as Attoparsec
import qualified Data.ByteString.Lazy as LBS
import qualified Data.HashMap.Strict as HashMap
import qualified Network.WebSockets as WS
import qualified Network.WebSockets.Snap as WS
import qualified Snap as Snap
import qualified Snap.Snaplet as Snap


--------------------------------------------------------------------------------
data SocketIO = SocketIO
  { eventRouter :: HashMap Text Subscriber
  , onConnection :: WS.Connection -> [WS.Connection] -> IO ()
  }


--------------------------------------------------------------------------------
init :: Effect.Eff (Listen :> Emit :> Effect.Lift IO :> ()) () -> Snap.SnapletInit b SocketIO
init router = Snap.makeSnaplet "socketio" "SocketIO" Nothing $ do
  Snap.addRoutes [ ("/:version", handShake)
                 , ("/:version/websocket/:session", webSocketHandler)
                 ]

  let subscribed = buildRoutingTable router

  SocketIO
    <$> liftIO (Effect.runLift (noopEmit subscribed))
    <*> pure (\c cs -> Effect.runLift (runEmitter c cs (void subscribed)))


--------------------------------------------------------------------------------
data Message
  = Disconnect
  | Connect
  | Heartbeat
  | Message
  | JSON
  | Event Text [Aeson.Value]
  | Ack
  | Error
  | Noop

encodeMessage :: Message -> Builder
decodeMessage :: LBS.ByteString -> Maybe Message

--------------------------------------------------------------------------------
encodeMessage (Event name args) =
  let prefix = Builder.fromString "5:::"
      event = Aeson.object [ "name" .= name
                           , "args" .= args
                           ]
  in prefix <> Builder.fromLazyByteString (Aeson.encode event)

encodeMessage Connect =
  Builder.fromString "1:::"


--------------------------------------------------------------------------------
decodeMessage = Attoparsec.maybeResult . Attoparsec.parse messageParser
 where
  messageParser = asum
    [ do let eventFromJson = Aeson.withObject "Event" $ \o ->
               Event <$> o .: "name" <*> o .: "args"
         Just event <- Aeson.parseMaybe eventFromJson
                         <$> (prefixParser 5 >> Aeson.json)
         return event
    ]

  prefixParser n = do
    AttoparsecC8.char (intToDigit n)
    AttoparsecC8.char ':'
    Attoparsec.option () (void $ Attoparsec.many1 AttoparsecC8.digit)
    Attoparsec.option Nothing (Just <$> AttoparsecC8.char '+')
    AttoparsecC8.char ':'
    AttoparsecC8.char ':'

--------------------------------------------------------------------------------
handShake :: Snap.Handler b SocketIO ()
handShake = accessControl $ Snap.writeText "4d4f185e96a7b:15:10:websocket"


--------------------------------------------------------------------------------
webSocketHandler :: Snap.Handler b SocketIO ()
webSocketHandler = accessControl $ do
  router <- asks eventRouter
  connectionHandler <- asks onConnection

  WS.runWebSocketsSnap $ \pendingConnection -> void $ do
    c <- WS.acceptRequest pendingConnection

    WS.sendTextData c . Builder.toLazyByteString $
      encodeMessage $ Connect

    connectionHandler c []

    forever $ do
      m <- WS.receiveDataMessage c

      Just message <- return $ case m of
            WS.Text encodedText -> decodeMessage encodedText

      case message of
        Event name args ->
          maybe
            (return ())
            (\action -> Effect.runLift $ runEmitter c [] $ action args)
            (HashMap.lookup name router)


--------------------------------------------------------------------------------
accessControl :: Snap.MonadSnap m => m a -> m a
accessControl =
  (Snap.modifyResponse (Snap.setHeader "Access-Control-Allow-Origin" "*") >>)


--------------------------------------------------------------------------------
data Emit k = Emit Text [Aeson.Value] k
  deriving (Functor, Typeable)

emit :: (Effect.Member Emit r, Aeson.ToJSON a) => Text -> a -> Effect.Eff r ()
emit event value = emitValues event [ Aeson.toJSON value ]

emitValues :: (Effect.Member Emit r) => Text -> [Aeson.Value] -> Effect.Eff r ()
emitValues event values =
  Effect.send $ \k -> Effect.inj $ Emit event values (k ())

runEmitter
  :: Effect.SetMember Effect.Lift (Effect.Lift IO) r
  => WS.Connection -> [WS.Connection] -> Effect.Eff (Emit :> r) a -> Effect.Eff r a
runEmitter c pool = loop . Effect.admin
 where
  loop (Effect.Val x) = return x
  loop (Effect.E u) = Effect.handleRelay u loop $ \eff ->
    case eff of
      Emit event args k -> do
        Effect.lift . WS.sendTextData c . Builder.toLazyByteString $
          encodeMessage $ Event event args

        loop k

noopEmit :: Effect.Eff (Emit :> r) a -> Effect.Eff r a
noopEmit = loop . Effect.admin
 where
  loop (Effect.Val x) = return x
  loop (Effect.E u) = Effect.handleRelay u loop $
    \(Emit event args k) -> loop k


--------------------------------------------------------------------------------
type Emitter = Effect.Eff (Emit :> Effect.Lift IO :> ()) ()

type Subscriber = [Aeson.Value] -> Emitter

data Listen k = Listen Text Subscriber k
  deriving (Functor, Typeable)

on
  :: Aeson.FromJSON a
  => Effect.Member Listen r => Text -> (a -> Emitter) -> Effect.Eff r ()
on event f =
  let f' [x] = case Aeson.fromJSON x of
                 Aeson.Success v -> f v
                 _ -> return () -- TODO We should probably do more here - exception?
      f' _   = return () -- TODO We should probably do more here - exception?
  in Effect.send $ \k -> Effect.inj $ Listen event f' (k ())

buildRoutingTable
  :: Effect.Eff (Listen :> r) a -> Effect.Eff r (HashMap Text Subscriber)
buildRoutingTable = loop HashMap.empty . Effect.admin
 where
  loop t (Effect.Val _) = return t
  loop t (Effect.E u) = Effect.handleRelay u (loop t) $
    \(Listen event subscriber k) ->
      loop (HashMap.insert event subscriber t) k
