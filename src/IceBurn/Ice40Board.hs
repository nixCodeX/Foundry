{-# LANGUAGE LambdaCase, NoImplicitPrelude, OverloadedStrings, RecordWildCards #-}
{-|
Module      : IceBurn.Ice40Board
Description : Interact with an Ice 40 FPGA
Copyright   : (c) Jonathan Tanner, 2019
Licence     : GPL-3
Maintainer  : jonathan.tanner@sjc.ox.ac.uk
Stability   : experimental
-}
module IceBurn.Ice40Board
  ( Ice40Board
  , withBoard
  , boardGetSerial
  , boardWithGpio
  , gpioSetReset
  , boardWithSpi
  , spiSetSpeed
  , spiSetMode
  , spiIoFunc
  , M25P10Flash(..)
  , flashWakeup
  , flashSetWritable
  , flashChipErase
  , flashRead
  , flashPageProgram
  , flashWaitDone
  , flashGetStatus
  , flashGetId
  ) where

import ClassyPrelude

import Utils (Endianness(..), encodeWord32, decodeWord32, wrapError)

import Control.Monad.Except (ExceptT(..), runExceptT, throwError)
import Control.Monad.Trans (lift)
import Data.Bits (shiftR, (.&.))
import Data.List (unfoldr)
import Data.List.Split (chunksOf)
import qualified Data.Vector as Vector
import System.Exit (exitFailure)
import System.IO (hPutStrLn)
import System.USB

vendorId :: VendorId
vendorId = 0x1443

productId :: ProductId
productId = 0x0007

cmdGetBoardType :: Word8
cmdGetBoardType = 0xE2

cmdGetBoardSerial :: Word8
cmdGetBoardSerial = 0xE4

cmdOutAddress :: EndpointAddress
cmdOutAddress = EndpointAddress 1 Out

cmdInAddress :: EndpointAddress
cmdInAddress = EndpointAddress 2 In

dataOutAddress :: EndpointAddress
dataOutAddress = EndpointAddress 3 Out

dataInAddress :: EndpointAddress
dataInAddress = EndpointAddress 4 In

findEndpointDesc :: Interface -> EndpointAddress -> Either Text EndpointDesc
findEndpointDesc is a = maybe (Left $ "Cannot find endpoint for address " ++ tshow a) Right . find ((== a) . endpointAddress) . concat . map interfaceEndpoints $ is

data Ice40Board = Ice40Board
  { boardDevice  :: DeviceHandle
  , boardCmdOut  :: EndpointDesc
  , boardCmdIn   :: EndpointDesc
  , boardDataOut :: EndpointDesc
  , boardDataIn  :: EndpointDesc
  }

withBoard :: (Ice40Board -> ExceptT Text IO a) -> ExceptT Text IO a
withBoard act = do
  ctx <- lift newCtx
  lift $ setDebug ctx PrintInfo

  dev <- lift $
    if ctx `hasCapability` HasHotplug
    then waitForBoard ctx vendorId productId
    else findBoard    ctx vendorId productId

  ConfigDesc{..} <- lift $ getConfigDesc dev 0
  intf <- maybe (throwError "No Interface found") return . headMay $ configInterfaces

  boardCmdOut  <- ExceptT . return . findEndpointDesc intf $ cmdOutAddress
  boardCmdIn   <- ExceptT . return . findEndpointDesc intf $ cmdInAddress
  boardDataOut <- ExceptT . return . findEndpointDesc intf $ dataOutAddress
  boardDataIn  <- ExceptT . return . findEndpointDesc intf $ dataInAddress

  ExceptT . withDeviceHandle dev $ \boardDevice -> runExceptT $ do
    bType <- boardGetType Ice40Board{..}
    unless (bType == "iCE40") . throwError $ "Board type " ++ bType ++ " does not match expected \"iCE40\""
    act $ Ice40Board{..}

boardGetType :: Ice40Board -> ExceptT Text IO Text
boardGetType board = decodeUtf8 . takeWhile (/= 0x00) <$> boardCtrlRead board 0xE2 16

boardGetSerial :: Ice40Board -> ExceptT Text IO Text
boardGetSerial board = decodeUtf8 . takeWhile (/= 0x00) <$> boardCtrlRead board 0xE2 16

boardCtrlRead :: Ice40Board -> Request -> Size -> ExceptT Text IO ByteString
boardCtrlRead Ice40Board{..} req size =
  lift (readControl boardDevice (ControlSetup Vendor ToEndpoint req 0 0) size 100)
  >>= \case
    (bs, Completed) -> return bs
    (_,  TimedOut)  -> throwError "Request timed out"

usbRead :: DeviceHandle -> EndpointDesc -> Size -> ExceptT Text IO ByteString
usbRead dev EndpointDesc{..} size =
  case endpointAttribs of
    Control           -> throwError "Control transfers not yet supported"
    (Isochronous _ _) -> throwError "Isochronous transfers not yet supported"
    Bulk              -> return readBulk
    Interrupt         -> return readInterrupt
  >>= lift . (\f -> f dev endpointAddress size 1000)
  >>= \case
    (bs, Completed) -> return bs
    (_,  TimedOut)  -> throwError "Read timed out"

usbWrite :: DeviceHandle -> EndpointDesc -> ByteString -> ExceptT Text IO ()
usbWrite dev EndpointDesc{..} bs =
  case endpointAttribs of
    Control           -> throwError "Control transfers not yet supported"
    (Isochronous _ _) -> throwError "Isochronous transfers not yet supported"
    Bulk              -> return writeBulk
    Interrupt         -> return writeInterrupt
  >>= lift . (\f -> f dev endpointAddress bs 1000)
  >>= \case
    (_, Completed) -> return ()
    (_, TimedOut)  -> throwError "Write timed out"

boardCmdI :: Ice40Board -> ByteString -> Size -> ExceptT Text IO ByteString
boardCmdI Ice40Board{..} bs size = do
  let payload = cons (fromIntegral . length $ bs) bs
  usbWrite boardDevice boardCmdOut payload
  usbRead boardDevice boardCmdIn size

boardCmd :: Ice40Board -> Word8 -> Word8 -> ByteString -> Size -> ExceptT Text IO ByteString
boardCmd board cmd subCmd payload size = do
  boardCmdI board (cons cmd . cons subCmd $ payload) size

data GPIO = GPIO Ice40Board

boardWithGpio :: Ice40Board -> (GPIO -> ExceptT Text IO a) -> ExceptT Text IO a
boardWithGpio board act = wrapError
  (void $ boardCmd board 0x03 0x00 "\x00" 16)
  (act . GPIO $ board)
  (void $ boardCmd board 0x03 0x01 "\x00" 16)

gpioSetDir :: GPIO -> Word8 -> ExceptT Text IO ()
gpioSetDir (GPIO board) dir = void $ boardCmd board 0x03 0x04 (pack [0x00, dir, 0x00, 0x00, 0x00]) 16

gpioSetValue :: GPIO -> Word8 -> ExceptT Text IO ()
gpioSetValue (GPIO board) value = void $ boardCmd board 0x03 0x06 (pack [0x00, value, 0x00, 0x00, 0x00]) 16

gpioSetReset :: GPIO -> Bool -> ExceptT Text IO ()
gpioSetReset gpio True  = gpioSetDir gpio 1 >> gpioSetValue gpio 0
gpioSetReset gpio False = gpioSetDir gpio 0

data SPI = SPI Ice40Board

boardWithSpi :: Ice40Board -> Word8 -> (SPI -> ExceptT Text IO a) -> ExceptT Text IO a
boardWithSpi board portNum act = wrapError
  (void $ boardCmd board 0x06 0x00 (pack [portNum]) 16)
  (act . SPI $ board)
  (void $ boardCmd board 0x06 0x01 (pack [portNum]) 16)

spiSetSpeed :: SPI -> Word32 -> ExceptT Text IO Word32
spiSetSpeed (SPI board) speed =
  decodeWord32 Little <$> boardCmd board 0x06 0x03 (cons 0x00 (encodeWord32 Little speed)) 16

spiSetMode :: SPI -> ExceptT Text IO ()
spiSetMode (SPI board) =
  void $ boardCmd board 0x06 0x05 (pack [0x00, 0x00]) 16

spiIoFunc :: SPI -> ByteString -> Size -> ExceptT Text IO ByteString
spiIoFunc (SPI Ice40Board{..}) writeBytes readSize = do
  boardCmd Ice40Board{..} 0x06 0x06 (pack [0x00, 0x00]) 16 -- SPI Start
  boardCmd Ice40Board{..} 0x06 0x07 (pack [0x00, 0x00, 0x00, if readSize > 0 then 0x01 else 0x00, fromIntegral . length $ writeBytes]) 16 -- SPI IO Start
  let writeChunks = map pack . chunksOf 64 . unpack $ writeBytes
  mapM (usbWrite boardDevice boardDataOut) writeChunks
  let readSizes = unfoldr (\case 0 -> Nothing; x -> let y = min 64 x in Just (y, x - y)) readSize
  readBytes <- concat <$> mapM (usbRead boardDevice boardDataIn) readSizes
  boardCmd Ice40Board{..} 0x06 0x87 (pack [0x00]) 16
  boardCmd Ice40Board{..} 0x06 0x06 (pack [0x00, 0x01]) 16
  return readBytes

data M25P10Flash = M25P10Flash (ByteString -> Size -> ExceptT Text IO ByteString)

flashStatBusy :: Word8
flashStatBusy = 0x1
flashStatWel :: Word8
flashStatWel = 0x2

flashCmdGetStatus :: Word8
flashCmdGetStatus = 0x05
flashCmdWriteEnable :: Word8
flashCmdWriteEnable = 0x6
flashCmdReadId :: Word8
flashCmdReadId = 0x9F
flashCmdWakeUp :: Word8
flashCmdWakeUp = 0xAB
flashCmdChipErase :: Word8
flashCmdChipErase = 0xC7
flashCmdPageProgram :: Word8
flashCmdPageProgram = 0x02
flashCmdFastRead :: Word8
flashCmdFastRead = 0xB

flashWakeup :: M25P10Flash -> ExceptT Text IO ()
flashWakeup (M25P10Flash io) = void $ io (pack [flashCmdWakeUp]) 0

flashSetWritable :: M25P10Flash -> ExceptT Text IO ()
flashSetWritable (M25P10Flash io) = void $ io (pack [flashCmdWriteEnable]) 0

flashChipErase :: M25P10Flash -> ExceptT Text IO ()
flashChipErase flash@(M25P10Flash io) = do
  flashSetWritable flash
  void $ io (pack [flashCmdChipErase]) 0
  flashWaitDone flash

flashRead :: M25P10Flash -> Word32 -> Size -> ExceptT Text IO ByteString
flashRead (M25P10Flash io) addr size = drop 5
  <$> io 
    ( pack
      [ flashCmdFastRead
      , fromIntegral . shiftR addr $ 16
      , fromIntegral . shiftR addr $ 8
      , fromIntegral addr
      , 0x00
      ]
      )
    ( size + 5 )

flashPageProgram :: M25P10Flash -> Word32 -> ByteString -> ExceptT Text IO ()
flashPageProgram flash@(M25P10Flash io) addr buf = do
  flashSetWritable flash
  io
    ( pack
      [ flashCmdPageProgram
      , fromIntegral . shiftR addr $ 16
      , fromIntegral . shiftR addr $ 8
      , fromIntegral addr
      ] ++ buf
      )
    0
  flashWaitDone flash

flashWaitDone :: M25P10Flash -> ExceptT Text IO ()
flashWaitDone flash = (flashStatBusy .&.) <$> flashGetStatus flash >>= \case
  0 -> return ()
  _ -> flashWaitDone flash

flashGetStatus :: M25P10Flash -> ExceptT Text IO Word8
flashGetStatus (M25P10Flash io) =
  io (pack [flashCmdGetStatus]) 1
  >>= (\x -> (lift . putStrLn . ("Status: " ++) . tshow . unpack $ x) >> return x)
  >>= maybe (throwError "Failed to get flash status") return . flip index 1

flashGetId :: M25P10Flash -> ExceptT Text IO ByteString
flashGetId (M25P10Flash io) =
  io (pack [flashCmdReadId]) 4
  >>= (\x -> (lift . putStrLn . ("ID: " ++) . tshow . unpack $ x) >> return x)
  >>= maybe (throwError "Failed to get flash id") return . tailMay

waitForBoard :: Ctx -> VendorId -> ProductId -> IO Device
waitForBoard ctx vendorId productId = do
  putStrLn "Waiting for board attachment..."
  mv <- newEmptyMVar
  mask_ $
    registerHotplugCallback
      ctx
      deviceArrived
      enumerate
      (Just vendorId)
      (Just productId)
      Nothing
      (\dev event -> tryPutMVar mv (dev, event) $> DeregisterThisCallback)
    >>= void . mkWeakMVar mv . deregisterHotplugCallback
  (dev, _) <- takeMVar mv
  return dev

-- Enumerate all devices and find the right one.
findBoard :: Ctx -> VendorId -> ProductId -> IO Device
findBoard ctx vendorId productId = do
    getDevices ctx >>= (headMay <$>) . filterM (fmap match . getDeviceDesc) >>= \case
      Nothing  -> hPutStrLn stderr "Board not found" >> exitFailure
      Just dev -> return dev
  where
    match :: DeviceDesc -> Bool
    match DeviceDesc{..} = deviceVendorId  == vendorId && deviceProductId == productId
