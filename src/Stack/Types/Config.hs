{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DefaultSignatures     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}

-- | The Config type.

module Stack.Types.Config
  (
  -- * Main configuration types and classes
  -- ** Config & HasConfig
    Config (..)
  , HasConfig (..)
  , askLatestSnapshotUrl
  , configProjectRoot
  -- * Details
  -- ** GlobalOpts & GlobalOptsMonoid
  , defaultLogLevel
  -- ** Project & ProjectAndConfigMonoid
  , Project (..)
  , ProjectConfig (..)
  , Curator (..)
  , ProjectAndConfigMonoid (..)
  , parseProjectAndConfigMonoid
  -- ** Styles
  , readStyles
  -- * Paths
  , bindirSuffix
  , GlobalInfoSource (..)
  , docDirSuffix
  , platformOnlyRelDir
  , workDirL
  , ghcInstallHook
  -- * Command-related types
  , module X
  -- * Lens helpers
  , ExtraDirs (..)
  , buildOptsL
  , globalOptsL
  , globalOptsBuildOptsMonoidL
  , stackRootL
  , stackGlobalConfigL
  , whichCompilerL
  , envOverrideSettingsL
  -- * Helper logging functions
  , prettyStackDevL
  -- * Lens reexport
  , view
  , to
  ) where

import           Pantry.Internal.AesonExtended
                   ( FromJSON (..), ToJSON (..), Value, WithJSONWarnings (..)
                   , (.=), (...:), (..:?), (..!=), jsonSubWarnings
                   , jsonSubWarningsT, jsonSubWarningsTT, object
                   , withObjectWarnings
                   )
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Yaml as Yaml
import           Distribution.System ( Platform )
import           Generics.Deriving.Monoid ( mappenddefault, memptydefault )
import           Options.Applicative ( ReadM )
import qualified Options.Applicative.Types as OA
import           Path ( (</>), parent, reldir, relfile )
import           RIO.Process ( HasProcessContext (..), ProcessContext )
import           Stack.Constants ( bindirSuffix, docDirSuffix )
import           Stack.Prelude
import           Stack.Types.ApplyGhcOptions ( ApplyGhcOptions (..) )
import           Stack.Types.CabalConfigKey ( CabalConfigKey )
import           Stack.Types.Compiler
                   ( ActualCompiler (..), CompilerRepository, WhichCompiler
                   , whichCompiler
                   )
import           Stack.Types.CompilerBuild ( CompilerBuild )
import           Stack.Types.ConfigMonoid
                   ( ConfigMonoid (..), parseConfigMonoidObject)
import           Stack.Types.Docker ( DockerOpts )
import           Stack.Types.DumpLogs ( DumpLogs )
import           Stack.Types.EnvSettings ( EnvSettings )
import           Stack.Types.GHCVariant ( GHCVariant (..), HasGHCVariant (..) )
import           Stack.Types.GlobalOpts ( GlobalOpts (..) )
import           Stack.Types.Nix ( NixOpts )
import           Stack.Types.Platform
                   ( HasPlatform (..), PlatformVariant, platformOnlyRelDir
                   )
import           Stack.Types.PvpBounds ( PvpBounds )
import           Stack.Types.Resolver ( AbstractResolver )
import           Stack.Types.Runner ( HasRunner (..), Runner, globalOptsL )
import           Stack.Types.SCM ( SCM )
import           Stack.Types.SetupInfo ( SetupInfo )
import           Stack.Types.Storage ( UserStorage )
import           Stack.Types.TemplateName ( TemplateName )
import           Stack.Types.Version ( VersionCheck (..), VersionRange )

-- Re-exports
import           Stack.Types.Config.Build as X

