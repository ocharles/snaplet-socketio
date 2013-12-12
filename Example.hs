{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import Control.Applicative
import Control.Eff
import Control.Eff.Lift
import Control.Lens.TH

import qualified Data.Aeson as Aeson
import qualified Snap.Http.Server.Config as Snap
import qualified Snap.Snaplet as Snap
import qualified Snap.Snaplet.SocketIO as SocketIO
import qualified Snap.Util.FileServe as Snap

data App = App { _socketIO :: Snap.Snaplet SocketIO.SocketIO }
makeLenses ''App

initApp = Snap.makeSnaplet "app" "app" Nothing $ do
  Snap.addRoutes [ ("/socket.io.js", Snap.serveFile "node_modules/socket.io-client/dist/socket.io.js")
                 , ("/", Snap.serveFile "example.html")
                 ]
  App <$> Snap.nestSnaplet "socket.io" socketIO (SocketIO.init connectionHandler)


connectionHandler = do
  SocketIO.emit "news" (Aeson.object [ "foo" Aeson..= ("bar" :: String) ])

  SocketIO.on "my other event" $ \v ->
    lift (print (v :: Aeson.Value))


main :: IO ()
main = Snap.serveSnaplet Snap.defaultConfig initApp
