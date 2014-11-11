{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module SDL.Audio
  ( -- * 'AudioFormat'
    AudioFormat

    -- * 'AudioSpec'
  , AudioSpec(audioSpecFreq , audioSpecFormat , audioSpecChannels)
  , audioSpecSilence
  , audioSpecSize
  , audioSpecCallback

    -- * 'Channels'
  , Channels(..)

    -- * 'AudioDevice'
  , AudioDevice
  , getAudioDeviceNames
  , openAudioDevice
  , closeAudioDevice
  , LockState(..)
  , setAudioDeviceLocked
  , PlaybackState(..)
  , setAudioDevicePlaybackState
  -- , clearQueuedAudio
  , AudioDeviceStatus(..)
  , audioDeviceStatus
  , OpenDeviceSpec(..)
  , Changeable(..)
  , AudioDeviceUsage(..)

    -- * Audio Drivers
  , AudioDriver
  , audioDriverName
  , getAudioDrivers
  , currentAudioDriver

    -- * Explicit Initialization
  , audioInit
  , Raw.audioQuit
  ) where

import Control.Applicative
import Data.Bits
import Data.Traversable (for)
import Data.Word
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils
import Foreign.Ptr
import Foreign.Storable
import Data.Text (Text)
import Data.Typeable
import Data.Vector.Storable (Vector)
import SDL.Exception

import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV
import qualified SDL.Raw.Audio as Raw
import qualified SDL.Raw.Enum as Raw
import qualified SDL.Raw.Types as Raw

newtype AudioFormat = AudioFormat { unAudioFormat :: Word16 }
  deriving (Eq, Ord, Show, Typeable)

{-

audioFormatBitSize :: Lens' AudioFormat Word8
audioFormatFloat :: Lens' AudioFormat Bool
audioFormatBigEndian :: Lens' AudioFormat Bool
audioFormatSigned :: Lens' AudioFormat Bool

audioFormatU8 = AudioFormat 0 & audioFormatBitSize .~ 8
audioFormatS8 = audioFormatU8 & audioFormatSigned .~ True

audioFormatS16LSB = audioFormatS8 & audioFormatBitSize .~ 16
audioFormatS16MSB = audioFormatS16LSB & audioFormatBigEndian .~ True
audioFormatS16Sys = _
audioFormatS16 = audioFormatS16LSB
audioFormatU16LSB = audioFormatS16LSB & audioFormatSigned .~ False
audioFormatU16MSB = audioFormatS16MSB & audioFormatSigned .~ False
audioFormatU16Sys = _
audioFormatU16 = audioFormatU16LSB

audioFormatS32LSB = audioFormatS16LSB & audioFormatBitSize .~ 32
audioFormatS32MSB = audioFormatS16MSB & audioFormatBitSize .~ 32
audioFormatS32Sys = _
audioFormatS32 = audioFormatS32LSB

audioFormatF32LSB = audioFormatS32LSB & audioFormatFloat .~ True
audioFormatF32MSB = audioFormatS32MSB & audioFormatFloat .~ True
audioFormatF32Sys = _
audioFormatF32 = audioFormatF32LSB

-}

data Channels = Mono | Stereo | Quad | FivePointOne
  deriving (Eq, Show, Typeable)

data AudioSpec = AudioSpec
  { audioSpecFreq :: !CInt
  , audioSpecFormat :: !AudioFormat
  , audioSpecChannels :: !Channels
  , _audioSpecSilence :: !Word8
  , audioSpecSamples :: !Word16
  , _audioSpecSize :: !Word32
  , audioSpecCallback :: !(CInt -> IO (Vector Word8))
  }

audioSpecSilence :: AudioSpec -> Word8
audioSpecSilence = _audioSpecSilence

audioSpecSize :: AudioSpec -> Word32
audioSpecSize = _audioSpecSize

newtype AudioDevice = AudioDevice (Raw.AudioDeviceID)
  deriving (Eq, Typeable)

getAudioDeviceNames :: AudioDeviceUsage -> IO (Maybe (V.Vector Text))
getAudioDeviceNames usage = do
  n <- Raw.getNumAudioDevices usage'
  if n == -1
    then return Nothing
    else fmap (Just . V.fromList) $
         for [0 .. (n - 1)] $ \i -> do
           cstr <- throwIfNull "SDL.Audio.getAudioDeviceNames" "SDL_GetAudioDeviceName" $
             Raw.getAudioDeviceName i usage'
           Text.decodeUtf8 <$> BS.packCString cstr

  where usage' = encodeUsage usage

data AudioDeviceUsage = ForPlayback | ForCapture
  deriving (Eq, Show, Typeable)

encodeUsage :: Num a => AudioDeviceUsage -> a
encodeUsage usage =
  case usage of
    ForPlayback -> 0
    ForCapture -> 1

data OpenDeviceSpec = OpenDeviceSpec
  { openDeviceFreq :: !(Changeable CInt)
  , openDeviceFormat :: !(Changeable AudioFormat)
  , openDeviceChannels :: !(Changeable Channels)
  , openDeviceSamples :: !Word16
  , openDeviceCallback :: !(CInt -> IO (Vector Word8))
  , openDeviceUsage :: !AudioDeviceUsage
  , openDeviceName :: !(Maybe Text)
  } deriving (Typeable)

data Changeable a
  = Mandate !a
  | Desire !a
  deriving (Eq, Show, Typeable)

foldChangeable :: (a -> b) -> (a -> b) -> Changeable a -> b
foldChangeable f _ (Mandate a) = f a
foldChangeable _ g (Desire a) = g a

unpackChangeable :: Changeable a -> a
unpackChangeable = foldChangeable id id

openAudioDevice :: OpenDeviceSpec -> IO (AudioDevice, AudioSpec)
openAudioDevice OpenDeviceSpec{..} =
  maybeWith (BS.useAsCString . Text.encodeUtf8) openDeviceName $ \cDevName -> do
    cb <- Raw.mkAudioCallback $ \_ buffer len -> do
      v <- openDeviceCallback len
      let (vForeignPtr, len') = SV.unsafeToForeignPtr0 v
      withForeignPtr vForeignPtr $ \vPtr ->
        copyBytes buffer vPtr (min (fromIntegral len) (fromIntegral len'))
    with (desiredSpec cb) $ \desiredSpecPtr ->
      alloca $ \actualSpecPtr -> do
        devId <- throwIf0 "SDL.Audio.openAudioDevice" "SDL_OpenAudioDevice" $
          Raw.openAudioDevice cDevName (encodeUsage openDeviceUsage) desiredSpecPtr actualSpecPtr changes
        actual <- peek actualSpecPtr
        let audioDevice = AudioDevice devId
            spec = AudioSpec { audioSpecFreq = Raw.audioSpecFreq actual
                             , audioSpecFormat = AudioFormat (Raw.audioSpecFormat actual)
                             , audioSpecChannels = fromC "SDL.Audio.openAudioDevice" "audioSpecChannels" readChannels (Raw.audioSpecChannels actual)
                             , _audioSpecSilence = Raw.audioSpecSilence actual
                             , _audioSpecSize = Raw.audioSpecSize actual
                             , audioSpecSamples = Raw.audioSpecSamples actual
                             , audioSpecCallback = openDeviceCallback
                             }
        return (audioDevice, spec)

  where
  changes = foldl (.|.) 0 [ foldChangeable (const Raw.SDL_AUDIO_ALLOW_FREQUENCY_CHANGE) (const 0) openDeviceFreq
                          , foldChangeable (const Raw.SDL_AUDIO_ALLOW_FORMAT_CHANGE) (const 0) openDeviceFormat
                          , foldChangeable (const Raw.SDL_AUDIO_ALLOW_CHANNELS_CHANGE) (const 0) openDeviceChannels
                          ]

  channelsToWord8 Mono = 1
  channelsToWord8 Stereo = 2
  channelsToWord8 Quad = 4
  channelsToWord8 FivePointOne = 6

  readChannels 1 = Just Mono
  readChannels 2 = Just Stereo
  readChannels 4 = Just Quad
  readChannels 6 = Just FivePointOne
  readChannels _ = Nothing

  desiredSpec cb = Raw.AudioSpec
    { Raw.audioSpecFreq = unpackChangeable openDeviceFreq
    , Raw.audioSpecFormat = unAudioFormat (unpackChangeable openDeviceFormat)
    , Raw.audioSpecChannels = channelsToWord8 (unpackChangeable openDeviceChannels)
    , Raw.audioSpecSilence = 0
    , Raw.audioSpecSize = 0
    , Raw.audioSpecSamples = openDeviceSamples
    , Raw.audioSpecCallback = cb
    , Raw.audioSpecUserdata = nullPtr
    }

closeAudioDevice :: AudioDevice -> IO ()
closeAudioDevice (AudioDevice d) = Raw.closeAudioDevice d

data LockState = Locked | Unlocked
  deriving (Eq, Show, Typeable)

setAudioDeviceLocked :: AudioDevice -> LockState -> IO ()
setAudioDeviceLocked (AudioDevice d) Locked = Raw.lockAudioDevice d
setAudioDeviceLocked (AudioDevice d) Unlocked = Raw.unlockAudioDevice d

data PlaybackState = Pause | Play
  deriving (Eq, Show, Typeable)

setAudioDevicePlaybackState :: AudioDevice -> PlaybackState -> IO ()
setAudioDevicePlaybackState (AudioDevice d) Pause = Raw.pauseAudioDevice d 1
setAudioDevicePlaybackState (AudioDevice d) Play = Raw.pauseAudioDevice d 0

data AudioDeviceStatus = Playing | Paused | Stopped
  deriving (Eq, Show, Typeable)

audioDeviceStatus :: AudioDevice -> IO AudioDeviceStatus
audioDeviceStatus (AudioDevice d) = fromC "SDL.Audio.audioDeviceStatus" "SDL_AudioStatus" readStatus <$> Raw.getAudioDeviceStatus d
  where
  readStatus n = case n of
    Raw.SDL_AUDIO_PLAYING -> Just Playing
    Raw.SDL_AUDIO_STOPPED -> Just Stopped
    Raw.SDL_AUDIO_PAUSED -> Just Paused
    _ -> Nothing

-- clearQueuedAudio :: AudioDevice -> IO ()
-- clearQueuedAudio (AudioDevice d) = Raw.clearQueuedAudio d

newtype AudioDriver = AudioDriver Text
  deriving (Eq, Show, Typeable)

audioDriverName :: AudioDriver -> Text
audioDriverName (AudioDriver t) = t

getAudioDrivers :: IO (V.Vector AudioDriver)
getAudioDrivers = do
  n <- Raw.getNumAudioDrivers
  fmap V.fromList $
    for [0 .. (n - 1)] $ \i -> do
      -- TODO This could return null if i is invalid, but it's not an SDL_Error.
      cstr <- Raw.getAudioDriver i
      AudioDriver . Text.decodeUtf8 <$> BS.packCString cstr

audioInit :: AudioDriver -> IO ()
audioInit (AudioDriver n) = BS.useAsCString (Text.encodeUtf8 n) $
  throwIfNeg_ "SDL.Audio.audioInit" "SDL_AudioInit" . Raw.audioInit

currentAudioDriver :: IO (Maybe Text)
currentAudioDriver =
  maybePeek (fmap Text.decodeUtf8 . BS.packCString) =<< Raw.getCurrentAudioDriver
