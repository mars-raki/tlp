module Learn where

import Application
import Import

import Codec.Picture
import Codec.Picture.Types
import Database.Persist.Sql (toSqlKey)
import Data.Aeson (decode)
import qualified Data.Text.Lazy.Encoding as LTE
import qualified Data.Text.Lazy as LT
import qualified Data.Vector.Storable as V
import System.IO (withBinaryFile, IOMode(ReadMode))
import qualified Vision.Image as I
import qualified Vision.Primitive as P
import qualified Vision.Primitive.Shape as S
import Vision.Image.Conversion
import Vision.Image.Filter
import Vision.Image.Grey.Type
import Vision.Image.JuicyPixels
import Vision.Image.RGB.Type
import Vision.Image.Type

import qualified Data.List as L

import Polygon

learn :: IO ()
learn = handler learnHandler

saveChop :: IO ()
saveChop = handler saveChopHandler

saveChopHandler :: Handler ()
saveChopHandler = do
    examples <- loadExamples 5
    liftIO $ mapM_ saveNumberedExample $ zip [1..] examples

saveNumberedExample :: (Int, Example) -> IO ()
saveNumberedExample (number, example) =
    let
      juiced = ImageRGB8 $ toJuicyRGB $ exampleImage example
      filename = (show number) ++ ".png"
    in
      savePngImage filename juiced

data Example = Example
    { exampleImage :: RGB
    , exampleLabel :: Int
    }

data ProcessedExample = ProcessedExample
    { processedExampleFeatureValues :: [Double]
    , processedExampleLabel :: Int
    } deriving (Show)

data Feature = Feature RGB

dotWord8 :: Word8 -> Word8 -> Double
dotWord8 a b =
  ((fromIntegral a) / 256) * ((fromIntegral b) / 256)

dotPixel :: RGBPixel -> RGBPixel -> Double
dotPixel p1 p2 =
    (dotWord8 (rgbRed p1) (rgbRed p2)) +
    (dotWord8 (rgbGreen p1) (rgbGreen p2)) +
    (dotWord8 (rgbBlue p1) (rgbBlue p2))

dotImage :: RGB -> RGB -> Double
dotImage i1 i2 =
    V.sum $ V.zipWith dotPixel (I.manifestVector i1) (I.manifestVector i2)

featureValue :: Feature -> RGB -> Double
featureValue (Feature feature) image =
    (dotImage feature image) / (sqrt $ (dotImage feature feature) * (dotImage image image))

loadExample :: [Entity Label] -> Polygon -> Entity Frame -> Handler Example
loadExample labels polygon (Entity frameId frame) = do
    imageEither <- liftIO $ withBinaryFile (unpack $ frameFilename frame) ReadMode (\x -> fmap decodeImage (hGetContents x))
    image <- case imageEither of
      Left error -> invalidArgs ["Could not load image."]
      Right (ImageYCbCr8 image) -> return $ toFridayRGB $ convertImage image
      Right _ -> invalidArgs ["Unknown image type."]
    let chopped = chopImage polygon image

    label <- case headMay $ L.map (\(Entity _ label) -> labelValue label) $ L.filter (\(Entity _ label) -> labelFrame label == frameId) labels of
      Just "unoccupied" -> return 0
      Just "occupied" -> return 1
      other -> invalidArgs ["Bad label " ++ (fromString $ show other) ++ "."]

    return $ Example chopped label

loadExamples :: Int -> Handler [Example]
loadExamples count = do
    let directionId = toSqlKey 3 :: DirectionId
    let regionId = toSqlKey 7 :: RegionId
    frames <- runDB $ selectList [FrameDirection ==. directionId] [LimitTo count]
    labels <- runDB $ selectList [LabelRegion ==. regionId] []
    region <- runDB $ get404 regionId
    polygon <- case (decode (LTE.encodeUtf8 $ LT.fromStrict $ regionValue region) :: Maybe Polygon) of
      Just polygon -> return $ zoom 0.5 polygon
      Nothing -> invalidArgs ["Cannot decode polygon."]
    mapM (loadExample labels polygon) frames

makeFeatures' :: Int -> [Example] -> [Feature]
makeFeatures' 0 _ = []
makeFeatures' _ [] = []
makeFeatures' count (example : examples) =
    (Feature $ exampleImage example) : makeFeatures' (count - 1) (drop ((quot (1 + length examples) count) - 1) examples)

makeFeatures :: Int -> [Example] -> [Feature]
makeFeatures count examples =
    (makeFeatures' (quot count 2) (filter (\x -> exampleLabel x == 0) examples)) ++
    (makeFeatures' (quot count 2) (filter (\x -> exampleLabel x == 1) examples))

processExample :: [Feature] -> Example -> ProcessedExample
processExample features example =
    ProcessedExample
      (map (\f -> featureValue f (exampleImage example)) features)
      (exampleLabel example)

learnHandler :: Handler ()
learnHandler = do
    {-frame <- runDB $ get404 (toSqlKey 4520 :: FrameId)
    region <- runDB $ get404 (toSqlKey 7 :: RegionId)
    let blurred = colorGaussianBlur 5 chopped
    let rejuiced = ImageRGB8 $ toJuicyRGB chopped
    liftIO $ savePngImage "example.png" rejuiced-}
    let trainSize = 200
    let testSize = 100
    let trainTestBufferSize = 100
    examples <- loadExamples (trainSize + trainTestBufferSize + testSize)
    let trainExamples = take trainSize examples
    let testExamples = drop (trainSize + trainTestBufferSize) examples
    let features = makeFeatures 6 trainExamples
    liftIO $ print $ length features
    liftIO $ mapM_ (print . (processExample features)) trainExamples
    return ()

chopImage :: Polygon -> RGB -> RGB
chopImage polygon image =
    let
      rect = boundingRect polygon
      Rect origin _ = rect
      Point ox oy = origin
      translatedPolygon = setOrigin origin polygon
      fridayRect = P.Rect (floor ox) (floor oy) (ceiling $ rw rect) (ceiling $ rh rect)
      croppedImage = I.crop fridayRect image :: RGB
    in
      I.fromFunction (I.shape croppedImage) $ \pt ->
        let
          S.Z S.:. y S.:. x = pt
          point = Point (fromIntegral x + 0.5) (fromIntegral y + 0.5)
        in
          if containsPoint translatedPolygon point then
            I.index croppedImage pt
          else
            RGBPixel 0 0 0

colorGaussianBlur :: Int -> RGB -> RGB
colorGaussianBlur radius image =
    let
      blurF = gaussianBlur radius (Nothing :: Maybe Double)
      red = blurF $ redChannel image
      green = blurF $ greenChannel image
      blue = blurF $ blueChannel image
    in
      combineChannels red green blue

redChannel :: RGB -> Grey
redChannel = I.map (GreyPixel . rgbRed)

greenChannel :: RGB -> Grey
greenChannel = I.map (GreyPixel . rgbGreen)

blueChannel :: RGB -> Grey
blueChannel = I.map (GreyPixel . rgbBlue)

combineChannels :: Grey -> Grey -> Grey -> RGB
combineChannels red green blue =
    I.fromFunction (I.shape red) $ \pt ->
      RGBPixel (pixelValue $ I.index red pt) (pixelValue $ I.index green pt) (pixelValue $ I.index blue pt)

pixelValue :: GreyPixel -> Word8
pixelValue (GreyPixel v) = v