-- | The top-level Stackage configuration.
data Config = Config
  { configWorkDir             :: !(Path Rel Dir)
    -- ^ this allows to override .stack-work directory
  , configUserConfigPath      :: !(Path Abs File)
    -- ^ Path to user configuration file (usually ~/.stack/config.yaml)
  , configBuild               :: !BuildOpts
    -- ^ Build configuration
  , configDocker              :: !DockerOpts
    -- ^ Docker configuration
  , configNix                 :: !NixOpts
    -- ^ Execution environment (e.g nix-shell) configuration
  , configProcessContextSettings :: !(EnvSettings -> IO ProcessContext)
    -- ^ Environment variables to be passed to external tools
  , configLocalProgramsBase   :: !(Path Abs Dir)
    -- ^ Non-platform-specific path containing local installations
  , configLocalPrograms       :: !(Path Abs Dir)
    -- ^ Path containing local installations (mainly GHC)
  , configHideTHLoading       :: !Bool
    -- ^ Hide the Template Haskell "Loading package ..." messages from the
    -- console
  , configPrefixTimestamps    :: !Bool
    -- ^ Prefix build output with timestamps for each line.
  , configPlatform            :: !Platform
    -- ^ The platform we're building for, used in many directory names
  , configPlatformVariant     :: !PlatformVariant
    -- ^ Variant of the platform, also used in directory names
  , configGHCVariant          :: !(Maybe GHCVariant)
    -- ^ The variant of GHC requested by the user.
  , configGHCBuild            :: !(Maybe CompilerBuild)
    -- ^ Override build of the compiler distribution (e.g. standard, gmp4,
    -- tinfo6)
  , configLatestSnapshot      :: !Text
    -- ^ URL of a JSON file providing the latest LTS and Nightly snapshots.
  , configSystemGHC           :: !Bool
    -- ^ Should we use the system-installed GHC (on the PATH) if
    -- available? Can be overridden by command line options.
  , configInstallGHC          :: !Bool
    -- ^ Should we automatically install GHC if missing or the wrong
    -- version is available? Can be overridden by command line options.
  , configSkipGHCCheck        :: !Bool
    -- ^ Don't bother checking the GHC version or architecture.
  , configSkipMsys            :: !Bool
    -- ^ On Windows: don't use a sandboxed MSYS
  , configCompilerCheck       :: !VersionCheck
    -- ^ Specifies which versions of the compiler are acceptable.
  , configCompilerRepository  :: !CompilerRepository
    -- ^ Specifies the repository containing the compiler sources
  , configLocalBin            :: !(Path Abs Dir)
    -- ^ Directory we should install executables into
  , configRequireStackVersion :: !VersionRange
    -- ^ Require a version of Stack within this range.
  , configJobs                :: !Int
    -- ^ How many concurrent jobs to run, defaults to number of capabilities
  , configOverrideGccPath     :: !(Maybe (Path Abs File))
    -- ^ Optional gcc override path
  , configExtraIncludeDirs    :: ![FilePath]
    -- ^ --extra-include-dirs arguments
  , configExtraLibDirs        :: ![FilePath]
    -- ^ --extra-lib-dirs arguments
  , configCustomPreprocessorExts :: ![Text]
    -- ^ List of custom preprocessors to complete the hard coded ones
  , configConcurrentTests     :: !Bool
    -- ^ Run test suites concurrently
  , configTemplateParams      :: !(Map Text Text)
    -- ^ Parameters for templates.
  , configScmInit             :: !(Maybe SCM)
    -- ^ Initialize SCM (e.g. git) when creating new projects.
  , configGhcOptionsByName    :: !(Map PackageName [Text])
    -- ^ Additional GHC options to apply to specific packages.
  , configGhcOptionsByCat     :: !(Map ApplyGhcOptions [Text])
    -- ^ Additional GHC options to apply to categories of packages
  , configCabalConfigOpts     :: !(Map CabalConfigKey [Text])
    -- ^ Additional options to be passed to ./Setup.hs configure
  , configSetupInfoLocations  :: ![String]
    -- ^ URLs or paths to stack-setup.yaml files, for finding tools.
    -- If none present, the default setup-info is used.
  , configSetupInfoInline     :: !SetupInfo
    -- ^ Additional SetupInfo to use to find tools.
  , configPvpBounds           :: !PvpBounds
    -- ^ How PVP upper bounds should be added to packages
  , configModifyCodePage      :: !Bool
    -- ^ Force the code page to UTF-8 on Windows
  , configRebuildGhcOptions   :: !Bool
    -- ^ Rebuild on GHC options changes
  , configApplyGhcOptions     :: !ApplyGhcOptions
    -- ^ Which packages to ghc-options on the command line apply to?
  , configAllowNewer          :: !Bool
    -- ^ Ignore version ranges in .cabal files. Funny naming chosen to
    -- match cabal.
  , configAllowNewerDeps      :: !(Maybe [PackageName])
    -- ^ Ignore dependency upper and lower bounds only for specified
    -- packages. No effect unless allow-newer is enabled.
  , configDefaultTemplate     :: !(Maybe TemplateName)
    -- ^ The default template to use when none is specified.
    -- (If Nothing, the 'default' default template is used.)
  , configAllowDifferentUser  :: !Bool
    -- ^ Allow users other than the Stack root owner to use the Stack
    -- installation.
  , configDumpLogs            :: !DumpLogs
    -- ^ Dump logs of local non-dependencies when doing a build.
  , configProject             :: !(ProjectConfig (Project, Path Abs File))
    -- ^ Project information and stack.yaml file location
  , configAllowLocals         :: !Bool
    -- ^ Are we allowed to build local packages? The script
    -- command disallows this.
  , configSaveHackageCreds    :: !Bool
    -- ^ Should we save Hackage credentials to a file?
  , configHackageBaseUrl      :: !Text
    -- ^ Hackage base URL used when uploading packages
  , configRunner              :: !Runner
  , configPantryConfig        :: !PantryConfig
  , configStackRoot           :: !(Path Abs Dir)
  , configResolver            :: !(Maybe AbstractResolver)
    -- ^ Any resolver override from the command line
  , configUserStorage         :: !UserStorage
    -- ^ Database connection pool for user Stack database
  , configHideSourcePaths     :: !Bool
    -- ^ Enable GHC hiding source paths?
  , configRecommendUpgrade    :: !Bool
    -- ^ Recommend a Stack upgrade?
  , configNoRunCompile   :: !Bool
    -- ^ Use --no-run and --compile options when using `stack script`
  , configStackDeveloperMode  :: !Bool
    -- ^ Turn on Stack developer mode for additional messages?
  }

