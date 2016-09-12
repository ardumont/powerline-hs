{-# LANGUAGE ScopedTypeVariables #-}

-- TODO: split this file up - too much config logic in here
module Main where

import Control.Monad
import Data.Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.Function ((&))
import Data.List (foldl1')
import qualified Data.Map.Lazy as Map
import Data.Map.Lazy.Merge
import Data.Maybe (fromJust, fromMaybe)
import Data.Monoid ((<>))
import Rainbow (byteStringMakerFromEnvironment)
import System.Directory (doesFileExist)
import System.Environment.XDG.BaseDir (getUserConfigDir)
import System.FilePath ((</>), takeExtension)

import Aeson_Merge
import CommandArgs
import ConfigSchema(
    ColourConfig(..),
    ColourSchemeConfig(..),
    ExtConfig(..),
    ExtConfigs(..),
    ForBothSides(..),
    MainConfig(..),
    Segment(..),
    SegmentArgs,
    SegmentData(..),
    ThemeConfig(..),
    defaultTopTheme,
    )
import Rendering
import Segments
import Util


main :: IO ()
main = parseArgs >>= \args -> do
    cfgDir  <- getUserConfigDir "powerline"
    config  <- loadConfigFile $ cfgDir </> "config.json" :: IO MainConfig
    colours <- loadConfigFile $ cfgDir </> "colors.json" :: IO ColourConfig

    let ExtConfig shellCS shellTheme = shell . ext $ config

    -- Color scheme
    let csNames = (\dir -> cfgDir </> dir </> shellCS ++ ".json") <$> [
                    "colorschemes",
                    "colorschemes/shell"
                ]
    cs <- loadLayeredConfigFiles csNames :: IO ColourSchemeConfig

    -- Themes - more complicated because we need to merge before parsing
    let default_top_theme = defaultTopTheme $ common config
    let themeNames = [
                    default_top_theme ++ ".json",
                    "shell" </> "__main__.json",
                    "shell" </> shellTheme ++ ".json"
                 ]
    let themePaths = (cfgDir </>) . ("themes" </>) <$> themeNames
    themesThatExist <- filterM doesFileExist themePaths
    themeCfg <- loadLayeredConfigFiles themesThatExist :: IO ThemeConfig

    -- Need to segments over segment_data
    let fmap2 f = fmap (fmap f)
    let segments' = layerSegments (segment_data themeCfg) `fmap2` segments themeCfg

    -- Generate prompt
    left_prompt  <- generateSegment args `mapM` left  segments'
    right_prompt <- generateSegment args `mapM` right segments'

    -- Actually render the prompts
    let numSpaces = fromMaybe 1 $ spaces themeCfg
    let divCfg = themeCfg & dividers & fromJust
    let renderInfo = RenderInfo (colors colours) (groups cs) divCfg numSpaces
    term <- byteStringMakerFromEnvironment

    putStrLn "Left:"
    putChunks term . renderSegments renderInfo SLeft $ concat left_prompt
    putStrLn ""

    putStrLn "Right:"
    putChunks term . renderSegments renderInfo SRight $ concat right_prompt
    putStrLn ""


-- Loads a config file, throwing an exception if there was an error message
loadConfigFile :: FromJSON a => FilePath -> IO a
loadConfigFile path = do
    raw <- BSL.readFile path
    return $ fromRight $ eitherDecode raw

-- Loads multiple config files, merges them, then parses them. Merge is right-biased; last file in the list has precedence.
loadLayeredConfigFiles :: FromJSON a => [FilePath] -> IO a
loadLayeredConfigFiles paths = do
    objs <- mapM loadConfigFile paths :: IO [Value]
    let res = foldl1' mergeJson objs

    -- Convert to target type
    return . fromRight . eitherDecode $ encode res

-- Layer a segment over the corresponding segment data
layerSegments :: Map.Map String SegmentData -> Segment -> Segment
layerSegments segmentData s = Segment (function s) before' after' args' where
    -- for powerline.segments.common.net.hostname, assume the segment has key 'hostname'
    key = tail . takeExtension $ function s

    sd = Map.lookup key segmentData
    before' = before s <> (sdBefore =<< sd)
    after'  = after s  <> (sdAfter =<< sd)
    args' = Just $ leftBiasedMerge (maybeMap $ args s) (maybeMap $ sdArgs =<< sd)

    leftBiasedMerge :: SegmentArgs -> SegmentArgs -> SegmentArgs
    leftBiasedMerge = merge preserveMissing preserveMissing $ zipWithMatched (\_ -> flip mergeJson)
    maybeMap = fromMaybe Map.empty

-- Helper function for extracting result
fromRight :: Either String b -> b
fromRight (Left a)  = error a
fromRight (Right b) = b

