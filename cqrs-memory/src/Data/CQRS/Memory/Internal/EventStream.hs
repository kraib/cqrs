{-# LANGUAGE ScopedTypeVariables #-}
module Data.CQRS.Memory.Internal.EventStream
    ( StreamPosition
    , newEventStream
    ) where

import           Control.Applicative ((<$>))
import           Control.Concurrent.STM.TVar (readTVarIO)
import           Data.CQRS.Types.EventStream
import           Data.CQRS.Internal.PersistedEvent
import           Data.CQRS.Internal.StreamPosition
import           Data.CQRS.Memory.Internal.Storage
import qualified Data.Foldable as F
import           System.IO.Streams (InputStream)
import qualified System.IO.Streams.Combinators as SC
import qualified System.IO.Streams.List as SL

readEventStream :: forall i e a . Storage i e -> StreamPosition -> (InputStream (StreamPosition, PersistedEvent' i e) -> IO a) -> IO a
readEventStream (Storage store) (StreamPosition sp0) f = do
    -- Take a snapshot of all the events in the store
    allEvents <- msEvents <$> readTVarIO store
    -- Filter out irrelevant events
    let events = filter (\(Event _ _ t) -> t > sp0) $ F.toList allEvents
    -- Start streaming events.
    SL.fromList events >>= SC.map reformat >>= f
  where
    reformat :: Event i e -> (StreamPosition, PersistedEvent' i e)
    reformat (Event i e p) = (StreamPosition p, grow i e)

newEventStream :: Storage i e -> IO (EventStream i e)
newEventStream storage =
  return EventStream
    { esReadEventStream = readEventStream storage
    }
