{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Avaya.Internal
    where
import           Prelude hiding (catch, getContents)
import           Control.Applicative
import           Control.Arrow
import           Control.Monad
import           Control.Monad.Error
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Comonad.Trans.Store
import           Data.Maybe
import           Network
import           System.IO

import           Control.Concurrent.STM
import           Data.Binary.Get
import           Data.Binary.Put
import           Data.Lens.Template
import           Data.Lens.Common

import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.Text as T
import           Text.Printf

import           Network.Avaya.Parse

data AvayaException
    -- | The remote host refused the specified authentication
    -- credentials.
    = AuthenticationFailure

    -- | The sessionID given by the application is not valid or not
    -- known by the server.
    | InvalidSessionId

    -- | The session terminated due to a resource constraint.
    | ResourceLimitation

instance Error AvayaException where
    strMsg = error


data AvayaConfig
    = AvayaConfig
      { cHost         :: HostName    -- ^ AES host name
      , cPort         :: PortNumber  -- ^ AES port number - default port is 4721
      , cUser         :: T.Text
      , cUserPassword :: T.Text
      , cDelay        :: T.Text
      , cVersion      :: T.Text      -- ^ AES version
      , cDuration     :: T.Text      -- ^ amount of time in seconds that a session will remain active
      , cCallServerIp :: T.Text
      , cExtension    :: T.Text
      , cPassword     :: T.Text
      } deriving (Show)

data AvayaSession
    = AvayaSession
      { _sIn         :: Maybe (TChan B.ByteString)
      , _sOut        :: Maybe (TChan B.ByteString)
      , _sInvokeId   :: Int
      , _sSessionId  :: Maybe T.Text
      , _sProtocol   :: Maybe T.Text
      , _sDeviceId   :: Maybe T.Text
      , _sMonitorId  :: Maybe T.Text
      }

makeLens ''AvayaSession

data AvayaState
    = AS (AvayaConfig, AvayaSession)

type Avaya
    = ErrorT AvayaException (ReaderT AvayaConfig (StateT AvayaSession IO))


defaultSession :: AvayaSession
defaultSession =
    AvayaSession
      { _sIn         = Nothing
      , _sOut        = Nothing
      , _sInvokeId   = 0
      , _sSessionId  = Nothing
      , _sProtocol   = Nothing
      , _sDeviceId   = Nothing
      , _sMonitorId  = Nothing
      }


runAvayaAction :: AvayaState -> Avaya a -> IO (Either AvayaException (AvayaState, a))
runAvayaAction (AS (conf, session)) action
    = (right . (,) . AS . ((,) conf) . snd) `ap` fst <$>
        runStateT (runReaderT (runErrorT action) conf) session


runAvayaActionWithLens :: (MonadIO m, MonadState app m) =>
                            Lens app (Maybe AvayaState) -> Avaya a
                         -> m (Either AvayaException a)
runAvayaActionWithLens lens action
    = do
        app <- get
        est <- liftIO $ runAvayaAction (fromJust $ getL lens app) action
        case est of
            Left excpt ->
                return $ Left excpt
            Right (avst, a) -> do
                put $ setL lens (Just avst) app
                return $ Right a


avayaRead :: Avaya B.ByteString
avayaRead = do
  c <- maccess sIn
  liftIO $ atomically $ readTChan c


avayaWrite :: B.ByteString -> Avaya ()
avayaWrite a = do
  c <- maccess sOut
  liftIO $ atomically $ writeTChan c a


loopRead :: Handle -> TChan B.ByteString -> IO ()
loopRead h ch = do
    res <- B.hGet h 8  -- get header (first 8 bytes)

    unless (B.null res) $ do
        let header = runGet getHeader res
        mes <- B.hGet h $ hLength header

        atomically $ writeTChan ch mes 
        loopRead h ch 


loopWrite :: Handle -> TChan B.ByteString -> Int -> IO ()
loopWrite h ch idx = do
    mess <- atomically $ readTChan ch
    B.hPut h (runPut $ putHeader mess (packInvokeId idx))
    loopWrite h ch (nextIdx idx)
  where
    nextIdx = mod 9999 . (+1)
    packInvokeId = B.pack . printf "%04d"


-- More logical reimplementation of Data.Lens.Lazy

access :: (Functor m, MonadState s m) => Lens s b -> m b
access (Lens f) = gets (pos . f)
{-# INLINE access #-}

maccess :: (Functor m, MonadState s m) => Lens s (Maybe b) -> m b
maccess lns
    = fromMaybe
        (error $ "Trying to access unsetted field")
        <$> access lns
{-# INLINE maccess #-}

infixr 4 ~=
(~=) :: (Functor m, MonadState s m) => Lens s b -> b -> m b
lns ~= b
    = (modify $ setL lns b) >> (return b)


infixr 4 ~!=
(~!=) :: (Functor m, MonadState s m) => Lens s (Maybe b) -> b -> m b
lns ~!= b
    = (modify $ setL lns $ Just b) >> (return b)


infixr 4 %=
    
(%=) :: (Functor m, MonadState s m) => Lens s b -> (b -> b) -> m b
lns %= g
    = (modify $ modL lns g) >> (getL lns <$> get)

