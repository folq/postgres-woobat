{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Database.Woobat.Query (
  module Database.Woobat.Query,
  MonadQuery,
) where

import qualified Barbies
import Control.Monad.State
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.Functor.Const (Const (Const))
import Data.Int
import Data.Kind (Type)
import Data.Scientific
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as Lazy
import Data.Time (Day, DiffTime, LocalTime, TimeOfDay, TimeZone, UTCTime)
import Data.UUID.Types (UUID)
import Database.Woobat.Barbie hiding (result)
import Database.Woobat.Expr
import Database.Woobat.Query.Monad
import qualified Database.Woobat.Raw as Raw
import Database.Woobat.Select.Builder
import Database.Woobat.Table (Table)
import qualified Database.Woobat.Table as Table

from ::
  forall table query.
  (MonadQuery query, Barbies.FunctorB table) =>
  Table table ->
  query (table Expr)
from table = do
  let tableName =
        Text.encodeUtf8 $ Table.name table
  alias <- freshName tableName
  let tableRow :: table Expr
      tableRow =
        Barbies.bmap (\(Const columnName) -> Expr $ Raw.codeExpr $ alias <> "." <> Text.encodeUtf8 columnName) $ Table.columnNames table
  addFrom $ Raw.Table tableName alias
  pure tableRow

where_ :: MonadQuery query => Expr Bool -> query ()
where_ (Expr cond) =
  addWhere cond

filter_ :: MonadQuery query => (a -> Expr Bool) -> query a -> query a
filter_ f q = do
  a <- q
  where_ $ f a
  pure a

leftJoin ::
  forall a query.
  (MonadQuery query, Barbie Expr a) =>
  Select a ->
  (FromBarbie Expr a Expr -> Expr Bool) ->
  query (Left a)
leftJoin (Select sel) on = do
  (innerResults, rightSelect) <- subquery sel
  let innerResultsBarbie :: ToBarbie Expr a Expr
      innerResultsBarbie = toBarbie innerResults
  leftFrom <- getFrom
  leftFrom' <- mapM (\() -> freshName "unit") leftFrom
  usedNames_ <- getUsedNames
  alias <- freshName "subquery"
  namedResults :: ToBarbie Expr a (Product (Const ByteString) Expr) <-
    Barbies.btraverse
      ( \e -> do
          name <- freshName "col"
          pure $ Product (Const name) e
      )
      innerResultsBarbie
  let outerResults :: ToBarbie Expr a Expr
      outerResults =
        Barbies.bmap (\(Product (Const name) _) -> Expr $ Raw.codeExpr $ alias <> "." <> name) namedResults
      Expr rawOn =
        on $ fromBarbie @Expr @a outerResults
      nullableResults :: ToBarbie Expr a (NullableF Expr)
      nullableResults = Barbies.bmap (\(Expr e) -> NullableF (Expr e)) outerResults
  putFrom $
    Raw.LeftJoin
      leftFrom'
      (Raw.unExpr rawOn usedNames_)
      ( Raw.Subquery
          (Barbies.bfoldMap (\(Product (Const name) (Expr e)) -> pure (Raw.unExpr e usedNames_, name)) namedResults)
          rightSelect
          alias
      )
  return $ fromBarbie @Expr @a nullableResults

-- | @LIMIT@
limit :: forall a query. (MonadQuery query, Barbie Expr a) => Int -> Select a -> query (FromBarbie Expr a Expr)
limit limit_
  | limit_ >= 0 = rawLimit mempty {Raw.count = Just limit_}
  | otherwise = error "Database.Woobat.Query.limit: negative limit"

-- | @OFFSET@
offset :: forall a query. (MonadQuery query, Barbie Expr a) => Int -> Select a -> query (FromBarbie Expr a Expr)
offset offset_
  | offset_ >= 0 = rawLimit mempty {Raw.offset = offset_}
  | otherwise = error "Database.Woobat.Query.limit: negative offset"

-- | @LIMIT@ and @OFFSET@.
rawLimit :: forall a query. (MonadQuery query, Barbie Expr a) => Raw.Limit -> Select a -> query (FromBarbie Expr a Expr)
rawLimit limit_ (Select sel) = do
  (innerResults, subSelect) <- subquery sel
  let innerResultsBarbie :: ToBarbie Expr a Expr
      innerResultsBarbie = toBarbie innerResults
  case Raw.fromView subSelect of
    Just (Raw.Subquery results select alias) -> do
      addFrom $ Raw.Subquery results (mempty {Raw.limit = limit_} <> select) alias
      pure $ fromBarbie @Expr @a innerResultsBarbie
    _ -> do
      usedNames_ <- getUsedNames
      alias <- freshName "subquery"
      namedResults :: ToBarbie Expr a (Product (Const ByteString) Expr) <-
        Barbies.btraverse
          ( \e -> do
              name <- freshName "col"
              pure $ Product (Const name) e
          )
          innerResultsBarbie
      addFrom $
        Raw.Subquery
          (Barbies.bfoldMap (\(Product (Const name) (Expr e)) -> pure (Raw.unExpr e usedNames_, name)) namedResults)
          (mempty {Raw.limit = limit_} <> subSelect)
          alias
      let outerResults :: ToBarbie Expr a Expr
          outerResults =
            Barbies.bmap (\(Product (Const name) _) -> Expr $ Raw.codeExpr $ alias <> "." <> name) namedResults
      return $ fromBarbie @Expr @a outerResults

aggregate ::
  forall a query.
  (MonadQuery query, Barbie AggregateExpr a) =>
  Select a ->
  query (Aggregated a)
aggregate (Select sel) = do
  (innerResults, aggSelect) <- subquery sel
  alias <- freshName "subquery"
  usedNames_ <- getUsedNames
  namedResults :: ToBarbie AggregateExpr a (Product (Const ByteString) AggregateExpr) <-
    Barbies.btraverse
      ( \e -> do
          name <- freshName "col"
          pure $ Product (Const name) e
      )
      (toBarbie innerResults)
  let outerResults :: ToBarbie AggregateExpr a Expr
      outerResults =
        Barbies.bmap (\(Product (Const name) _) -> Expr $ Raw.codeExpr $ alias <> "." <> name) namedResults
  addFrom $
    Raw.Subquery
      (Barbies.bfoldMap (\(Product (Const name) (AggregateExpr e)) -> pure (Raw.unExpr e usedNames_, name)) namedResults)
      aggSelect
      alias
  return $ aggregated @a outerResults

groupBy ::
  Expr a ->
  Select (AggregateExpr a)
groupBy (Expr expr) = Select $ do
  usedNames_ <- gets usedNames
  addSelect mempty {Raw.groupBys = pure $ Raw.unExpr expr usedNames_}
  pure $ AggregateExpr expr

-- | @VALUES@
values :: MonadQuery query => DatabaseType a => [a] -> query (Expr a)
values = expressions . map value

-- | @VALUES@
expressions ::
  forall a query.
  ( MonadQuery query
  , Barbie Expr a
  , Monoid (ToBarbie Expr a (Const ()))
  , Barbies.ConstraintsB (ToBarbie Expr a)
  , Barbies.AllB DatabaseType (ToBarbie Expr a)
  ) =>
  [a] ->
  query (FromBarbie Expr a Expr)
expressions rows = do
  case rows of
    [] -> where_ false
    _ -> pure ()
  let barbieRows :: [ToBarbie Expr a Expr]
      barbieRows = toBarbie <$> rows
  rowAlias <- Raw.code <$> freshName "expressions"
  aliasesBarbie :: ToBarbie Expr a (Const ByteString) <- Barbies.btraverse (\(Const ()) -> Const <$> freshName "col") mempty
  let aliases = Barbies.bfoldMap (\(Const a) -> [Raw.code a]) aliasesBarbie
  usedNames_ <- getUsedNames
  addFrom $
    Raw.Set
      ( "(VALUES "
          <> ( case barbieRows of
                [] -> do
                  let go :: forall f x. DatabaseType x => f x -> Expr x
                      go _ = Expr $ "null::" <> typeName @x
                      nullRow = Barbies.bmapC @DatabaseType go aliasesBarbie
                  "(" <> Raw.separateBy ", " (Barbies.bfoldMap (\(Expr e) -> [Raw.unExpr e usedNames_]) nullRow) <> ")"
                _ -> Raw.separateBy ", " ((\row_ -> "(" <> Raw.separateBy ", " (Barbies.bfoldMap (\(Expr e) -> [Raw.unExpr e usedNames_]) row_) <> ")") <$> barbieRows)
             )
          <> ")"
      )
      ( rowAlias
          <> "("
          <> Raw.separateBy ", " aliases
          <> ")"
      )
  let resultBarbie :: ToBarbie Expr a Expr
      resultBarbie = Barbies.bmap (\(Const alias) -> Expr $ Raw.Expr (const rowAlias) <> "." <> Raw.codeExpr alias) aliasesBarbie
  pure $ fromBarbie @Expr @a resultBarbie

-- | @UNNEST@
unnest ::
  forall a query.
  ( MonadQuery query
  , Unnestable a
  ) =>
  Expr [a] ->
  query (Unnested a Expr)
unnest (Expr arr) = do
  (returnRow, result) <- unnested @a
  usedNames_ <- getUsedNames
  addFrom $ Raw.Set ("UNNEST(" <> Raw.unExpr arr usedNames_ <> ")") returnRow
  pure result

-- TODO move
type Unnested a f = FromBarbie f (UnnestedBarbie a f) f

class Unnestable a where
  type UnnestedBarbie a :: (Type -> Type) -> Type
  type UnnestedBarbie a = Singleton a
  unnested :: forall query. MonadQuery query => query (Raw.SQL, Unnested a Expr)
  default unnested :: (MonadQuery query, UnnestedBarbie a ~ Singleton a) => query (Raw.SQL, Unnested a Expr)
  unnested = do
    alias <- Raw.code <$> freshName "unnested"
    pure (alias, Singleton $ Expr $ Raw.Expr $ const alias)

instance Unnestable [a]
instance Unnestable (JSONB a)
instance UnnestableRowElement a => Unnestable (Maybe a)
instance Unnestable Bool
instance Unnestable Int
instance Unnestable Int16
instance Unnestable Int32
instance Unnestable Int64
instance Unnestable Float
instance Unnestable Double
instance Unnestable Scientific
instance Unnestable UUID
instance Unnestable Char
instance Unnestable Text
instance Unnestable Lazy.Text
instance Unnestable ByteString
instance Unnestable Lazy.ByteString
instance Unnestable Day
instance Unnestable TimeOfDay
instance Unnestable (TimeOfDay, TimeZone)
instance Unnestable LocalTime
instance Unnestable UTCTime
instance Unnestable DiffTime

instance
  ( Barbies.AllB UnnestableRowElement row
  , Barbies.ConstraintsB row
  , Barbies.TraversableB row
  , Monoid (row (Const ()))
  ) =>
  Unnestable (Row row)
  where
  type UnnestedBarbie (Row row) = RowF row
  unnested = do
    returnRow <- Barbies.btraverseC @UnnestableRowElement go (mempty :: row (Const ()))
    alias <- Raw.code <$> freshName "unnested"
    usedNames_ <- getUsedNames
    let returnRowList = Barbies.bfoldMap (\(Const (colAlias, typeName_)) -> [colAlias <> " " <> Raw.unExpr typeName_ usedNames_]) returnRow
        result = Barbies.bmap (\(Const (colAlias, _)) -> Expr $ Raw.Expr $ const $ alias <> "." <> colAlias) returnRow
    pure (alias <> "(" <> Raw.separateBy ", " returnRowList <> ")", Row result)
    where
      go :: forall a query. (UnnestableRowElement a, MonadQuery query) => Const () a -> query (Const (Raw.SQL, Raw.Expr) a)
      go (Const ()) = do
        colAlias <- freshName "col"
        pure $ Const (Raw.code colAlias, typeName @a)

class (DatabaseType a, Unnestable a, UnnestedBarbie a ~ Singleton a) => UnnestableRowElement a
instance (DatabaseType a, Unnestable a, UnnestedBarbie a ~ Singleton a) => UnnestableRowElement a

-- | Unnest a singleton array
unrow ::
  ( MonadQuery query
  , Barbies.AllB UnnestableRowElement row
  , Barbies.AllB DatabaseType row
  , Barbies.ConstraintsB row
  , Barbies.TraversableB row
  , Monoid (row (Const ()))
  ) =>
  Expr (Row row) ->
  query (row Expr)
unrow row_ =
  (\(Row r) -> r) <$> unnest (array [row_])
