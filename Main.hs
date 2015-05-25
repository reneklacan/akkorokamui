{-# OPTIONS -XOverloadedStrings #-}

import Network.AMQP
import Control.Concurrent.ParallelIO (parallel_, stopGlobalPool)
import System.Environment (getArgs)
import Control.Applicative ((<$>))
import Data.Maybe (fromJust)
import Network.Browser
import Network.HTTP
import Network.HTTP.Proxy (parseProxy)
import Data.Text hiding (replicate, foldl)
import Network.URI (parseURI)
import Data.Aeson
import Control.Monad (mzero)

import qualified Data.ByteString.Lazy.Char8 as BL

data Settings = Settings
    { settingsProcessQueue :: Text
    , settingsResultsQueue :: Text
    , settingsExchange :: Text
    , settingsProcessExchangeKey :: Text
    , settingsResultsExchangeKey :: Text }

data CrawlRequest = CrawlRequest
    { url :: String
    }

instance FromJSON CrawlRequest where
    parseJSON (Object v) = CrawlRequest <$> v .: "url"
    parseJSON _ = mzero

data CrawlResponse = CrawlResponse
    { body :: Text
    , code :: Int
    }

instance ToJSON CrawlResponse where
    toJSON (CrawlResponse body code) =
        object ["body" .= body, "code" .= code]

main :: IO ()
main = do
    parallel_ $ replicate 4 createConsumer
    stopGlobalPool

command :: IO (String)
command = do
    args <- getArgs
    case args of
        (cmd:[]) -> return cmd
        otherwise -> error "usage: akkorokamui [command]"

defaultSettings :: Settings
defaultSettings =
    Settings
        { settingsProcessQueue = "akkorokamui_new"
        , settingsResultsQueue = "akkorokamui_results"
        , settingsExchange = "akkorokamui_exchange"
        , settingsProcessExchangeKey = "new"
        , settingsResultsExchangeKey = "results" }

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
    settings = defaultSettings
    processQueueName = settingsProcessQueue settings
    resultsQueueName = settingsResultsQueue settings
    msgExchangeName = settingsExchange settings
    processExchangeKey = settingsProcessExchangeKey settings
    resultsExchangeKey = settingsResultsExchangeKey settings


consumerCallback :: (Message, Envelope) -> IO ()
consumerCallback (msg, env) = do
    putStrLn $ "started receiving from "
    putStrLn $ "received: " ++ (BL.unpack $ msgBody msg)

    (_, rsp) <- browse $ do
        --setProxy . fromJust $ parseProxy "127.0.0.1:8118"
        setAllowRedirects True
        setOutHandler $ const (return ())
        request $ createRequest crawlRequest

    putStrLn $ rspBody rsp

    publishResult env rsp

    ackEnv env
  where
    message = msgBody msg
    crawlRequest = parseCrawlRequest message

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

parseCrawlRequest :: BL.ByteString -> CrawlRequest
parseCrawlRequest msg =
    case (decode msg :: Maybe CrawlRequest) of
      Just cr -> cr
      Nothing -> error "Failed to parse crawl request"

createCrawlResponse :: Response String -> CrawlResponse
createCrawlResponse response =
    CrawlResponse
        { body = pack $ rspBody response
        , code = responseCode
        }
  where
    (n1, n2, n3) = rspCode response
    responseCode = read $ foldl (++) "" $ fmap show [n1, n2, n3] :: Int

publishResult :: Envelope -> Response String -> IO ()
publishResult env response = do
    publishMsg
        (envChannel env)
        "test_exchange"
        "result"
        (newMsg
            { msgBody = encode $ createCrawlResponse response
            , msgDeliveryMode = Just NonPersistent
            }
        )
