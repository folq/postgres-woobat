{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Database.Woobat.Update where

import qualified Barbies
import qualified ByteString.StrictBuilder as Builder
import Control.Exception.Safe
import Data.ByteString.Char8 as ByteString
import Data.Functor.Const
import qualified Data.HashMap.Lazy as HashMap
import qualified Data.Sequence as Seq
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Database.PostgreSQL.LibPQ as LibPQ
import Database.Woobat.Barbie
import Database.Woobat.Expr.Types
import Database.Woobat.Monad (MonadWoobat)
import qualified Database.Woobat.Monad as Monad
import qualified Database.Woobat.Raw as Raw
import Database.Woobat.Returning
import qualified Database.Woobat.Select as Select
import Database.Woobat.Table (Table)
import qualified Database.Woobat.Table as Table
import Database.Woobat.Update.Builder (Update)
import qualified Database.Woobat.Update.Builder as Builder

update ::
  forall table a m.
  (MonadWoobat m, Barbies.TraversableB table, Barbies.ApplicativeB table) =>
  Table table ->
  (table Expr -> Update (table Expr, Returning a)) ->
  m a
update table query =
  Raw.execute statement getResults
  where
    columnNames = Barbies.bmap (\(Const name) -> Const $ Text.encodeUtf8 name) $ Table.columnNames table
    columnNameExprs = Barbies.bmap (\(Const name) -> Expr $ Raw.codeExpr (Text.encodeUtf8 $ Table.name table) <> "." <> Raw.codeExpr name) columnNames
    columnNamesList = Barbies.bfoldMap (\(Const name) -> [name]) columnNames
    usedNames = HashMap.fromList $ (Text.encodeUtf8 $ Table.name table, 1) : [(name, 1) | name <- columnNamesList]
    ((updatedRow, returning_), builderState) = Builder.run usedNames $ query columnNameExprs
    setters =
      Barbies.bfoldMap (\(Const xs) -> xs) $
        Barbies.bzipWith
          ( \(Const columnName) (Expr updated) ->
              Const $ do
                let (Raw.SQL updated') = Raw.unExpr updated $ Builder.usedNames builderState
                case updated' of
                  Raw.Code columnName' Seq.:<| Seq.Empty | columnName == Builder.builderBytes columnName' -> []
                  _ -> ["SET " <> Raw.code columnName <> " = " <> Raw.unExpr updated (Builder.usedNames builderState)]
          )
          columnNames
          updatedRow
    tableName = Text.encodeUtf8 $ Table.name table
    returningClause :: Raw.SQL
    getResults :: LibPQ.Result -> IO a
    (returningClause, getResults) = case returning_ of
      ReturningNothing ->
        ("", const $ pure ())
      Returning results -> do
        let resultsBarbie = toBarbie results
            resultsExprs = Barbies.bfoldMap (\(Expr e) -> [Raw.unExpr e usedNames]) resultsBarbie
        (" RETURNING " <> Raw.separateBy ", " resultsExprs, Select.parseRows (Just results) resultsBarbie)
      ReturningRowCount ->
        ( ""
        , \result_ -> do
            maybeRowCountString <- LibPQ.cmdTuples result_
            case maybeRowCountString >>= ByteString.readInt of
              Just (rowCount, "") ->
                pure rowCount
              _ ->
                throwM $ Monad.DecodingError 0 0 $ "Failed to decode row count: " <> Text.pack (show maybeRowCountString)
        )
    from =
      case Raw.unitView $ Builder.rawFrom builderState of
        Right () -> ""
        Left f -> " USING " <> Raw.compileFrom f
    statement =
      "UPDATE " <> Raw.code tableName <> " (" <> Raw.separateBy ", " (Raw.code <$> columnNamesList) <> ")"
        <> Raw.separateBy ", " setters
        <> from
        <> Raw.compileWheres (Builder.wheres builderState)
        <> returningClause

update_ ::
  forall table m.
  (MonadWoobat m, Barbies.TraversableB table, Barbies.ApplicativeB table) =>
  Table table ->
  (table Expr -> Update (table Expr)) ->
  m ()
update_ table query =
  update table $ \row -> do
    row' <- query row
    pure (row', ReturningNothing)
