module Main (main) where

import Prelude

import Control.Monad (when)
import Data.Map qualified as M
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Language.PureScript qualified as P
import Language.PureScript.CST qualified as CST
import Language.PureScript.Make (buildMakeActions, inferForeignModules, runMake)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO.UTF8 (readUTF8FilesT)

main :: IO ()
main = do
  out : files <- getArgs
  t0 <- getCurrentTime
  moduleFiles <- readUTF8FilesT files
  let opts = P.Options False True (S.fromList [P.JS])
  (errs, warns) <- runMake opts $ do
    ms <- CST.parseModulesFromFiles id moduleFiles
    let filePathMap = M.fromList $ map (\(fp, pm) -> (P.getModuleName $ CST.resPartial pm, Right fp)) ms
    foreigns <- inferForeignModules filePathMap
    let actions = buildMakeActions out filePathMap foreigns False
    P.make actions (map snd ms)
  t1 <- getCurrentTime
  let ppe = P.defaultPPEOptions { P.ppeFileContents = moduleFiles }
  when (P.nonEmpty warns) $ putStrLn (P.prettyPrintMultipleWarnings ppe warns)
  case errs of
    Left e -> putStrLn (P.prettyPrintMultipleErrors ppe e) >> putStrLn "RESULT: errors" >> report t0 t1 >> exitFailure
    Right _ -> putStrLn "RESULT: ok" >> report t0 t1
  where
    report t0 t1 = putStrLn ("elapsed: " <> show (diffUTCTime t1 t0))
