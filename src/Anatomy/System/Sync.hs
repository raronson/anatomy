{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Anatomy.System.Sync (
    syncRepositories
  , syncHooks
  , syncBuilds
  , githubprojects
  , newprojects
  , hookable
  , jenkinsable
  , syncReport
  , renderProjectReport
  , genModJob
  , updateRepository
  ) where

import           Anatomy.Data

import           Control.Concurrent (threadDelay)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Either
import           Control.Monad.IO.Class
import           Control.Retry

import qualified Anatomy.Ci.GitHub as G
import qualified Anatomy.Ci.Jenkins as J
import           Anatomy.System.XmlDiff

import qualified Data.Text as T

import           Github.Repos (Error, NewOrgRepo (..), createOrganizationRepo, newOrgRepo)
import qualified Github.Repos.Branches as GB
import qualified Github.Organizations as GO

import           P

import           System.IO
import           System.IO.Temp
import           System.Process


-- | Create github repos for things listed in anatomy but don't have
--   github repositories.  Repositories will be created with owner
--   specified by "team" argument. This is normally owners and extra
--   teams are specified as permissions elsewhere (but that bit isn't
--   implemented yet ...)
syncRepositories :: GithubAuth -> (a -> Maybe GithubTemplate) -> Org -> Team -> [Project a b c] -> EitherT GithubCreateError IO ()
syncRepositories auth templateName o admins projects = do
  forM_ projects $ \p -> do
    createRepository auth templateName o p
    updateRepository auth o admins p

syncHooks :: GithubAuth -> HipchatToken -> HipchatRoom -> Org -> HooksUrl -> [Project a b c] -> EitherT Error IO ()
syncHooks auth token room o h projects =
  forM_ projects $
    G.hook h token room auth o . name

syncBuilds :: JenkinsConfiguration -> [Project a b c] -> EitherT SyncBuildError IO ()
syncBuilds conf projects =
  forM_ projects $ \p -> do
    -- Don't spam jenkins, its a little fragile.
    liftIO $ threadDelay 200000 {-- 200 ms --}

    forM (builds p) $
      syncBuild conf p

syncBuild :: JenkinsConfiguration -> Project a b c -> Build -> EitherT SyncBuildError IO ()
syncBuild conf p b = do
  let mj = genModJob p b
  let createOrUpdate = retry $ J.createOrUpdateJob conf mj

  currentJob <- lift . retry $ getJob conf b

  case currentJob of
    Nothing ->
      lift createOrUpdate
    Just currentJob' -> do
      expectedJob <- lift . J.generateJob $ mj

      case xmlDiffText currentJob' expectedJob of
        Left e ->
          left $ XmlError b e

        Right (Right ()) ->
          right ()

        Right (Left (XmlDiff e (n1, n2))) -> do
          lift . putStrLn . T.unpack $ "Job '" <> buildName b <> "' has changed at " <> elementsPath e
            <> " from " <> (T.pack . show) n1
            <> " to " <> (T.pack . show) n2
          lift createOrUpdate

getJob :: JenkinsConfiguration -> Build -> IO (Maybe Text)
getJob conf b = do
  e <- J.getJob conf (J.JobName $ buildName b)
  pure $ rightToMaybe e

-- | Log sync reporting for the specified projects.
syncReport :: [Project a b c] -> IO ()
syncReport ps =
  forM_ ps $ \p ->
    putStrLn . T.unpack . T.intercalate " " $ [
        "new github project:"
      , renderName . name $ p
      ]

renderProjectReport :: Project a b c -> Text
renderProjectReport p =
  T.intercalate " " $ [
      "new github project:"
    , renderName . name $ p
    ]

githubprojects :: [Report a b c] -> [Project a b c]
githubprojects rs =
  rs >>= \r -> case r of
    Report Nothing Nothing ->
      []
    Report (Just p) (Just _) ->
      [p]
    Report Nothing (Just _) ->
      []
    Report (Just _) Nothing ->
      []

newprojects :: [Report a b c] -> [Project a b c]
newprojects rs =
  rs >>= \r -> case r of
    Report Nothing Nothing ->
      []
    Report (Just _) (Just _) ->
      []
    Report Nothing (Just _) ->
      []
    Report (Just p) Nothing ->
      [p]

hookable :: [Report a b c] -> [Project a b c]
hookable rs =
  rs >>= \r ->
    case r of
      Report Nothing Nothing ->
        []
      Report (Just _) Nothing ->
        []
      Report Nothing (Just _) ->
        []
      Report (Just p) (Just _) ->
        [p]

jenkinsable :: [Report a b c] -> [Project a b c]
jenkinsable rs =
  rs >>= \r ->
    case r of
      Report (Just p) _ ->
        [p]
      Report _ _ ->
        []

createRepository :: GithubAuth -> (a -> Maybe GithubTemplate) -> Org -> Project a b c -> EitherT GithubCreateError IO ()
createRepository auth templateName o p = do
  let org = T.unpack . orgName $ o
      repo = T.unpack . renderName . name $ p
  void . bimapEitherT CreateRepoError id . EitherT $
    createOrganizationRepo auth org (newOrgRepo repo) {
        newOrgRepoDescription = Just . T.unpack . description $ p
      , newOrgRepoPrivate = Just True
      , newOrgRepoHasIssues = Just True
      , newOrgRepoHasWiki = Just False
      , newOrgRepoHasDownloads = Just False
      , newOrgRepoTeamId = Nothing
      , newOrgRepoAutoInit = Just False
      , newOrgRepoLicense = Nothing
      , newOrgRepoGitIgnore = Nothing
      }
  forM_ (templateName $ cls p) $
    lift . pushTemplate p

-- Permissions only for the time being
updateRepository :: GithubAuth -> Org -> Team -> Project a b c -> EitherT GithubCreateError IO ()
updateRepository auth o admins p = do
  let org = T.unpack . orgName $ o
      repo = T.unpack . renderName . name $ p
  void . bimapEitherT AddTeamError id . EitherT $
    GO.addTeamToRepo auth (teamGithubId admins) org repo (Just PermissionAdmin)
  forM_ (teams p) $ \tm ->
    void . bimapEitherT AddTeamError id . EitherT $
      GO.addTeamToRepo auth (teamGithubId tm) org repo (teamPermission tm)
  forM_ (branchProtection p) $ \(b, pro) ->
    bimapEitherT AddProtectionError id . EitherT $
      GB.protect auth org repo (T.unpack $ renderBranch b) (Just pro)

genModJob :: Project a b c -> Build -> J.ModJob
genModJob p b =
  J.ModJob {
      J.modName = J.JobName $ buildName b
    , J.jobTemplate = template b
    , J.params = toParams p $ replacements b
    }

toParams :: Project a b c -> [Replace] -> Text -> Maybe Text
toParams p rs s = case s of
  "project" ->
    Just . renderName . name $ p
  _ ->
    fmap replaceValue . flip P.find rs $ \r ->
      replaceKey r == s

pushTemplate :: Project a b c -> GithubTemplate -> IO ()
pushTemplate p t =
  void . withSystemTempDirectory "template_repo" $ \dir ->
    system $ P.intercalate " " ["./bin/clone_template", dir, T.unpack . githubTemplate $ t, T.unpack . renderName . name $ p]
