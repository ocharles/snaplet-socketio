{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
module Snap.Snaplet.SocketIO
  ( -- * Socket.io Snaplet
    SocketIO
  , init
  , RoutingTable

    -- * Socket.io Handlers
  , EventHandler
  , emit, on, on_
  , Connection
  , ConnectionId
  , getConnectionId
  , getOutputStream

    -- * Socket.io Protoc
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
import Control.Monad (forever, mzero, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (MonadReader, ask, asks)
import Control.Monad.State (MonadState, modify)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe (MaybeT, runMaybeT)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Control.Monad.Trans.State (State, execState)
import Control.Monad.Trans.Writer (WriterT)
import Data.Aeson ((.=), (.:))
import Data.Char (intToDigit)
import Data.Foldable (asum)
import Data.HashMap.Strict (HashMap)
import Data.Monoid ((<>), mempty)
import Data.Text (Text)
import Data.Traversable (forM)
import Data.Typeable (Typeable)
import Data.Unique
import System.Timeout (timeout)

import qualified Blaze.ByteString.Builder as Builder
import qualified Blaze.ByteString.Builder.ByteString as Builder
import qualified Blaze.ByteString.Builder.Char8 as Builder
import qualified Control.Concurrent.Async as Async
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
import qualified Pipes as Pipes
import qualified Pipes.Concurrent as Pipes
import qualified Snap as Snap
import qualified Snap.Snaplet as Snap

--------------------------------------------------------------------------------
data SocketIO = SocketIO


--------------------------------------------------------------------------------
init socketIOHandler =
  Snap.makeSnaplet "socketio" "SocketIO" Nothing $ do
    Snap.addRoutes [ ("/:version", handShake)
                   , ("/:version/websocket/:session",  Snap.withTop' id $ wrapSocketIOHandler socketIOHandler)
                   ]

    return SocketIO


--------------------------------------------------------------------------------
data Message
  = Disconnect
  | Connect
  | Heartbeat
  | Message
  | JSON
  | Event { eventName :: Text, eventPayload :: [Aeson.Value] }
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
wrapSocketIOHandler h = do
  initialRoutingTable <- buildRoutingTable <$> h

  WS.runWebSocketsSnap $ \pendingConnection -> void $ do
    c <- WS.acceptRequest pendingConnection

    WS.sendTextData c $ encodeMessage $ Connect

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

    connectionId <- newUnique
    (output, input) <- Pipes.spawn Pipes.Unbounded

    let connection = Connection output connectionId

    _ <- Async.async $ do
      Pipes.runEffect $ Pipes.for (Pipes.fromInput input) $
        liftIO . WS.sendTextData c . encodeMessage

    let loop tbl@(RoutingTable routingTable) = do
          m <- WS.receive c
          case m of
            WS.ControlMessage (WS.Close _) -> do
              Async.cancel heartbeat
              error "Client closed connection"

            WS.ControlMessage (WS.Ping pl) -> do
              WS.send c (WS.ControlMessage (WS.Pong pl))
              loop tbl

            WS.ControlMessage (WS.Pong _) ->
              loop tbl

            WS.DataMessage (WS.Text (decodeMessage -> Just message)) ->
              case message of
                Heartbeat -> do
                  putMVar heartbeatAcknowledged ()
                  loop tbl

                Event name args -> do
                  maybe
                    (return ())
                    (\action -> void $ runReaderT (runMaybeT (action args)) connection)
                    (HashMap.lookup name routingTable)

                  loop tbl

            _ -> error $ "Unknown message: " ++ show m

    loop initialRoutingTable

--------------------------------------------------------------------------------
newtype RoutingTable =
  RoutingTable (HashMap.HashMap Text ([Aeson.Value] -> MaybeT EventHandler ()))

--------------------------------------------------------------------------------
on
  :: MonadState RoutingTable m
  => Aeson.FromJSON a => Text -> (a -> EventHandler ()) -> m ()
on eventName handler =
  let eventHandler [x] =
        case Aeson.fromJSON x of
          Aeson.Success v -> lift (handler v)
          Aeson.Error r -> mzero
      eventHandler _ = mzero

  in modify $ \(RoutingTable routes) -> RoutingTable $
      HashMap.insertWith (\new old json -> old json <|> new json)
                         eventName eventHandler routes

--------------------------------------------------------------------------------
on_ :: MonadState RoutingTable m => Text -> EventHandler () -> m ()
on_ eventName handler = modify $ \(RoutingTable routes) -> RoutingTable $
  HashMap.insertWith (\new old json -> old json <|> new json)
                     eventName (\_ -> lift handler) routes

--------------------------------------------------------------------------------
type ConnectionId = Unique

data Connection = Connection { connectionOutputStream :: Pipes.Output Message
                              , connectionId :: ConnectionId
                              }

type EventHandler = ReaderT Connection IO

emit :: Aeson.ToJSON a => Text -> a -> EventHandler ()
emit evtName payload = do
  connection <- getOutputStream
  void $ liftIO $ Pipes.atomically $
    Pipes.send connection (Event evtName [ Aeson.toJSON payload ])

getOutputStream :: MonadReader Connection m => m (Pipes.Output Message)
getOutputStream = asks connectionOutputStream

getConnectionId :: MonadReader Connection m => m ConnectionId
getConnectionId = asks connectionId

--------------------------------------------------------------------------------
buildRoutingTable
  :: State RoutingTable a -> RoutingTable
buildRoutingTable = flip execState (RoutingTable HashMap.empty)

--------------------------------------------------------------------------------
heartbeatPeriod :: Int
heartbeatPeriod = 60
