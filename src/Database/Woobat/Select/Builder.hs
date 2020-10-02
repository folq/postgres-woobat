{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Database.Woobat.Select.Builder where

import Control.Monad.State
import Data.ByteString (ByteString)
import Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.String
import qualified Database.Woobat.Raw as Raw

newtype Select s a = Select (State SelectState a)
  deriving (Functor, Applicative, Monad)

data SelectState = SelectState
  { usedNames :: !(HashMap ByteString Int)
  , rawSelect :: !Raw.Select
  }

run :: HashMap ByteString Int -> Select s a -> (a, HashMap ByteString Int, Raw.Select)
run used (Select s) = do
  let (a, st) = runState s SelectState {usedNames = used, rawSelect = mempty}
  (a, usedNames st, rawSelect st)

freshName :: ByteString -> State SelectState ByteString
freshName suggestion = do
  used <- gets usedNames
  let count = HashMap.lookupDefault 0 suggestion used
  modify $ \s -> s {usedNames = HashMap.insert suggestion (count + 1) used}
  pure $
    if count == 0
      then suggestion
      else suggestion <> "_" <> fromString (show count)

subquery :: State SelectState a -> State SelectState (a, Raw.Select)
subquery q = do
  used <- gets usedNames
  let (result, usedNames', rawSelect') = run used $ Select q
  modify $ \s -> s {usedNames = usedNames'}
  pure (result, rawSelect')

addSelect :: Raw.Select -> State SelectState ()
addSelect sel =
  modify $ \s -> s {rawSelect = rawSelect s <> sel}
