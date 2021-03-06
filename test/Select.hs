{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Select where

import qualified Barbies
import Control.Lens hiding ((<.))
import Control.Monad
import Data.Foldable
import Data.Generic.HKD (HKD)
import qualified Data.Generic.HKD as HKD
import Data.Generics.Labels ()
import qualified Data.List as List
import Data.Ratio
import Database.Woobat
import qualified Database.Woobat.Barbie as Barbie
import qualified Expr
import GHC.Generics
import qualified Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

properties ::
  (forall a. WoobatT (Hedgehog.PropertyT IO) a -> Hedgehog.PropertyT IO a) ->
  [(Hedgehog.PropertyName, Hedgehog.Property)]
properties runWoobat =
  [
    ( "values"
    , Hedgehog.property $ do
        Expr.Some gen <- Hedgehog.forAll Expr.genSome
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $ select $ values xs
        result Hedgehog.=== xs
    )
  ,
    ( "where_"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        cutoff <- Hedgehog.forAll gen
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $ do
                v <- values xs
                where_ $ v >. value cutoff
                pure v
        result Hedgehog.=== filter (> cutoff) xs
    )
  ,
    ( "orderBy"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $ do
                (v, v') <- expressions $ zip (value <$> xs) (value <$> reverse xs)
                orderBy v ascending
                pure (v, v')
        result Hedgehog.=== List.sortOn fst (zip xs (reverse xs))
    )
  ,
    ( "leftJoin"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        Operation _ dbOp haskellOp <- Hedgehog.forAll genOrdOperation
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $ do
                v <- values xs
                mv' <- leftJoin (values xs) $ dbOp v
                pure (v, mv')
        result Hedgehog.=== do
          v <- xs
          mv <- leftJoinList xs $ haskellOp v
          pure (v, mv)
    )
  ,
    ( "lateral leftJoin"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        Operation _ dbOp haskellOp <- Hedgehog.forAll genOrdOperation
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $ do
                v <- values xs
                mv' <-
                  leftJoin
                    (filter_ (<=. v) $ values xs)
                    $ dbOp v
                pure (v, mv')
        result Hedgehog.=== do
          v <- xs
          mv <- leftJoinList (filter (<= v) xs) $ haskellOp v
          pure (v, mv)
    )
  ,
    ( "aggregate"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $
                aggregate $ do
                  v <- values xs
                  pure ((count v, countAll), (all_ $ v ==. 0, any_ $ v ==. 0), (max_ v, min_ v), sum_ v, arrayAggregate v)
        result
          Hedgehog.=== [
                         ( (length xs, length xs)
                         , (all (== 0) xs, any (== 0) xs)
                         , if null xs
                            then (Nothing, Nothing)
                            else (Just $ maximum xs, Just $ minimum xs)
                         , sum $ fromIntegral <$> xs
                         , xs
                         )
                       ]
    )
  ,
    ( "aggregate average"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll $ Expr.genSomeRangedIntegral $ Range.linearFrom 0 (-1000) 1000
        xs <- Hedgehog.forAll (Gen.list (Range.linearFrom 0 0 10) gen)
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $
                aggregate $ do
                  v <- values xs
                  pure $ average v
        let result' = fmap round <$> result
            expected :: Ratio Integer
            expected = sum (fromIntegral <$> xs) % fromIntegral (length xs)
        result' Hedgehog.=== [if null xs then Nothing else Just (round expected :: Integer)]
    )
  ,
    ( "lateral aggregate average"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll $ Expr.genSomeRangedIntegral $ Range.linearFrom 0 (-1000) 1000
        xs <- Hedgehog.forAll (Gen.list (Range.linearFrom 0 0 10) gen)
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $ do
                v <- values xs
                aggregate $ do
                  v' <- filter_ (<=. v) $ values xs
                  pure $ sum_ v'
        let expected = do
              v <- xs
              pure $ sum (fromIntegral <$> filter (<= v) xs)
        result Hedgehog.=== expected
    )
  ,
    ( "multiple values"
    , Hedgehog.property $ do
        Expr.Some gen <- Hedgehog.forAll Expr.genSome
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $
                expressions $ zip (value <$> xs) (value <$> xs)
        result Hedgehog.=== zip (toList xs) (toList xs)
    )
  ,
    ( "start with leftJoin"
    , Hedgehog.property $ do
        Expr.SomeNonMaybe gen <- Hedgehog.forAll Expr.genSomeNonMaybe
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        let sameParamAs :: f a -> g a -> g a
            sameParamAs _ ga = ga
        result <-
          Hedgehog.evalM $
            runWoobat $ select $ leftJoin (values xs) $ const false
        result Hedgehog.=== [sameParamAs xs Nothing]
    )
  ,
    ( "unnest integral"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $
                unnest (value xs)
        result Hedgehog.=== xs
    )
  ,
    ( "unnest row"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen1 <- Hedgehog.forAll Expr.genSomeIntegral
        Expr.SomeIntegral gen2 <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) $ Expr.TableTwo <$> gen1 <*> gen2
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $ do
                Row tab <- unnest (array $ row . record <$> xs)
                where_ $ tab ^. #field1 ==. tab ^. #field1 &&. tab ^. #field2 ==. tab ^. #field2
                pure tab
        result Hedgehog.=== xs
    )
  ,
    ( "exists"
    , Hedgehog.property $ do
        Expr.SomeIntegral gen <- Hedgehog.forAll Expr.genSomeIntegral
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $
                pure $ exists $ unnest (value xs)
        result Hedgehog.=== [not (List.null xs)]
    )
  ,
    ( "arrayOf"
    , Hedgehog.property $ do
        Expr.SomeNonArray gen <- Hedgehog.forAll Expr.genSomeNonArray
        xs <- Hedgehog.forAll $ Gen.list (Range.linearFrom 0 0 10) gen
        result <-
          Hedgehog.evalM $
            runWoobat $
              select $
                pure $ arrayOf $ values xs
        result Hedgehog.=== [xs]
    )
  ,
    ( "HKD select"
    , Hedgehog.withTests 100 $
        Hedgehog.property $ do
          SomeColumnSelectSpec select1 expected1 <- Hedgehog.forAll genSomeColumnSelectSpec
          SomeColumnSelectSpec select2 expected2 <- Hedgehog.forAll genSomeColumnSelectSpec
          SomeColumnSelectSpec select3 expected3 <- Hedgehog.forAll genSomeColumnSelectSpec
          result <- Hedgehog.evalM $
            runWoobat $
              select $ do
                x1 <- select1
                x2 <- select2
                x3 <- select3
                pure $ HKDType (HKD.build @(Expr.TableTwo _ _) x1 x2) x3
          let expected = do
                x1 <- expected1
                x2 <- expected2
                x3 <- expected3
                pure $ HKDType (HKD.build @(Expr.TableTwo _ _) (Identity x1) (Identity x2)) (Identity x3)
          List.sort result Hedgehog.=== List.sort expected
    )
  ,
    ( "select spec"
    , Hedgehog.withTests 1000 $
        Hedgehog.property $ do
          SomeSelectSpec select_ expected <- Hedgehog.forAll genSomeSelectSpec
          result <- Hedgehog.evalM $ runWoobat $ select select_
          List.sort result Hedgehog.=== List.sort expected
    )
  ]

data HKDType a b c f = HKDType
  { first :: HKD (Expr.TableTwo a b) f
  , second :: f c
  }
  deriving (Eq, Ord, Show, Generic, Barbies.FunctorB, Barbies.TraversableB, Barbies.ConstraintsB)

-------------------------------------------------------------------------------

data SelectSpec a where
  SelectSpec ::
    Select a ->
    [Barbie.Result (Barbie.FromBarbie Expr a Identity)] ->
    SelectSpec a

data SomeSelectSpec where
  SomeSelectSpec ::
    ( Show (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Eq (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Ord (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Barbie Expr a
    , Barbies.AllB DatabaseType (Barbie.ToBarbie Expr a)
    , Barbies.ConstraintsB (Barbie.ToBarbie Expr a)
    , Barbie.Resultable (Barbie.FromBarbie Expr a Identity)
    ) =>
    Select a ->
    [Barbie.Result (Barbie.FromBarbie Expr a Identity)] ->
    SomeSelectSpec

instance Show SomeSelectSpec where
  show (SomeSelectSpec sel result) = show (fst $ compile sel, result)

data Operation where
  Operation ::
    String ->
    (forall a. Ord a => Expr a -> Expr a -> Expr Bool) ->
    (forall a. Ord a => a -> a -> Bool) ->
    Operation

instance Show Operation where
  show (Operation o _ _) = o

genSelectSpec :: DatabaseType a => Hedgehog.Gen a -> Hedgehog.Gen (SelectSpec (Expr a))
genSelectSpec gen =
  Gen.choice
    [ do
        x <- gen
        let sel = pure $ value x
            expected = [x]
        pure $ SelectSpec sel expected
    , do
        xs <- Gen.list (Range.linearFrom 0 0 10) gen
        let sel = values xs
            expected = xs
        pure $ SelectSpec sel expected
    ]

genSomeSelectSpec :: Hedgehog.Gen SomeSelectSpec
genSomeSelectSpec =
  Gen.recursive
    Gen.choice
    [ do
        Expr.Some gen <- Expr.genSome
        SelectSpec sel expected <- genSelectSpec gen
        pure $ SomeSelectSpec sel expected
    ]
    [ do
        SomeSelectSpec sel1 expected1 <- genSomeSelectSpec
        SomeSelectSpec sel2 expected2 <- genSomeSelectSpec
        let sel = (,) <$> sel1 <*> sel2
            expected = (,) <$> expected1 <*> expected2
        pure $ SomeSelectSpec sel expected
    , do
        Expr.SomeNonMaybe gen <- Expr.genSomeNonMaybe
        SelectSpec sel1 expected1 <- genSelectSpec gen
        SelectSpec sel2 expected2 <- genSelectSpec gen
        Operation _ dbOp haskellOp <- genEqOperation
        let sel = do
              x <- sel1
              y <- sel2
              where_ $ dbOp x y
              pure x
            expected = do
              x <- expected1
              y <- expected2
              guard $ haskellOp x y
              pure x
        pure $ SomeSelectSpec sel expected
    , do
        Expr.SomeNonMaybe gen <- Expr.genSomeNonMaybe
        SelectSpec sel1 expected1 <- genSelectSpec gen
        SelectSpec sel2 expected2 <- genSelectSpec gen
        Operation _ dbOp haskellOp <- genEqOperation
        let sel = do
              x <- sel1
              mx <- leftJoin sel2 $ dbOp x
              pure (x, mx)
            expected = do
              x <- expected1
              mx <- leftJoinList expected2 $ haskellOp x
              pure (x, mx)
        pure $ SomeSelectSpec sel expected
    , do
        Expr.SomeIntegral gen <- Expr.genSomeIntegral
        SelectSpec sel expected <- genSelectSpec gen
        x <- gen
        Operation _ dbOp haskellOp <- genOrdOperation
        let sel' = filter_ (dbOp $ value x) sel
            expected' = filter (haskellOp x) expected
        pure $ SomeSelectSpec sel' expected'
    , do
        Expr.SomeIntegral gen1 <- Expr.genSomeIntegral
        Expr.SomeIntegral gen2 <- Expr.genSomeIntegral
        SelectSpec sel1 expected1 <- genSelectSpec gen1
        SelectSpec sel2 expected2 <- genSelectSpec gen2
        let sel' = unnest $
              arrayOf $ do
                x <- sel1
                y <- sel2
                pure $ row $ HKD.build @(Expr.TableTwo _ _) x y
            expected' = Expr.TableTwo <$> expected1 <*> expected2
        pure $ SomeSelectSpec sel' expected'
    , do
        SomeSelectSpec sel expected <- genSomeSelectSpec
        let sel' = pure $ exists sel
            expected' = [not $ null expected]
        pure $ SomeSelectSpec sel' expected'
    , do
        Expr.SomeIntegral gen <- Expr.genSomeIntegral
        SelectSpec sel expected <- genSelectSpec gen
        limit_ <- Gen.int $ Range.linearFrom 0 0 10
        offset_ <- Gen.int $ Range.linearFrom 0 0 10
        let sel' = limit limit_ $
              offset offset_ $ do
                x <- sel
                orderBy x ascending
                pure x
            expected' = take limit_ $ drop offset_ $ List.sort expected
        pure $ SomeSelectSpec sel' expected'
    , do
        Expr.SomeIntegral gen <- Expr.genSomeIntegral
        SelectSpec sel expected <- genSelectSpec gen
        limit1 <- Gen.int $ Range.linearFrom 0 0 10
        offset1 <- Gen.int $ Range.linearFrom 0 0 10
        limit2 <- Gen.int $ Range.linearFrom 0 0 10
        offset2 <- Gen.int $ Range.linearFrom 0 0 10
        let sel' =
              limit limit1 $
                offset offset1 $
                  limit limit2 $
                    offset offset2 $ do
                      x <- sel
                      orderBy x ascending
                      pure x
            expected' = take limit1 $ drop offset1 $ take limit2 $ drop offset2 $ List.sort expected
        pure $ SomeSelectSpec sel' expected'
    ]

data SomeColumnSelectSpec where
  SomeColumnSelectSpec ::
    ( a ~ Expr (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Show (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Eq (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Ord (Barbie.Result (Barbie.FromBarbie Expr a Identity))
    , Barbie Expr a
    , Barbies.AllB DatabaseType (Barbie.ToBarbie Expr a)
    , Barbies.ConstraintsB (Barbie.ToBarbie Expr a)
    , Barbie.Resultable (Barbie.FromBarbie Expr a Identity)
    ) =>
    Select a ->
    [Barbie.Result (Barbie.FromBarbie Expr a Identity)] ->
    SomeColumnSelectSpec

instance Show SomeColumnSelectSpec where
  show (SomeColumnSelectSpec sel result) = show (fst $ compile sel, result)

genSomeColumnSelectSpec :: Hedgehog.Gen SomeColumnSelectSpec
genSomeColumnSelectSpec =
  Gen.recursive
    Gen.choice
    [ do
        Expr.Some gen <- Expr.genSomeColumn
        SelectSpec sel expected <- genSelectSpec gen
        pure $ SomeColumnSelectSpec sel expected
    ]
    [ do
        Expr.SomeNonMaybe gen <- Expr.genSomeNonMaybeColumn
        SelectSpec sel1 expected1 <- genSelectSpec gen
        SelectSpec sel2 expected2 <- genSelectSpec gen
        Operation _ dbOp haskellOp <- genEqOperation
        let sel = do
              x <- sel1
              y <- sel2
              where_ $ dbOp x y
              pure x
            expected = do
              x <- expected1
              y <- expected2
              guard $ haskellOp x y
              pure x
        pure $ SomeColumnSelectSpec sel expected
    , do
        Expr.SomeIntegral gen <- Expr.genSomeIntegral
        SelectSpec sel expected <- genSelectSpec gen
        x <- gen
        Operation _ dbOp haskellOp <- genOrdOperation
        let sel' = filter_ (dbOp $ value x) sel
            expected' = filter (haskellOp x) expected
        pure $ SomeColumnSelectSpec sel' expected'
    , do
        SomeColumnSelectSpec sel expected <- genSomeColumnSelectSpec
        let sel' = pure $ exists sel
            expected' = [not $ null expected]
        pure $ SomeColumnSelectSpec sel' expected'
    , do
        Expr.SomeIntegral gen <- Expr.genSomeIntegral
        SelectSpec sel expected <- genSelectSpec gen
        limit_ <- Gen.int $ Range.linearFrom 0 0 1000
        offset_ <- Gen.int $ Range.linearFrom 0 0 1000
        let sel' = limit limit_ $
              offset offset_ $ do
                x <- sel
                orderBy x ascending
                pure x
            expected' = take limit_ $ drop offset_ $ List.sort expected
        pure $ SomeColumnSelectSpec sel' expected'
    , do
        Expr.SomeIntegral gen <- Expr.genSomeIntegral
        SelectSpec sel expected <- genSelectSpec gen
        limit1 <- Gen.int $ Range.linearFrom 0 0 1000
        offset1 <- Gen.int $ Range.linearFrom 0 0 1000
        limit2 <- Gen.int $ Range.linearFrom 0 0 1000
        offset2 <- Gen.int $ Range.linearFrom 0 0 1000
        let sel' =
              limit limit1 $
                offset offset1 $
                  limit limit2 $
                    offset offset2 $ do
                      x <- sel
                      orderBy x ascending
                      pure x
            expected' = take limit1 $ drop offset1 $ take limit2 $ drop offset2 $ List.sort expected
        pure $ SomeColumnSelectSpec sel' expected'
    ]

genEqOperation :: Hedgehog.Gen Operation
genEqOperation =
  Gen.element
    [ Operation "==" (==.) (==)
    , Operation "/=" (/=.) (/=)
    ]

genOrdOperation :: Hedgehog.Gen Operation
genOrdOperation =
  Gen.choice
    [ genEqOperation
    , Gen.element
        [ Operation "<" (<.) (<)
        , Operation "<=" (<=.) (<=)
        , Operation ">" (>.) (>)
        , Operation ">=" (>=.) (>=)
        ]
    ]

leftJoinList :: [a] -> (a -> Bool) -> [Maybe a]
leftJoinList as on =
  case filter on as of
    [] ->
      pure Nothing
    as' ->
      Just <$> as'