-- | The project root directory, if in a project.
configProjectRoot :: Config -> Maybe (Path Abs Dir)
configProjectRoot c =
  case configProject c of
    PCProject (_, fp) -> Just $ parent fp
    PCGlobalProject -> Nothing
    PCNoProject _deps -> Nothing

-- | Project configuration information. Not every run of Stack has a
-- true local project; see constructors below.
data ProjectConfig a
  = PCProject a
    -- ^ Normal run: we want a project, and have one. This comes from
    -- either 'SYLDefault' or 'SYLOverride'.
  | PCGlobalProject
    -- ^ No project was found when using 'SYLDefault'. Instead, use
    -- the implicit global.
  | PCNoProject ![PackageIdentifierRevision]
    -- ^ Use a no project run. This comes from 'SYLNoProject'.

-- | Default logging level should be something useful but not crazy.
defaultLogLevel :: LogLevel
defaultLogLevel = LevelInfo

readStyles :: ReadM StylesUpdate
readStyles = parseStylesUpdateFromString <$> OA.readerAsk

-- | A project is a collection of packages. We can have multiple stack.yaml
-- files, but only one of them may contain project information.
data Project = Project
  { projectUserMsg :: !(Maybe String)
    -- ^ A warning message to display to the user when the auto generated
    -- config may have issues.
  , projectPackages :: ![RelFilePath]
    -- ^ Packages which are actually part of the project (as opposed
    -- to dependencies).
  , projectDependencies :: ![RawPackageLocation]
    -- ^ Dependencies defined within the stack.yaml file, to be applied on top
    -- of the snapshot.
  , projectFlags :: !(Map PackageName (Map FlagName Bool))
    -- ^ Flags to be applied on top of the snapshot flags.
  , projectResolver :: !RawSnapshotLocation
    -- ^ How we resolve which @Snapshot@ to use
  , projectCompiler :: !(Maybe WantedCompiler)
    -- ^ Override the compiler in 'projectResolver'
  , projectExtraPackageDBs :: ![FilePath]
  , projectCurator :: !(Maybe Curator)
    -- ^ Extra configuration intended exclusively for usage by the curator tool.
    -- In other words, this is /not/ part of the documented and exposed Stack
    -- API. SUBJECT TO CHANGE.
  , projectDropPackages :: !(Set PackageName)
    -- ^ Packages to drop from the 'projectResolver'.
  }
  deriving Show

instance ToJSON Project where
  -- Expanding the constructor fully to ensure we don't miss any fields.
  toJSON (Project userMsg packages extraDeps flags resolver mcompiler extraPackageDBs mcurator drops) = object $ concat
    [ maybe [] (\cv -> ["compiler" .= cv]) mcompiler
    , maybe [] (\msg -> ["user-message" .= msg]) userMsg
    , [ "extra-package-dbs" .= extraPackageDBs | not (null extraPackageDBs) ]
    , [ "extra-deps" .= extraDeps | not (null extraDeps) ]
    , [ "flags" .= fmap toCabalStringMap (toCabalStringMap flags)
      | not (Map.null flags)
      ]
    , ["packages" .= packages]
    , ["resolver" .= resolver]
    , maybe [] (\c -> ["curator" .= c]) mcurator
    , [ "drop-packages" .= Set.map CabalString drops | not (Set.null drops) ]
    ]

