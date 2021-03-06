{-# LANGUAGE OverloadedStrings #-}
import Data.List (elemIndices)
import Data.List.NonEmpty (nonEmpty, last)
import Data.Semigroup ((<>))
import System.Environment
import System.Exit
import System.IO

import Data.Text
import Data.Text.Encoding
import Data.Text.IO as TIO
import Options.Applicative
import System.Directory
import System.Process hiding (cwd)

import Checkmate.Check
import Checkmate.Discover
import Checkmate.Publisher.GitHub
import Checkmate.Renderer

type InputReader = App -> IO Text
type CommandRunner = App -> Checklist -> IO ()

data Command = Command
    { inputReader :: InputReader
    , commandRunner :: CommandRunner
    }

data App = App
    { inputFilePath :: Maybe FilePath
    , appCommand :: Command
    }

withInputFile :: App -> (Handle -> IO r) -> IO r
withInputFile App { inputFilePath = Nothing } action' = do
    let i = stdin
    r <- action' i
    hClose i
    return r
withInputFile app@App { inputFilePath = Just "-" } action' =
    withInputFile (app { inputFilePath = Nothing }) action'
withInputFile App { inputFilePath = Just i } action' =
    withFile i ReadMode action'

readInputFile :: App -> IO Text
readInputFile = (`withInputFile` TIO.hGetContents)

readDiff :: App -> IO (Either String FileDeltas)
readDiff app@App{ appCommand = Command { inputReader = readInput } } =
    parseDiff <$> readInput app

listChecks :: App -> IO Checklist
listChecks app = do
    d <- readDiff app
    cwd <- getCurrentDirectory
    case d of
        Left msg -> die msg
        Right deltas -> discover cwd deltas

appP :: Parser App
appP = App
    <$> option (Just <$> str)
        (  long "input-file"
        <> short 'i'
        <> metavar "FILE"
        <> value Nothing
        <> help "A diff text to extract a checklist from"
        )
    <*> subparser (  command "commonmark" commonmarkPI
                  <> command "gfm" gfmPI
                  <> command "github" githubPI
                  <> command "github-circle" githubCirclePI
                  <> command "github-travis" githubTravisPI
                  )

commonmarkPI :: ParserInfo Command
commonmarkPI = info (pure $ Command readInputFile cmd) $
    progDesc "Print a checklist as CommonMark (i.e. Markdown) format."
  where
    cmd :: CommandRunner
    cmd _ checklist = do
        cwd <- getCurrentDirectory
        TIO.putStr $ toCommonMark cwd 1 checklist

gfmPI :: ParserInfo Command
gfmPI = info (pure $ Command readInputFile cmd) $
    progDesc "Print a checklist as GitHub Flavored Markdown format."
  where
    cmd :: CommandRunner
    cmd _ checklist = do
        cwd <- getCurrentDirectory
        TIO.putStr $ toGFMarkdown cwd 1 checklist

githubTokenOption :: Parser Token
githubTokenOption = option (encodeUtf8 . pack <$> str)
    (  long "access-token"
    <> long "token"
    <> short 't'
    <> metavar "TOKEN"
    <> help "GitHub OAuth access token"
    )

leaveGithubComment :: Maybe OwnerName
                   -> RepoName
                   -> PullRequestId
                   -> Token
                   -> Maybe Text
                   -> CommandRunner
leaveGithubComment owner' repo pr accessToken endpoint _ checklist = do
    cwd <- getCurrentDirectory
    r <- leaveComment owner' repo pr accessToken endpoint cwd checklist
    case r of
        Right Nothing -> return ()
        Right (Just (URL url)) -> TIO.putStrLn url
        Left e -> handleGithubError e

githubInputReader :: IO (Maybe OwnerName, RepoName, PullRequestId)
                  -> String
                  -> Token -> InputReader
githubInputReader identifier headEnvironKey accessToken (App Nothing _) = do
    (owner, repo, prId) <- identifier
    result <- pullRequestBaseSha owner repo prId accessToken Nothing
    base <- case result of
        Left e -> handleGithubError e
        Right sha -> return sha
    head' <- environ headEnvironKey
    let range = unpack base ++ ".." ++ head'
    diff <- readProcess "git" ["diff", range] ""
    return $ pack diff
githubInputReader _ _ _ app = readInputFile app

githubCommandRunner :: IO (Maybe OwnerName, RepoName, PullRequestId)
                    -> Token -> CommandRunner
githubCommandRunner identifier accessToken app checklist = do
    (owner, repo, prId) <- identifier
    leaveGithubComment owner repo prId accessToken Nothing app checklist

handleGithubError :: Checkmate.Publisher.GitHub.Error -> IO a
handleGithubError (HTTPError httpError) = printError $ pack $ show httpError
handleGithubError (ParseError message) = printError message
handleGithubError (JsonError message) = printError message
handleGithubError (UserError message) = printError message

githubPI :: ParserInfo Command
githubPI = info (parser <**> helper) $
    progDesc $ "Create a checklist comment on the corresponding pull " ++
               "reuqest on GitHub."
  where
    parser :: Parser Command
    parser = cmd
        <$> option (Just . mkOwnerName . pack <$> str)
            (  long "owner"
            <> long "login"
            <> short 'l'
            <> metavar "LOGIN"
            <> value Nothing
            <> help ("Owner of GitHub repository of a pull request to " ++
                     "create a checklist comment.  \"foo\" of " ++
                     "\"github.com/foo/bar\".  The currently authenticated " ++
                     "user (through -t/--access-token/--token) by default")
            )
        <*> option (mkRepoName . pack <$> str)
            (  long "repository"
            <> long "repo"
            <> short 'r'
            <> metavar "REPO"
            <> help ("Name of GitHub repository of a pull request to create " ++
                     "a checklist comment.  \"bar\" of \"github.com/foo/bar\"")
            )
        <*> option (mkPullRequestId <$> (auto :: ReadM Int))
            (  long "pull-request"
            <> long "pr"
            <> short 'p'
            <> metavar "NUM"
            <> help "No. of pull request to create a checklist comment"
            )
        <*> githubTokenOption
        <*> option (Just . dropWhileEnd (== '/') . pack <$> str)
            (  long "enterprise-endpoint"
            <> short 'e'
            <> metavar "URL"
            <> value Nothing
            <> help "API endpoint URL for GitHub Enterprise (if applicable)"
            )
    cmd :: Maybe OwnerName -> RepoName -> PullRequestId -> Token -> Maybe Text
        -> Command
    cmd owner repo prId token endpoint =
        Command readInputFile
                (leaveGithubComment owner repo prId token endpoint)

githubCirclePI :: ParserInfo Command
githubCirclePI = info (parser <**> helper) $
    progDesc $ "Create a checklist comment on the corresponding pull " ++
               "reuqest on GitHub from Circle CI. It depends on the " ++
               "following environment variables: CI_PULL_REQUEST, " ++
               "CIRCLE_PROJECT_REPONAME, CIRCLE_PROJECT_USERNAME, CIRCLE_SHA1"
  where
    parser :: Parser Command
    parser = fmap cmd githubTokenOption
    cmd :: Token -> Command
    cmd token = Command (githubInputReader identifier "CIRCLE_SHA1" token)
                        (githubCommandRunner identifier token)
    identifier :: IO (Maybe OwnerName, RepoName, PullRequestId)
    identifier = do
        pr <- environ "CI_PULL_REQUEST"
        case nonEmpty $ elemIndices '/' pr of
            Nothing -> do
                System.IO.hPutStrLn stderr "This is not a PR build; skipped..."
                exitSuccess  -- It shouldn't be marked as failure on CI builds
            Just slashes -> do
                let lastPart = Prelude.drop
                        (succ $ Data.List.NonEmpty.last slashes)
                        pr
                    prId = mkPullRequestId $ read lastPart
                owner <- environ "CIRCLE_PROJECT_USERNAME"
                repo <- environ "CIRCLE_PROJECT_REPONAME"
                return ( Just $ mkOwnerName $ pack owner
                       , mkRepoName $ pack repo
                       , prId
                       )

githubTravisPI :: ParserInfo Command
githubTravisPI = info (parser <**> helper) $
    progDesc $ "Create a checklist comment on the corresponding pull " ++
               "reuqest on GitHub from Travis CI. It depends on the " ++
               "following environment variables: TRAVIS_PULL_REQUEST, " ++
               "TRAVIS_PULL_REQUEST_SHA, TRAVIS_REPO_SLUG."
  where
    parser :: Parser Command
    parser = cmd <$> githubTokenOption
    cmd :: Token -> Command
    cmd token = Command
        (githubInputReader identifier "TRAVIS_PULL_REQUEST_SHA" token)
        (githubCommandRunner identifier token)
    identifier :: IO (Maybe OwnerName, RepoName, PullRequestId)
    identifier = do
        pr <- environ "TRAVIS_PULL_REQUEST"
        case pr of
            "false" -> do
                System.IO.hPutStrLn stderr "This is not a PR build; skipped..."
                exitSuccess  -- It shouldn't be marked as failure on CI builds
            _ -> do
                let prId = mkPullRequestId $ read pr
                slug <- pack <$> environ "TRAVIS_REPO_SLUG"
                let (o, r) = Data.Text.break (== '/') slug
                    owner = mkOwnerName o
                    repo = mkRepoName $ Data.Text.drop 1 r
                return (Just owner, repo, prId)

appPI :: ParserInfo App
appPI = info (appP <**> helper)
    (  fullDesc
    <> progDesc "Generate checklists relevant to a given patch."
    )

environ :: String -> IO String
environ name = do
    r <- lookupEnv name
    case r of
        Nothing -> printError $ pack name `append` " is not defined."
        Just v -> return v

printError :: Text -> IO a
printError message = do
    prog <- getProgName
    die $ prog ++ ": error: " ++ unpack message

main :: IO ()
main = do
    app@App { appCommand = Command { commandRunner = cmd } } <- execParser appPI
    checklist <- listChecks app
    cmd app checklist
