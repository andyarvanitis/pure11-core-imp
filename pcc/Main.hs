-----------------------------------------------------------------------------
--
-- Module      :  Main
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds, GeneralizedNewtypeDeriving, TupleSections, RecordWildCards #-}

module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Trans.Except
import Control.Monad.Reader
import Control.Monad.Writer

import Data.Version (showVersion)
import Data.Traversable (traverse)

import Options.Applicative as Opts

import System.Directory
       (doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.Exit (exitSuccess, exitFailure)
import System.IO.Error (tryIOError)

import qualified Language.PureScript.Cpp as P
import qualified Paths_pure14 as Paths


data PSCMakeOptions = PSCMakeOptions
  { pscmInput     :: [FilePath]
  , pscmOutputDir :: FilePath
  , pscmOpts      :: P.Options P.Make
  , pscmUsePrefix :: Bool
  }

data InputOptions = InputOptions
  { ioNoPrelude   :: Bool
  , ioInputFiles  :: [FilePath]
  }

readInput :: InputOptions -> IO [(Either P.RebuildPolicy FilePath, String)]
readInput InputOptions{..} = forM ioInputFiles $ \inFile -> (Right inFile, ) <$> readFile inFile

newtype Make a = Make { unMake :: ReaderT (P.Options P.Make) (WriterT P.MultipleErrors (ExceptT P.MultipleErrors IO)) a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadError P.MultipleErrors, MonadWriter P.MultipleErrors, MonadReader (P.Options P.Make))

runMake :: P.Options P.Make -> Make a -> IO (Either P.MultipleErrors (a, P.MultipleErrors))
runMake opts = runExceptT . runWriterT . flip runReaderT opts . unMake

makeIO :: (IOError -> P.ErrorMessage) -> IO a -> Make a
makeIO f io = do
  e <- liftIO $ tryIOError io
  either (throwError . P.singleError . f) return e

instance P.MonadMake Make where
  getTimestamp path = makeIO (const (P.SimpleErrorWrapper $ P.CannotGetFileInfo path)) $ do
    exists <- doesFileExist path
    traverse (const $ getModificationTime path) $ guard exists
  readTextFile path = makeIO (const (P.SimpleErrorWrapper $ P.CannotReadFile path))$ do
    putStrLn $ "Reading " ++ path
    readFile path
  writeTextFile path text = makeIO (const (P.SimpleErrorWrapper $ P.CannotWriteFile path)) $ do
    mkdirp path
    putStrLn $ "Writing " ++ path
    writeFile path text
  progress = liftIO . putStrLn

compile :: PSCMakeOptions -> IO ()
compile (PSCMakeOptions input outputDir opts usePrefix) = do
  modules <- P.parseModulesFromFiles (either (const "") id) <$> readInput (InputOptions (P.optionsNoPrelude opts) input)
  case modules of
    Left err -> do
      print err
      exitFailure
    Right ms -> do
      e <- runMake opts $ P.make outputDir ms prefix
      case e of
        Left errs -> do
          putStrLn (P.prettyPrintMultipleErrors (P.optionsVerboseErrors opts) errs)
          exitFailure
        Right (_, warnings) -> do
          when (P.nonEmpty warnings) $
            putStrLn (P.prettyPrintMultipleWarnings (P.optionsVerboseErrors opts) warnings)
          exitSuccess
  where
    prefix = if usePrefix
               then ["Generated by pcc version " ++ showVersion Paths.version]
               else []

mkdirp :: FilePath -> IO ()
mkdirp = createDirectoryIfMissing True . takeDirectory

inputFile :: Parser FilePath
inputFile = strArgument $
     metavar "FILE"
  <> help "The input .purs file(s)"

outputDirectory :: Parser FilePath
outputDirectory = strOption $
     short 'o'
  <> long "output"
  <> Opts.value "output"
  <> showDefault
  <> help "The output directory"

noTco :: Parser Bool
noTco = switch $
     long "no-tco"
  <> help "Disable tail call optimizations"

noPrelude :: Parser Bool
noPrelude = switch $
     long "no-prelude"
  <> help "Omit the automatic Prelude import"

noMagicDo :: Parser Bool
noMagicDo = switch $
     long "no-magic-do"
  <> help "Disable the optimization that overloads the do keyword to generate efficient code specifically for the Eff monad."

noOpts :: Parser Bool
noOpts = switch $
     long "no-opts"
  <> help "Skip the optimization phase."

comments :: Parser Bool
comments = switch $
     short 'c'
  <> long "comments"
  <> help "Include comments in the generated code."

verboseErrors :: Parser Bool
verboseErrors = switch $
     short 'v'
  <> long "verbose-errors"
  <> help "Display verbose error messages"

noPrefix :: Parser Bool
noPrefix = switch $
     short 'p'
  <> long "no-prefix"
  <> help "Do not include comment header"


options :: Parser (P.Options P.Make)
options = P.Options <$> noPrelude
                    <*> noTco
                    <*> noMagicDo
                    <*> pure Nothing
                    <*> noOpts
                    <*> verboseErrors
                    <*> (not <$> comments)
                    <*> pure P.MakeOptions

pscMakeOptions :: Parser PSCMakeOptions
pscMakeOptions = PSCMakeOptions <$> many inputFile
                                <*> outputDirectory
                                <*> options
                                <*> (not <$> noPrefix)

main :: IO ()
main = execParser opts >>= compile
  where
  opts        = info (version <*> helper <*> pscMakeOptions) infoModList
  infoModList = fullDesc <> headerInfo <> footerInfo
  headerInfo  = header   "pcc - Compiles PureScript to C++11"
  footerInfo  = footer $ "pcc " ++ showVersion Paths.version

  version :: Parser (a -> a)
  version = abortOption (InfoMsg (showVersion Paths.version)) $ long "version" <> help "Show the version number" <> hidden
