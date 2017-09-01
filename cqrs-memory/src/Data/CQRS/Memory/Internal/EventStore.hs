module Data.CQRS.Memory.Internal.EventStore
    ( newEventStore
    ) where

import           Control.Concurrent.STM (STM, atomically)
import           Control.Concurrent.STM.TVar (TVar, readTVar, modifyTVar')
import           Control.Monad (when, forM_)
import           Control.Monad.STM (throwSTM)
import           Data.CQRS.Internal.PersistedEvent
import           Data.CQRS.Types.Chunk (Chunk)
import qualified Data.CQRS.Types.Chunk as C
import           Data.CQRS.Types.EventStore (EventStore(..))
import           Data.CQRS.Types.StoreError (StoreError(..))
import           Data.CQRS.Memory.Internal.Storage
import qualified Data.Foldable as F
import           Data.Int (Int32)
import           Data.List (nub, sortBy)
import           Data.Ord (comparing)
import           Data.Sequence (Seq, (><))
import qualified Data.Sequence as S
import           Data.Typeable (Typeable)
import           System.IO.Streams (InputStream)
import qualified System.IO.Streams.List as SL
import qualified System.IO.Streams.Combinators as SC

storeEvents :: (Show i, Eq i, Typeable i) => Storage i e -> Chunk i e -> IO ()
storeEvents (Storage store) chunk = atomically $ do
    runSanityChecks
    -- Append to the list of all previous events
    modifyTVar' store addEvents
  where
    addEvents ms =
        -- Base timestamp
        let baseTimestamp = msCurrentTimestamp ms in
        -- Tag all the events with our wrapper
        let newTaggedEvents = map (\(e,ts) -> Event aggregateId e ts) (zip (F.toList newEvents) [baseTimestamp..]) in
        -- Update the storage
        ms { msEvents = msEvents ms >< S.fromList newTaggedEvents
           , msCurrentTimestamp = baseTimestamp + fromIntegral (length newTaggedEvents)
           }

    runSanityChecks = do
      -- Extract all existing events for this aggregate.
      events <- eventsByAggregateId store aggregateId
      -- Check for duplicates in the input list itself
      let newSequenceNumbers = F.toList $ fmap peSequenceNumber newEvents
      when (nub newSequenceNumbers /= newSequenceNumbers) $ throwSTM $ VersionConflict aggregateId
      -- Check for duplicate events
      let eventSequenceNumbers = F.toList $ fmap peSequenceNumber events
      forM_ newSequenceNumbers $ \newSequenceNumber ->
        when (newSequenceNumber `elem` eventSequenceNumbers) $
             throwSTM $ VersionConflict aggregateId
      -- Check version numbers; this exists as a sanity check for tests
      let vE = lastStoredVersion $ F.toList events
      let v0 = if null newEvents then
                   vE + 1
                 else
                   minimum $ fmap peSequenceNumber newEvents
      when (v0 /= vE + 1) $ error "Mismatched version numbers"

    lastStoredVersion [ ] = -1
    lastStoredVersion es  = maximum $ map peSequenceNumber es

    (aggregateId, newEvents) = C.toList chunk

retrieveEvents :: (Eq i) => Storage i e -> i -> Int32 -> (InputStream (PersistedEvent i e) -> IO a) -> IO a
retrieveEvents (Storage store) aggregateId v0 f = do
  events <- fmap F.toList $ atomically $ eventsByAggregateId store aggregateId
  SL.fromList events >>= SC.filter (\e -> peSequenceNumber e > v0) >>= f

retrieveAllEvents :: (Ord i) => Storage i e -> (InputStream (PersistedEvent' i e) -> IO a) -> IO a
retrieveAllEvents (Storage store) f = do
  -- We won't bother with efficiency since this is only
  -- really used for debugging/tests.
  events <- fmap msEvents $ atomically $ readTVar store
  let eventList = F.toList events
  inputStream <- SL.fromList $ sortBy (comparing cf) eventList
  SC.map (\(Event i event _) -> grow i event) inputStream >>= f
  where
    cf e = (eAggregateId e, peSequenceNumber $ ePersistedEvent e)


eventsByAggregateId :: (Eq i) => TVar (Store i e) -> i -> STM (Seq (PersistedEvent i e))
eventsByAggregateId store aggregateId = do
  events <- readTVar store
  return $ fmap ePersistedEvent $ S.filter (\e -> aggregateId == eAggregateId e) $ msEvents events

-- | Create a memory-backend event store.
newEventStore :: (Show i, Ord i, Typeable i) => Storage i e -> IO (EventStore i e)
newEventStore storage =
  return EventStore
    { esStoreEvents = storeEvents storage
    , esRetrieveEvents = retrieveEvents storage
    , esRetrieveAllEvents = retrieveAllEvents storage
    }
