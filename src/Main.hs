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
import Data.Aeson
import Control.Monad (mzero)
import Settings

import qualified Data.ByteString.Lazy.Char8 as BL

data CrawlRequest = CrawlRequest
    { url :: String }

instance FromJSON CrawlRequest where
    parseJSON (Object v) = CrawlRequest <$> v .: "url"
    parseJSON _ = mzero

instance ToJSON CrawlRequest where
    toJSON (CrawlRequest url) =
        object ["url" .= url]

data CrawlResponse = CrawlResponse
    { originalRequest :: CrawlRequest
    , body :: Text
    , code :: Int }

instance ToJSON CrawlResponse where
    toJSON (CrawlResponse originalRequest body code) =
        object ["body" .= body, "code" .= code, "request" .= originalRequest]

main :: IO ()
main = do
    parallel_ $ replicate 10 createConsumer
    stopGlobalPool

command :: IO (String)
command = do
    args <- getArgs
    case args of
        (cmd:[]) -> return cmd
        otherwise -> error "usage: akkorokamui [command]"

createConsumer :: IO ()
createConsumer = do
    putStrLn $ "start"
    conn <- openConnection "127.0.0.1" "/" "guest" "guest"
    chan <- openChannel conn

    setupQueues chan

    getLine -- wait for keypress
    closeConnection conn
    putStrLn "connection closed"

setupQueues chan = do
    declareQueue chan newQueue { queueName = processQueueName }
    declareQueue chan newQueue { queueName = resultsQueueName }
    declareExchange chan newExchange {exchangeName = msgExchangeName, exchangeType = "topic"}
    bindQueue chan processQueueName msgExchangeName processExchangeKey
    bindQueue chan resultsQueueName msgExchangeName resultsExchangeKey
    consumeMsgs chan processQueueName Ack consumerCallback
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

    handleCrawlRequest env $ parseCrawlRequest message
  where
    message = msgBody msg

handleCrawlRequest env Nothing = do
    putStrLn "bad request"
    ackEnv env

handleCrawlRequest env (Just crawlRequest) = do
    (_, rsp) <- browse $ do
        --setProxy . fromJust $ parseProxy "127.0.0.1:8118"
        setAllowRedirects True
        setOutHandler $ const (return ())
        request $ createRequest crawlRequest

    putStrLn $ rspBody rsp

    publishResult env crawlRequest rsp

    ackEnv env

parseRequestMethod :: String -> RequestMethod
parseRequestMethod strMethod =
    case strMethod of
        "POST" -> POST
        otherwise -> GET

createRequest :: CrawlRequest -> Request String
createRequest crawlRequest =
    Request
        (fromJust $ parseURI $ url crawlRequest)
        (parseRequestMethod "GET")
        []
        "Body"

parseCrawlRequest :: BL.ByteString -> Maybe CrawlRequest
parseCrawlRequest msg = decode msg :: Maybe CrawlRequest

createCrawlResponse :: CrawlRequest -> Response String -> CrawlResponse
createCrawlResponse crawlRequest response =
    CrawlResponse
        { originalRequest = crawlRequest
        , body = pack $ rspBody response
        , code = responseCode }
  where
    (n1, n2, n3) = rspCode response
    responseCode = read $ foldl (++) "" $ fmap show [n1, n2, n3] :: Int

publishResult :: Envelope -> CrawlRequest -> Response String -> IO ()
publishResult env crawlRequest response = do
    publishMsg
        (envChannel env)
        msgExchangeName
        resultsExchangeKey
        (newMsg
            { msgBody = encode $ createCrawlResponse crawlRequest response
            , msgDeliveryMode = Just NonPersistent
            }
        )
  where
    processQueueName = settingsProcessQueue settings
    resultsQueueName = settingsResultsQueue settings
    msgExchangeName = settingsExchange settings
    processExchangeKey = settingsProcessExchangeKey settings
    resultsExchangeKey = settingsResultsExchangeKey settings