-- | Extra configuration intended exclusively for usage by the curator tool. In
-- other words, this is /not/ part of the documented and exposed Stack API.
-- SUBJECT TO CHANGE.
data Curator = Curator
  { curatorSkipTest :: !(Set PackageName)
  , curatorExpectTestFailure :: !(Set PackageName)
  , curatorSkipBenchmark :: !(Set PackageName)
  , curatorExpectBenchmarkFailure :: !(Set PackageName)
  , curatorSkipHaddock :: !(Set PackageName)
  , curatorExpectHaddockFailure :: !(Set PackageName)
  }
  deriving Show

instance ToJSON Curator where
  toJSON c = object
    [ "skip-test" .= Set.map CabalString (curatorSkipTest c)
    , "expect-test-failure" .= Set.map CabalString (curatorExpectTestFailure c)
    , "skip-bench" .= Set.map CabalString (curatorSkipBenchmark c)
    , "expect-benchmark-failure" .=
        Set.map CabalString (curatorExpectTestFailure c)
    , "skip-haddock" .= Set.map CabalString (curatorSkipHaddock c)
    , "expect-test-failure" .=
        Set.map CabalString (curatorExpectHaddockFailure c)
    ]

instance FromJSON (WithJSONWarnings Curator) where
  parseJSON = withObjectWarnings "Curator" $ \o -> Curator
    <$> fmap (Set.map unCabalString) (o ..:? "skip-test" ..!= mempty)
    <*> fmap (Set.map unCabalString) (o ..:? "expect-test-failure" ..!= mempty)
    <*> fmap (Set.map unCabalString) (o ..:? "skip-bench" ..!= mempty)
    <*> fmap (Set.map unCabalString) (o ..:? "expect-benchmark-failure" ..!= mempty)
    <*> fmap (Set.map unCabalString) (o ..:? "skip-haddock" ..!= mempty)
    <*> fmap (Set.map unCabalString) (o ..:? "expect-haddock-failure" ..!= mempty)

-- | Get the URL to request the information on the latest snapshots
askLatestSnapshotUrl :: (MonadReader env m, HasConfig env) => m Text
askLatestSnapshotUrl = view $ configL.to configLatestSnapshot

-- | @".stack-work"@
workDirL :: HasConfig env => Lens' env (Path Rel Dir)
workDirL = configL.lens configWorkDir (\x y -> x { configWorkDir = y })

-- | @STACK_ROOT\/hooks\/@
hooksDir :: HasConfig env => RIO env (Path Abs Dir)
hooksDir = do
  sr <- view $ configL.to configStackRoot
  pure (sr </> [reldir|hooks|])

-- | @STACK_ROOT\/hooks\/ghc-install.sh@
ghcInstallHook :: HasConfig env => RIO env (Path Abs File)
ghcInstallHook = do
  hd <- hooksDir
  pure (hd </> [relfile|ghc-install.sh|])

-- | Where do we get information on global packages for loading up a
-- 'LoadedSnapshot'?
data GlobalInfoSource
  = GISSnapshotHints
    -- ^ Accept the hints in the snapshot definition
  | GISCompiler ActualCompiler
    -- ^ Look up the actual information in the installed compiler

data ProjectAndConfigMonoid
  = ProjectAndConfigMonoid !Project !ConfigMonoid

parseProjectAndConfigMonoid ::
     Path Abs Dir
  -> Value
  -> Yaml.Parser (WithJSONWarnings (IO ProjectAndConfigMonoid))
