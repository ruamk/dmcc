{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

{-| Shared type declarations. -}

module DMCC.Types

where

import DMCC.Prelude

#if MIN_VERSION_base(4,13,0)
import Control.Monad.Fail
#endif
import Data.Aeson as A
import Data.Aeson.TH
import Data.CaseInsensitive
import Data.Data
import Data.Text as T


-- | Device ID used in DMCC requests.
--
-- This is based on text as stated in DMCC specification.
newtype DeviceId =
  DeviceId (CI Text)
  deriving (Eq, Ord, Show)


instance FromJSON DeviceId where
  parseJSON v = DeviceId . mk <$> parseJSON v


instance ToJSON DeviceId where
  toJSON (DeviceId t) = toJSON $ original t


newtype CallId =
  CallId Text
  deriving (Eq, Ord, Show, FromJSON, ToJSON)


-- | Globally unique call ID.
newtype UCID =
  UCID Text
  deriving (Eq, Ord, Show, FromJSON, ToJSON)


newtype Extension =
  Extension Text
  deriving (Eq, Ord, Show,
            Data, Typeable, ToJSON)


instance FromJSON Extension where
  parseJSON = withText "Extension" parseExtension
    where
      parseExtension s
        | T.length s > 30 = fail "Maximum extension length is 30 digits"
        | (\c -> c `elem` (['0'..'9'] <> ['*', '#'])) `T.all` s = pure $ Extension s
        | otherwise = fail "Extension must contain the digits 0-9, * or #"


newtype SwitchName =
  SwitchName Text
  deriving (Eq, Ord, Show, Data, Typeable, FromJSON, ToJSON)


newtype AgentId =
  AgentId (SwitchName, Extension)
  deriving (Data, Typeable, Eq, Ord, Show, FromJSON, ToJSON)


data CallDirection = In { vdn :: DeviceId }
                   | Out
                   deriving (Eq, Show)


$(deriveJSON
  defaultOptions{sumEncoding = defaultTaggedObject{tagFieldName="dir"}}
  ''CallDirection)


data Call = Call
  { direction :: CallDirection
  , ucid :: UCID
  , start :: UTCTime
  -- ^ When did call came into existence?
  , interlocutors :: [DeviceId]
  , answered :: Maybe UTCTime
  -- ^ When did another party answer this call?
  , held :: Bool
  , failed :: Bool
  }
  deriving Show


$(deriveJSON defaultOptions ''Call)


data SettableAgentState = Ready
                        | AfterCall
                        | NotReady
                        | Logout
                        deriving (Eq, Show)


$(deriveJSON defaultOptions ''SettableAgentState)


data AgentState = Busy
                | Settable SettableAgentState
                deriving (Eq, Show)


instance ToJSON AgentState where
  toJSON Busy         = String "Busy"
  toJSON (Settable s) = toJSON s


instance FromJSON AgentState where
  parseJSON (String "Busy") = pure Busy
  parseJSON s@(String _)    = Settable <$> parseJSON s
  parseJSON _               = fail "Could not parse AgentState"


data ParticipationType = Active
                       | Silent
                       deriving (Eq, Show)


$(deriveJSON defaultOptions ''ParticipationType)


-- TODO This should be removed
newtype LoggingOptions = LoggingOptions
  { syslogIdent :: ByteString
  }


data SessionOptions = SessionOptions
  { statePollingDelay :: Int
  -- ^ How often to poll every agent for state changes (in seconds).
  , sessionDuration :: Int
  -- ^ Serves both as session duration and session cleanup delay (in
  -- seconds).
  , connectionRetryAttempts :: Int
  , connectionRetryDelay :: Int
  -- ^ In seconds.
  }
