{-# LANGUAGE OverloadedStrings #-}

module Rewrite
  ( Args (..),
    version,
    quotedUrls,
  )
where

import qualified Data.Text as T
import qualified File
import qualified Nix
import OurPrelude
import qualified Utils
  ( UpdateEnv (..),
  )
import Prelude hiding (log)

{-
 This module contains rewrite functions that make some modification to the
 nix derivation. These are in the IO monad so that they can do things like
 re-run nix-build to recompute hashes, but morally they should just stick to
 editing the derivationFile for their one stated purpose.

 The return contract is:
 - If it makes a modification, it can (optionally) return a message to attach
   to the pull request description to provide context or justification for
   code reviewers (e.g., a GitHub issue or RFC).
 - If it makes no modification or a straightforward modification, return None
 - If it throws an exception, nixpkgs-update will be aborted for the package and
   no other rewrite functions will run.

  TODO: Setup some unit tests for these!
-}
data Args
  = Args
      { updateEnv :: Utils.UpdateEnv,
        attrPath :: Text,
        derivationFile :: FilePath,
        derivationContents :: Text
      }

--------------------------------------------------------------------------------
-- The canonical updater: updates the src attribute and recomputes the sha256
version :: MonadIO m => (Text -> m ()) -> Args -> ExceptT Text m (Maybe Text)
version log (Args env attrPth drvFile _) = do
  lift $ log "[version] started"
  oldHash <- Nix.getOldHash attrPth
  -- Change the actual version
  lift $ File.replace (Utils.oldVersion env) (Utils.newVersion env) drvFile
  lift $ File.replace oldHash Nix.sha256Zero drvFile
  newHash <- Nix.getHashFromBuild attrPth
  lift $ File.replace Nix.sha256Zero newHash drvFile
  lift $ log "[version]: updated version and sha256"
  return Nothing

--------------------------------------------------------------------------------
-- Rewrite meta.homepage (and eventually other URLs) to be quoted if not
-- already, as per https://github.com/NixOS/rfcs/pull/45
quotedUrls :: MonadIO m => (Text -> m ()) -> Args -> ExceptT Text m (Maybe Text)
quotedUrls log (Args _ attrPth drvFile drvContents) = do
  lift $ log "[quotedUrls] started"
  homepage <- Nix.getHomepage attrPth
  if T.isInfixOf homepage drvContents
    then do
      lift $ log "meta.homepage is already correctly quoted"
      return Nothing
    else do
      -- Bit of a hack, but the homepage that comes out of nix-env is *always*
      -- quoted by the nix eval, so we drop the first and last characters.
      let stripped = T.init . T.tail $ homepage
      File.replace stripped homepage drvFile
      lift $ log "[quotedUrls]: added quotes to meta.homepage"
      return $ Just "Quoted meta.homepage for [RFC 45](https://github.com/NixOS/rfcs/pull/45)"