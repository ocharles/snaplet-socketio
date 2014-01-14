{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
module Snap.Snaplet.SocketIO
  ( SocketIO
  , init
  , Listen
  , Emit, Emitter
  , emit
  , on
  , Message(..)
  , encodeMessage
  , decodeMessage
  ) where

import Prelude hiding (init)

import Blaze.ByteString.Builder (Builder, toLazyByteString)
import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (putMVar, newEmptyMVar, takeMVar)
import Control.Eff ((:>))
import Control.Monad (forever, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans.Writer (WriterT)
import Data.Aeson ((.=), (.:))
import Data.Char (intToDigit)
import Data.Foldable (asum)
import Data.HashMap.Strict (HashMap)
import Data.Monoid ((<>), mempty)
import Data.Text (Text)
import Data.Traversable (forM)
import Data.Typeable (Typeable)
import System.Timeout (timeout)

import qualified Control.Concurrent.Async as Async
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
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
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
  deriving (Eq, Show)

encodeMessage :: Message -> LBS.ByteString
decodeMessage :: LBS.ByteString -> Maybe Message

--------------------------------------------------------------------------------
encodeMessage = Builder.toLazyByteString . go
  where
  go Connect =
    Builder.fromString "1::"

  go Heartbeat =
    Builder.fromString "2::"

  go (Event name args) =
    let prefix = Builder.fromString "5:::"
        event = Aeson.object [ "name" .= name
                             , "args" .= args
                             ]
    in prefix <> Builder.fromLazyByteString (Aeson.encode event)


--------------------------------------------------------------------------------
decodeMessage = Attoparsec.maybeResult . Attoparsec.parse messageParser
 where
  messageParser = asum
    [ do Connect <$ prefixParser 1

    , do Heartbeat <$ prefixParser 2

    , do let eventFromJson = Aeson.withObject "Event" $ \o ->
               Event <$> o .: "name" <*> o .: "args"
         Just event <- Aeson.parseMaybe eventFromJson
                         <$> (prefixParser 5 >> AttoparsecC8.char ':' >> Aeson.json)
         return event
    ]

  prefixParser n = do
    AttoparsecC8.char (intToDigit n)
    AttoparsecC8.char ':'
    Attoparsec.option () (void $ Attoparsec.many1 AttoparsecC8.digit)
    Attoparsec.option Nothing (Just <$> AttoparsecC8.char '+')
    AttoparsecC8.char ':'

--------------------------------------------------------------------------------
handShake :: Snap.Handler b SocketIO ()
handShake = do
  Snap.modifyResponse (Snap.setContentType "text/plain")
  Snap.writeText $ Text.intercalate ":"
    [ "4d4f185e96a7b"
    , Text.pack $ show heartbeatPeriod
    , "60"
    , "websocket"
    ]


--------------------------------------------------------------------------------
webSocketHandler :: Snap.Handler b SocketIO ()
webSocketHandler = do
  router <- asks eventRouter
  connectionHandler <- asks onConnection

  WS.runWebSocketsSnap $ \pendingConnection -> void $ do
    c <- WS.acceptRequest pendingConnection

    WS.sendTextData c $ encodeMessage $ Connect

    connectionHandler c []

    heartbeatAcknowledged <- newEmptyMVar

    heartbeat <- Async.async $
      let loop = do
            WS.sendTextData c $ encodeMessage Heartbeat
            heartbeatReceived <- timeout (heartbeatPeriod * 1000000) $
              takeMVar heartbeatAcknowledged

            case heartbeatReceived of
              Just _ -> do
                threadDelay (round $ (fromIntegral heartbeatPeriod * 1000000) / 2)
                loop

              Nothing -> error "Failed to receive a heartbeat. Terminating client"

      in loop

    forever $ do
      m <- WS.receive c

      case m of
        WS.ControlMessage (WS.Close _) -> do
          Async.cancel heartbeat
          error "Client closed connection"

        WS.ControlMessage (WS.Ping pl) ->
          WS.send c (WS.ControlMessage (WS.Pong pl))

        WS.ControlMessage (WS.Pong _) ->
          return ()

        WS.DataMessage (WS.Text (decodeMessage -> Just message)) ->
          case message of
            Heartbeat -> putMVar heartbeatAcknowledged ()

            Event name args ->
              maybe
                (return ())
                (\action -> Effect.runLift $ runEmitter c [] $ action args)
                (HashMap.lookup name router)

        _ -> error $ "Unknown message: " ++ show m


--------------------------------------------------------------------------------
data Emit k = Emit Text [Aeson.Value] k
            | Broadcast Text [Aeson.Value] k
  deriving (Functor, Typeable)

emit :: (Effect.Member Emit r, Aeson.ToJSON a) => Text -> a -> Effect.Eff r ()
emit event value = emitValues event [ Aeson.toJSON value ]

emitValues :: (Effect.Member Emit r) => Text -> [Aeson.Value] -> Effect.Eff r ()
emitValues event values =
  Effect.send $ \k -> Effect.inj $ Emit event values (k ())

broadcast :: (Effect.Member Emit r, Aeson.ToJSON a) => Text -> a -> Effect.Eff r ()
broadcast event value = broadcastValues event [ Aeson.toJSON value ]

broadcastValues :: (Effect.Member Emit r) => Text -> [Aeson.Value] -> Effect.Eff r ()
broadcastValues event values =
  Effect.send $ \k -> Effect.inj $ Broadcast event values (k ())

runEmitter
  :: Effect.SetMember Effect.Lift (Effect.Lift IO) r
  => WS.Connection -> [WS.Connection] -> Effect.Eff (Emit :> r) a -> Effect.Eff r a
runEmitter c pool = loop . Effect.admin
 where
  loop (Effect.Val x) = return x
  loop (Effect.E u) = Effect.handleRelay u loop $ \eff ->
    case eff of
      Emit event args k -> do
        Effect.lift . WS.sendTextData c $
          encodeMessage $ Event event args

        loop k

      Broadcast event args k -> do
        forM pool $ \c' ->
          Effect.lift . WS.sendTextData c' $
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
                 Aeson.Error r -> Effect.lift $ putStrLn $ concat
                  [ Text.unpack event, " called with invalid argument: "
                  , show $ Aeson.encode x -- TODO Decode this properly
                  , " Reason: " ++ show r
                  ]

      f' args = Effect.lift $ putStrLn $ (Text.unpack event) ++ " was expected to be\
                  \called with exactly one argument but was called with " ++
                  show (length args)

  in Effect.send $ \k -> Effect.inj $ Listen event f' (k ())

buildRoutingTable
  :: Effect.Eff (Listen :> r) a -> Effect.Eff r (HashMap Text Subscriber)
buildRoutingTable = loop HashMap.empty . Effect.admin
 where
  loop t (Effect.Val _) = return t
  loop t (Effect.E u) = Effect.handleRelay u (loop t) $
    \(Listen event subscriber k) ->
      loop (HashMap.insert event subscriber t) k


--------------------------------------------------------------------------------
heartbeatPeriod :: Int
heartbeatPeriod = 60
