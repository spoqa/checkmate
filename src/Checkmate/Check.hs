module Checkmate.Check
    ( Check (Check, checkOrderIndex, checkScope, checkText)
    , Checklist
    , Scope (Directory, FileBlock, scopePath, scopeRange)
    , union
    ) where

import Data.Set
import Data.Text
import System.FilePath

import Checkmate.Range

data Scope
    = FileBlock { scopePath :: FilePath, scopeRange :: Range }
    | Directory { scopePath :: FilePath }
    deriving (Show)

instance Eq Scope where
    FileBlock pathA rangeA == FileBlock pathB rangeB =
        equalFilePath pathA pathB && rangeA == rangeB
    Directory pathA == Directory pathB =
        equalFilePath pathA pathB
    _ == _ = False

data Check
    = Check { checkScope :: Scope
            , checkOrderIndex :: Int
            , checkText :: Text
            } deriving (Eq, Show)

instance Ord Check where
    compare a b =
        compare (tup a) (tup b)
      where
        tup (Check scope orderIndex text) = (scopePath scope, orderIndex, text)

type Checklist = Set Check
