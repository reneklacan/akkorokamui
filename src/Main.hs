{-# OPTIONS -XOverloadedStrings #-}

import Network.AMQP
import Control.Concurrent.ParallelIO (parallel_, stopGlobalPool)
import System.Environment (getArgs)
import Control.Applicative ((<$>))
import Data.Maybe (fromJust)
import Network.Browser
import Network.HTTP
--import Network.HTTP.Proxy (parseProxy)
import Data.Text hiding (replicate, foldl)
import Network.URI (parseURI)
import Data.Aeson hiding (Result)
import Control.Monad (mzero)
import Settings

import qualified Data.ByteString.Lazy.Char8 as BL

data Job = Job
    { jobUrl :: String }

instance FromJSON Job where
    parseJSON (Object v) = Job <$> v .: "url"
    parseJSON _ = mzero

instance ToJSON Job where
    toJSON (Job url) =
        object ["url" .= url]

data Result = Result
    { resultJob :: Job
    , resultBody :: Text
    , resultCode :: Int }

instance ToJSON Result where
    toJSON (Result job body code) =
        object ["body" .= body, "code" .= code, "job" .= job]

main :: IO ()
main = do
    parallel_ $ replicate 10 createConsumer
    stopGlobalPool

command :: IO (String)
command = do
    args <- getArgs
    case args of
        (cmd:[]) -> return cmd
        _ -> error "usage: akkorokamui [command]"

createConsumer :: IO ()
createConsumer = do
    putStrLn $ "start"
    conn <- openConnection "127.0.0.1" "/" "guest" "guest"
    chan <- openChannel conn

    setupQueues chan

    _ <- getLine -- wait for keypress
    closeConnection conn
    putStrLn "connection closed"

setupQueues :: Channel -> IO ()
setupQueues chan = do
    _ <- declareQueue chan newQueue { queueName = processQueueName }
    _ <- declareQueue chan newQueue { queueName = resultsQueueName }
    declareExchange chan newExchange {exchangeName = msgExchangeName, exchangeType = "topic"}
    bindQueue chan processQueueName msgExchangeName processExchangeKey
    bindQueue chan resultsQueueName msgExchangeName resultsExchangeKey
    _ <- consumeMsgs chan processQueueName Ack consumerCallback
    return ()
  where
    processQueueName = settingsProcessQueue settings
    resultsQueueName = settingsResultsQueue settings
    msgExchangeName = settingsExchange settings
    processExchangeKey = settingsProcessExchangeKey settings
    resultsExchangeKey = settingsResultsExchangeKey settings

consumerCallback :: (Message, Envelope) -> IO ()
consumerCallback (msg, env) = do
    putStrLn $ "started receiving from "
    putStrLn $ "received: " ++ (BL.unpack $ msgBody msg)

    handleJob env $ parseJob message
  where
    message = msgBody msg

handleJob :: Envelope -> Maybe Job -> IO ()
handleJob env Nothing = do
    putStrLn "bad request"
    ackEnv env
handleJob env (Just job) = do
    (_, rsp) <- browse $ do
        --setProxy . fromJust $ parseProxy "127.0.0.1:8118"
        setAllowRedirects True
        setOutHandler $ const (return ())
        request $ createJob job

    publishResult env job rsp

    ackEnv env

parseRequestMethod :: String -> RequestMethod
parseRequestMethod strMethod =
    case strMethod of
        "POST" -> POST
        _ -> GET

createJob :: Job -> Request String
createJob job =
    Request
        (fromJust $ parseURI $ jobUrl job)
        (parseRequestMethod "GET")
        []
        "Body"

parseJob :: BL.ByteString -> Maybe Job
parseJob msg = decode msg :: Maybe Job

createResult :: Job -> Response String -> Result
createResult job response =
    Result
        { resultJob = job
        , resultBody = pack $ rspBody response
        , resultCode = responseCode }
  where
    (n1, n2, n3) = rspCode response
    responseCode = read $ foldl (++) "" $ fmap show [n1, n2, n3] :: Int

publishResult :: Envelope -> Job -> Response String -> IO ()
publishResult env job response = do
    publishMsg
        (envChannel env)
        msgExchangeName
        resultsExchangeKey
        (newMsg
            { msgBody = encode $ createResult job response
            , msgDeliveryMode = Just NonPersistent
            }
        )
  where
    msgExchangeName = settingsExchange settings
    resultsExchangeKey = settingsResultsExchangeKey settings