parseProjectAndConfigMonoid rootDir =
  withObjectWarnings "ProjectAndConfigMonoid" $ \o -> do
    packages <- o ..:? "packages" ..!= [RelFilePath "."]
    deps <- jsonSubWarningsTT (o ..:? "extra-deps") ..!= []
    flags' <- o ..:? "flags" ..!= mempty
    let flags = unCabalStringMap <$> unCabalStringMap
                (flags' :: Map (CabalString PackageName) (Map (CabalString FlagName) Bool))

    resolver <- jsonSubWarnings $ o ...: ["snapshot", "resolver"]
    mcompiler <- o ..:? "compiler"
    msg <- o ..:? "user-message"
    config <- parseConfigMonoidObject rootDir o
    extraPackageDBs <- o ..:? "extra-package-dbs" ..!= []
    mcurator <- jsonSubWarningsT (o ..:? "curator")
    drops <- o ..:? "drop-packages" ..!= mempty
    pure $ do
      deps' <- mapM (resolvePaths (Just rootDir)) deps
      resolver' <- resolvePaths (Just rootDir) resolver
      let project = Project
            { projectUserMsg = msg
            , projectResolver = resolver'
            , projectCompiler = mcompiler -- FIXME make sure resolver' isn't SLCompiler
            , projectExtraPackageDBs = extraPackageDBs
            , projectPackages = packages
            , projectDependencies =
                concatMap toList (deps' :: [NonEmpty RawPackageLocation])
            , projectFlags = flags
            , projectCurator = mcurator
            , projectDropPackages = Set.map unCabalString drops
            }
      pure $ ProjectAndConfigMonoid project config


-----------------------------------
-- Lens classes
-----------------------------------

-- | Class for environment values that can provide a 'Config'.
class ( HasPlatform env
      , HasGHCVariant env
      , HasProcessContext env
      , HasPantryConfig env
      , HasTerm env
      , HasRunner env
      ) => HasConfig env where
  configL :: Lens' env Config

-----------------------------------
-- Lens instances
-----------------------------------

instance HasPlatform Config where
  platformL = lens configPlatform (\x y -> x { configPlatform = y })
  platformVariantL =
    lens configPlatformVariant (\x y -> x { configPlatformVariant = y })

instance HasGHCVariant Config where
  ghcVariantL = to $ fromMaybe GHCStandard . configGHCVariant

instance HasProcessContext Config where
  processContextL = runnerL.processContextL

instance HasPantryConfig Config where
  pantryConfigL = lens configPantryConfig (\x y -> x { configPantryConfig = y })

instance HasConfig Config where
  configL = id
  {-# INLINE configL #-}

instance HasRunner Config where
  runnerL = lens configRunner (\x y -> x { configRunner = y })

instance HasLogFunc Config where
  logFuncL = runnerL.logFuncL

instance HasStylesUpdate Config where
  stylesUpdateL = runnerL.stylesUpdateL

instance HasTerm Config where
  useColorL = runnerL.useColorL
  termWidthL = runnerL.termWidthL

-----------------------------------
-- Helper lenses
-----------------------------------

stackRootL :: HasConfig s => Lens' s (Path Abs Dir)
stackRootL = configL.lens configStackRoot (\x y -> x { configStackRoot = y })

stackGlobalConfigL :: HasConfig s => Lens' s (Path Abs File)
stackGlobalConfigL =
  configL.lens configUserConfigPath (\x y -> x { configUserConfigPath = y })

data ExtraDirs = ExtraDirs
  { edBins :: ![Path Abs Dir]
  , edInclude :: ![Path Abs Dir]
  , edLib :: ![Path Abs Dir]
  }
  deriving (Show, Generic)

instance Semigroup ExtraDirs where
  (<>) = mappenddefault

instance Monoid ExtraDirs where
  mempty = memptydefault
  mappend = (<>)

buildOptsL :: HasConfig s => Lens' s BuildOpts
buildOptsL = configL.lens
  configBuild
  (\x y -> x { configBuild = y })

globalOptsBuildOptsMonoidL :: Lens' GlobalOpts BuildOptsMonoid
globalOptsBuildOptsMonoidL =
  lens
    globalConfigMonoid
    (\x y -> x { globalConfigMonoid = y })
  .
  lens
    configMonoidBuildOpts
    (\x y -> x { configMonoidBuildOpts = y })

whichCompilerL :: Getting r ActualCompiler WhichCompiler
whichCompilerL = to whichCompiler

envOverrideSettingsL ::
     HasConfig env
  => Lens' env (EnvSettings -> IO ProcessContext)
envOverrideSettingsL = configL.lens
  configProcessContextSettings
  (\x y -> x { configProcessContextSettings = y })

-- | In dev mode, print as a warning, otherwise as debug
prettyStackDevL :: HasConfig env => [StyleDoc] -> RIO env ()
prettyStackDevL docs = do
  config <- view configL
  if configStackDeveloperMode config
    then prettyWarnL docs
    else prettyDebugL docs
