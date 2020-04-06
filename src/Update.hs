{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Update
  ( updateAll,
    updatePackage,
    cveReport,
    cveAll,
    sourceGithubAll,
    addPatched,
  )
where

import qualified Blacklist
import CVE (CVE, cveID, cveLI)
import qualified Check
import Control.Concurrent
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.IORef
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Calendar (showGregorian)
import Data.Time.Clock (UTCTime, getCurrentTime, utctDay)
import qualified GH
import qualified Git
import NVD (getCVEs, withVulnDB)
import qualified Nix
import OurPrelude
import Outpaths
import qualified Rewrite
import qualified Time
import Data.Maybe (fromJust)
import Utils
  ( Options (..),
    URL,
    UpdateEnv (..),
    Version,
    branchName,
    logDir,
    parseUpdates,
    prTitle,
  )
import qualified Version
import Prelude hiding (log)

default (T.Text)

data MergeBaseOutpathsInfo
  = MergeBaseOutpathsInfo
      { lastUpdated :: UTCTime,
        mergeBaseOutpaths :: Set ResultLine
      }

log' :: MonadIO m => FilePath -> Text -> m ()
log' logFile msg = do
  runDate <- liftIO $ runM $ Time.runIO Time.runDate
  liftIO $ T.appendFile logFile (runDate <> " " <> msg <> "\n")

logFileName :: IO String
logFileName = do
  lDir <- logDir
  now <- getCurrentTime
  let logFile = lDir <> "/" <> showGregorian (utctDay now) <> ".log"
  putStrLn ("Using log file: " <> logFile)
  return logFile

getLog :: Options -> IO (Text -> IO ())
getLog o = do
  if batchUpdate o
    then do
      logFile <- logFileName
      let log = log' logFile
      T.appendFile logFile "\n\n"
      return log
    else
      return T.putStrLn

updateAll :: Options -> Text -> IO ()
updateAll o updates = do
  log <- getLog o
  log "New run of nixpkgs-update"
  when (doPR o) $ log "Will do push to origin and do PR on success."
  when (pushToCachix o) $ log "Will push to cachix."
  when (calculateOutpaths o) $ log "Will calculate outpaths."
  twoHoursAgo <- runM $ Time.runIO Time.twoHoursAgo
  mergeBaseOutpathSet <-
    liftIO $ newIORef (MergeBaseOutpathsInfo twoHoursAgo S.empty)
  updateLoop o log (parseUpdates updates) mergeBaseOutpathSet

cveAll :: Options -> Text -> IO ()
cveAll o updates = do
  let u' = rights $ parseUpdates updates
  results <-
    mapM
      ( \(p, oldV, newV, url) -> do
          r <- cveReport (UpdateEnv p oldV newV url o)
          return $ p <> ": " <> oldV <> " -> " <> newV <> "\n" <> r
      )
      u'
  T.putStrLn (T.unlines results)

sourceGithubAll :: Options -> Text -> IO ()
sourceGithubAll o updates = do
  let u' = rights $ parseUpdates updates
  _ <-
    runExceptT $ do
      Git.fetchIfStale <|> liftIO (T.putStrLn "Failed to fetch.")
      Git.cleanAndResetTo "master"
  mapM_
    ( \(p, oldV, newV, url) -> do
        let updateEnv = UpdateEnv p oldV newV url o
        runExceptT $ do
          attrPath <- Nix.lookupAttrPath updateEnv
          srcUrl <- Nix.getSrcUrl attrPath
          v <- GH.latestVersion updateEnv srcUrl
          if v /= newV
            then
              liftIO
                $ T.putStrLn
                $ p <> ": " <> oldV <> " -> " <> newV <> " -> " <> v
            else return ()
    )
    u'

updateLoop ::
  Options ->
  (Text -> IO ()) ->
  [Either Text (Text, Version, Version, Maybe URL)] ->
  IORef MergeBaseOutpathsInfo ->
  IO ()
updateLoop _ log [] _ = log "nixpkgs-update finished"
updateLoop o log (Left e : moreUpdates) mergeBaseOutpathsContext = do
  log e
  updateLoop o log moreUpdates mergeBaseOutpathsContext
updateLoop o log (Right (pName, oldVer, newVer, url) : moreUpdates) mergeBaseOutpathsContext = do
  log (pName <> " " <> oldVer <> " -> " <> newVer <> fromMaybe "" (fmap (" " <>) url))
  let updateEnv = UpdateEnv pName oldVer newVer url o
  updated <- updatePackageBatch log updateEnv mergeBaseOutpathsContext
  case updated of
    Left failure -> do
      log $ "FAIL " <> failure
      cleanupResult <- runExceptT $ Git.cleanup (branchName updateEnv)
      case cleanupResult of
        Left e -> liftIO $ print e
        _ ->
          if ".0" `T.isSuffixOf` newVer
            then
              let Just newNewVersion = ".0" `T.stripSuffix` newVer
               in updateLoop
                    o
                    log
                    (Right (pName, oldVer, newNewVersion, url) : moreUpdates)
                    mergeBaseOutpathsContext
            else updateLoop o log moreUpdates mergeBaseOutpathsContext
    Right _ -> do
      log "SUCCESS"
      updateLoop o log moreUpdates mergeBaseOutpathsContext

-- Arguments this function should have to make it testable:
-- - the merge base commit (should be updated externally to this function)
-- - the merge base context should be updated externally to this function
-- - the commit for branches: master, staging, staging-next, python-unstable
updatePackageBatch ::
  (Text -> IO ()) ->
  UpdateEnv ->
  IORef MergeBaseOutpathsInfo ->
  IO (Either Text ())
updatePackageBatch log updateEnv mergeBaseOutpathsContext =
  runExceptT $ do
    let pr = doPR . options $ updateEnv
    --
    -- Filters that don't need git
    Blacklist.packageName (packageName updateEnv)
    Nix.assertNewerVersion updateEnv
    --
    -- Update our git checkout
    Git.fetchIfStale <|> liftIO (T.putStrLn "Failed to fetch.")
    unless pr $
      Git.checkAutoUpdateBranchDoesntExist (packageName updateEnv)
    Git.cleanAndResetTo "master"
    --
    -- Filters: various cases where we shouldn't update the package
    attrPath <- Nix.lookupAttrPath updateEnv
    unless pr $
      GH.checkExistingUpdatePR updateEnv attrPath
    Blacklist.attrPath attrPath
    Version.assertCompatibleWithPathPin updateEnv attrPath
    srcUrls <- Nix.getSrcUrls attrPath
    Blacklist.srcUrl srcUrls
    derivationFile <- Nix.getDerivationFile attrPath
    assertNotUpdatedOn updateEnv derivationFile "master"
    assertNotUpdatedOn updateEnv derivationFile "staging"
    assertNotUpdatedOn updateEnv derivationFile "staging-next"
    assertNotUpdatedOn updateEnv derivationFile "python-unstable"
    --
    -- Calculate output paths for rebuilds and our merge base
    Git.checkoutAtMergeBase (branchName updateEnv)
    let calcOutpaths = calculateOutpaths . options $ updateEnv
    oneHourAgo <- liftIO $ runM $ Time.runIO Time.oneHourAgo
    mergeBaseOutpathsInfo <- liftIO $ readIORef mergeBaseOutpathsContext
    mergeBaseOutpathSet <-
      if calcOutpaths && lastUpdated mergeBaseOutpathsInfo < oneHourAgo
        then do
          mbos <- currentOutpathSet
          now <- liftIO getCurrentTime
          liftIO $
            writeIORef mergeBaseOutpathsContext (MergeBaseOutpathsInfo now mbos)
          return mbos
        else
          if calcOutpaths
            then return $ mergeBaseOutpaths mergeBaseOutpathsInfo
            else return $ dummyOutpathSetBefore attrPath
    --
    -- Get the original values for diffing purposes
    derivationContents <- liftIO $ T.readFile derivationFile
    oldHash <- Nix.getOldHash attrPath
    oldSrcUrl <- Nix.getSrcUrl attrPath
    --
    -- One final filter
    Blacklist.content derivationContents
    --
    ----------------------------------------------------------------------------
    -- UPDATES
    -- At this point, we've stashed the old derivation contents and validated
    -- that we actually should be touching this file. Get to work processing the
    -- various rewrite functions!
    let rwArgs = Rewrite.Args updateEnv attrPath derivationFile derivationContents
    msgs <- Rewrite.runAll log rwArgs
    ----------------------------------------------------------------------------
    --
    -- Compute the diff and get updated values
    diffAfterRewrites <- Git.diff
    lift . log $ "Diff after rewrites:\n" <> diffAfterRewrites
    updatedDerivationContents <- liftIO $ T.readFile derivationFile
    newSrcUrl <- Nix.getSrcUrl attrPath
    newHash <- Nix.getHash attrPath
    -- Sanity checks to make sure the PR is worth opening
    when (derivationContents == updatedDerivationContents) $ throwE "No rewrites performed on derivation."
    when (oldSrcUrl == newSrcUrl) $ throwE "Source url did not change. "
    when (oldHash == newHash) $ throwE "Hashes equal; no update necessary"
    editedOutpathSet <- if calcOutpaths then currentOutpathSet else return $ dummyOutpathSetAfter attrPath
    let opDiff = S.difference mergeBaseOutpathSet editedOutpathSet
    let numPRebuilds = numPackageRebuilds opDiff
    Blacklist.python numPRebuilds derivationContents
    when (numPRebuilds == 0) (throwE "Update edits cause no rebuilds.")
    Nix.build attrPath
    --
    -- Publish the result
    lift . log $ "Successfully finished processing"
    result <- Nix.resultLink
    publishPackage log updateEnv oldSrcUrl newSrcUrl attrPath result (Just opDiff) msgs

publishPackage ::
  MonadIO m =>
  (Text -> m ()) ->
  UpdateEnv ->
  Text ->
  Text ->
  Text ->
  Text ->
  Maybe (Set ResultLine) ->
  [Text] ->
  ExceptT Text m ()
publishPackage log updateEnv oldSrcUrl newSrcUrl attrPath result opDiff msgs = do
  cachixTestInstructions <- doCachix log updateEnv result
  resultCheckReport <-
    case Blacklist.checkResult (packageName updateEnv) of
      Right () -> lift $ Check.result updateEnv (T.unpack result)
      Left msg -> pure msg
  d <- Nix.getDescription attrPath <|> return T.empty
  u <- Nix.getHomepageET attrPath <|> return T.empty
  cveRep <- liftIO $ cveReport updateEnv
  let metaDescription =
        if d == T.empty
          then ""
          else "\n\nmeta.description for " <> attrPath <> " is: " <> d
  let metaHomepage =
        if u == T.empty
          then ""
          else "\n\nmeta.homepage for " <> attrPath <> " is: " <> u
  let rewriteMessages = foldl (\ms m -> ms <> T.pack "\n- " <> m) "\nUpdates performed:" msgs
  releaseUrlMessage <-
    ( do
        msg <- GH.releaseUrl updateEnv newSrcUrl
        return ("\n[Release on GitHub](" <> msg <> ")\n\n")
      )
      <|> return ""
  compareUrlMessage <-
    ( do
        msg <- GH.compareUrl oldSrcUrl newSrcUrl
        return ("\n[Compare changes on GitHub](" <> msg <> ")\n\n")
      )
      <|> return "\n"
  maintainers <- Nix.getMaintainers attrPath
  let maintainersCc =
        if not (T.null maintainers)
          then "\n\ncc " <> maintainers <> " for testing."
          else ""
  let commitMsg = commitMessage updateEnv attrPath
  Git.commit commitMsg
  commitHash <- Git.headHash
  -- Try to push it three times
  when (doPR . options $ updateEnv)
    (Git.push updateEnv <|> Git.push updateEnv <|> Git.push updateEnv)
  isBroken <- Nix.getIsBroken attrPath
  when (batchUpdate . options $ updateEnv)
    (lift untilOfBorgFree)
  let prMsg = prMessage
          updateEnv
          isBroken
          metaDescription
          metaHomepage
          rewriteMessages
          releaseUrlMessage
          compareUrlMessage
          resultCheckReport
          commitHash
          attrPath
          maintainersCc
          result
          (fromMaybe "" (outpathReport <$> opDiff))
          cveRep
          cachixTestInstructions
  if (doPR . options $ updateEnv)
  then do
    let base = if (isNothing opDiff || numPackageRebuilds (fromJust opDiff) < 100)
        then "master"
        else "staging"
    lift $ GH.pr base prMsg
  else liftIO $ T.putStrLn prMsg
  Git.cleanAndResetTo "master"

commitMessage :: UpdateEnv -> Text -> Text
commitMessage updateEnv attrPath = prTitle updateEnv attrPath

brokenWarning :: Bool -> Text
brokenWarning False = ""
brokenWarning True =
  "- WARNING: Package has meta.broken=true; Please manually test this package update and remove the broken attribute."

prMessage ::
  UpdateEnv ->
  Bool ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text
prMessage updateEnv isBroken metaDescription metaHomepage rewriteMessages releaseUrlMessage compareUrlMessage resultCheckReport commitHash attrPath maintainersCc resultPath opReport cveRep cachixTestInstructions =
  let brokenMsg = brokenWarning isBroken
      title = prTitle updateEnv attrPath
      sourceLinkInfo = maybe "" pattern $ sourceURL updateEnv
        where
          pattern link = [interpolate|This update was made based on information from $link.|]
   in [interpolate|
       $title

       Semi-automatic update generated by [nixpkgs-update](https://github.com/ryantm/nixpkgs-update) tools. $sourceLinkInfo
       $brokenMsg
       $metaDescription
       $metaHomepage
       $rewriteMessages
       $releaseUrlMessage
       $compareUrlMessage
       <details>
       <summary>
       Checks done (click to expand)
       </summary>

       - built on NixOS
       $resultCheckReport

       </details>
       <details>
       <summary>
       Rebuild report (if merged into master) (click to expand)
       </summary>

       $opReport

       </details>

       <details>
       <summary>
       Instructions to test this update (click to expand)
       </summary>

       $cachixTestInstructions
       ```
       nix-build -A $attrPath https://github.com/r-ryantm/nixpkgs/archive/$commitHash.tar.gz
       ```

       After you've downloaded or built it, look at the files and if there are any, run the binaries:
       ```
       ls -la $resultPath
       ls -la $resultPath/bin
       ```


       </details>
       <br/>
       $cveRep

       $maintainersCc
    |]

untilOfBorgFree :: MonadIO m => m ()
untilOfBorgFree = do
  stats <-
    shell "curl -s https://events.nix.ci/stats.php" & readProcessInterleaved_
  waiting <-
    shell "jq .evaluator.messages.waiting" & setStdin (byteStringInput stats)
      & readProcessInterleaved_
      & fmap (BSL.readInt >>> fmap fst >>> fromMaybe 0)
  when (waiting > 2) $ do
    liftIO $ threadDelay 60000000
    untilOfBorgFree

assertNotUpdatedOn ::
  MonadIO m => UpdateEnv -> FilePath -> Text -> ExceptT Text m ()
assertNotUpdatedOn updateEnv derivationFile branch = do
  Git.cleanAndResetTo branch
  derivationContents <- fmapLT tshow $ tryIO $ T.readFile derivationFile
  Nix.assertOldVersionOn updateEnv branch derivationContents

addPatched :: Text -> Set CVE -> IO [(CVE, Bool)]
addPatched attrPath set = do
  let list = S.toList set
  forM
    list
    ( \cve -> do
        patched <- runExceptT $ Nix.hasPatchNamed attrPath (cveID cve)
        let p =
              case patched of
                Left _ -> False
                Right r -> r
        return (cve, p)
    )

cveReport :: UpdateEnv -> IO Text
cveReport updateEnv =
  withVulnDB $ \conn -> do
    let pname1 = packageName updateEnv
    let pname2 = T.replace "-" "_" pname1
    oldCVEs1 <- getCVEs conn pname1 (oldVersion updateEnv)
    oldCVEs2 <- getCVEs conn pname2 (oldVersion updateEnv)
    let oldCVEs = S.fromList (oldCVEs1 ++ oldCVEs2)
    newCVEs1 <- getCVEs conn pname1 (newVersion updateEnv)
    newCVEs2 <- getCVEs conn pname2 (newVersion updateEnv)
    let newCVEs = S.fromList (newCVEs1 ++ newCVEs2)
    let inOldButNotNew = S.difference oldCVEs newCVEs
        inNewButNotOld = S.difference newCVEs oldCVEs
        inBoth = S.intersection oldCVEs newCVEs
        ifEmptyNone t =
          if t == T.empty
            then "none"
            else t
    inOldButNotNew' <- addPatched (packageName updateEnv) inOldButNotNew
    inNewButNotOld' <- addPatched (packageName updateEnv) inNewButNotOld
    inBoth' <- addPatched (packageName updateEnv) inBoth
    let toMkdownList = fmap (uncurry cveLI) >>> T.unlines >>> ifEmptyNone
        fixedList = toMkdownList inOldButNotNew'
        newList = toMkdownList inNewButNotOld'
        unresolvedList = toMkdownList inBoth'
    if fixedList == "none" && unresolvedList == "none" && newList == "none"
      then return ""
      else
        return
          [interpolate|
      <details>
      <summary>
      Security report (click to expand)
      </summary>

      CVEs resolved by this update:
      $fixedList

      CVEs introduced by this update:
      $newList

      CVEs present in both versions:
      $unresolvedList


       </details>
       <br/>
      |]

doCachix :: MonadIO m => (Text -> m ()) -> UpdateEnv -> Text -> ExceptT Text m Text
doCachix log updateEnv resultPath =
  if pushToCachix (options updateEnv)
    then do
      lift $ log ("cachix " <> (T.pack . show) resultPath)
      Nix.cachix resultPath
      return
        [interpolate|
       Either download from Cachix:
       ```
       nix-store -r $resultPath \
         --option binary-caches 'https://cache.nixos.org/ https://r-ryantm.cachix.org/' \
         --option trusted-public-keys '
         r-ryantm.cachix.org-1:gkUbLkouDAyvBdpBX0JOdIiD2/DP1ldF3Z3Y6Gqcc4c=
         cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
         '
       ```
       (r-ryantm's Cachix cache is only trusted for this store-path realization.)
       For the Cachix download to work, your user must be in the `trusted-users` list or you can use `sudo` since root is effectively trusted.

       Or, build yourself:
       |]
    else do
      lift $ log "skipping cachix"
      return "Build yourself:"

updatePackage ::
  Options ->
  Text ->
  IO (Either Text ())
updatePackage o updateInfo = do
  runExceptT $ do
    let (p, oldV, newV, url) = head (rights (parseUpdates updateInfo))
    let updateEnv = UpdateEnv p oldV newV url o
    let log = T.putStrLn
    Nix.assertNewerVersion updateEnv
    attrPath <- Nix.lookupAttrPath updateEnv
    Version.assertCompatibleWithPathPin updateEnv attrPath
    derivationFile <- Nix.getDerivationFile attrPath
    --
    -- Get the original values for diffing purposes
    derivationContents <- liftIO $ T.readFile derivationFile
    oldHash <- Nix.getOldHash attrPath
    oldSrcUrl <- Nix.getSrcUrl attrPath
    --
    ----------------------------------------------------------------------------
    -- UPDATES
    -- At this point, we've stashed the old derivation contents and validated
    -- that we actually should be touching this file. Get to work processing the
    -- various rewrite functions!
    let rwArgs = Rewrite.Args updateEnv attrPath derivationFile derivationContents
    msgs <- Rewrite.runAll log rwArgs
    ----------------------------------------------------------------------------
    --
    -- Compute the diff and get updated values
    diffAfterRewrites <- Git.diff
    lift . log $ "Diff after rewrites:\n" <> diffAfterRewrites
    updatedDerivationContents <- liftIO $ T.readFile derivationFile
    newSrcUrl <- Nix.getSrcUrl attrPath
    newHash <- Nix.getHash attrPath
    -- Sanity checks to make sure the PR is worth opening
    when (derivationContents == updatedDerivationContents) $ throwE "No rewrites performed on derivation."
    when (oldSrcUrl == newSrcUrl) $ throwE "Source url did not change. "
    when (oldHash == newHash) $ throwE "Hashes equal; no update necessary"
    Nix.build attrPath
    --
    -- Publish the result
    lift . log $ "Successfully finished processing"
    result <- Nix.resultLink
    publishPackage log updateEnv oldSrcUrl newSrcUrl attrPath result Nothing msgs
