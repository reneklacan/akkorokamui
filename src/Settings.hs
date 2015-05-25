{-# OPTIONS -XOverloadedStrings #-}

module Settings where

import Data.Text

data Settings = Settings
    { settingsProcessQueue :: Text
    , settingsResultsQueue :: Text
    , settingsExchange :: Text
    , settingsProcessExchangeKey :: Text
    , settingsResultsExchangeKey :: Text }


settings :: Settings
settings =
    Settings
        { settingsProcessQueue = "akkorokamui_new"
        , settingsResultsQueue = "akkorokamui_results"
        , settingsExchange = "akkorokamui_exchange"
        , settingsProcessExchangeKey = "new"
        , settingsResultsExchangeKey = "results" }
