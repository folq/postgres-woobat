{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Database.Woobat.Select (
  module Database.Woobat.Select,
  Database.Woobat.Barbie.Barbie,
  Database.Woobat.Select.Builder.Select,
) where

import qualified Barbies
import Control.Exception.Safe
import Control.Monad
import Control.Monad.State
import Data.Functor.Identity
import qualified Database.PostgreSQL.LibPQ as LibPQ
import Database.Woobat.Barbie hiding (result)
import qualified Database.Woobat.Barbie
import Database.Woobat.Expr
import qualified Database.Woobat.Monad as Monad
import qualified Database.Woobat.Raw as Raw
import Database.Woobat.Select.Builder
import qualified PostgreSQL.Binary.Decoding as Decoding

select ::
  forall a m.
  ( Monad.MonadWoobat m
  , Barbie Expr a
  , Barbies.AllB DatabaseType (ToBarbie Expr a)
  , Barbies.ConstraintsB (ToBarbie Expr a)
  , Resultable (FromBarbie Expr a Identity)
  ) =>
  Select a ->
  m [Result (FromBarbie Expr a Identity)]
select s = do
  let (rawSQL, resultsBarbie) = compile s
  Raw.execute rawSQL $ parseRows (Nothing :: Maybe a) resultsBarbie

-- TODO move
parseRows ::
  forall a proxy.
  ( Barbie Expr a
  , Barbies.AllB DatabaseType (ToBarbie Expr a)
  , Barbies.ConstraintsB (ToBarbie Expr a)
  , Resultable (FromBarbie Expr a Identity)
  ) =>
  proxy a ->
  ToBarbie Expr a Expr ->
  LibPQ.Result ->
  IO [Result (FromBarbie Expr a Identity)]
parseRows _ resultsBarbie result = do
  rowCount <- LibPQ.ntuples result
  forM [0 .. rowCount - 1] $ \rowNumber -> do
    let go :: DatabaseType x => Expr x -> StateT LibPQ.Column IO (Identity x)
        go _ = fmap Identity $ do
          col <- get
          put $ col + 1
          maybeValue <- liftIO $ LibPQ.getvalue result rowNumber col
          case (decoder, maybeValue) of
            (Decoder d, Just v) ->
              case Decoding.valueParser d v of
                Left err ->
                  throwM $ Monad.DecodingError rowNumber col err
                Right a ->
                  pure a
            (Decoder _, Nothing) ->
              throwM $ Monad.UnexpectedNullError rowNumber col
            (NullableDecoder _, Nothing) ->
              pure Nothing
            (NullableDecoder d, Just v) ->
              case Decoding.valueParser d v of
                Left err ->
                  throwM $ Monad.DecodingError rowNumber col err
                Right a ->
                  pure $ Just a

    barbieRow :: ToBarbie Expr a Identity <-
      flip evalStateT 0 $ Barbies.btraverseC @DatabaseType go resultsBarbie
    pure $ Database.Woobat.Barbie.result $ fromBarbie @Expr @a barbieRow

-- TODO move
compile :: forall a. Barbie Expr a => Select a -> (Raw.SQL, ToBarbie Expr a Expr)
compile s = do
  let (results, st) = run mempty s
      resultsBarbie :: ToBarbie Expr a Expr
      resultsBarbie = toBarbie results
      sql = Raw.compileSelect (Barbies.bfoldMap (\(Expr e) -> [Raw.unExpr e $ usedNames st]) resultsBarbie) $ rawSelect st
  (sql, resultsBarbie)

orderBy :: Expr a -> Raw.Order -> Select ()
orderBy (Expr expr) order_ =
  Select $ do
    usedNames_ <- gets usedNames
    addSelect mempty {Raw.orderBys = pure (Raw.unExpr expr usedNames_, order_)}

ascending :: Raw.Order
ascending = Raw.Ascending

descending :: Raw.Order
descending = Raw.Descending
