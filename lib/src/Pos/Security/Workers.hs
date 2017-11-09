module Pos.Security.Workers
       ( securityWorkers
       ) where

import           Universum

import           Data.Time.Units            (Millisecond, convertUnit)
import           Formatting                 (build, sformat, (%))
import           Mockable                   (delay)
import           Serokell.Util              (sec)
import           System.Wlog                (logWarning)

import           Pos.Binary.Ssc             ()
import           Pos.Block.Logic            (needRecovery)
import           Pos.Block.Network          (requestTipOuts, triggerRecovery)
import           Pos.Communication.Protocol (OutSpecs, SendActions (..), WorkerSpec,
                                             worker)
import           Pos.Configuration          (HasNodeConfiguration,
                                             mdNoBlocksSlotThreshold)
import           Pos.Context                (getOurPublicKey, getUptime,
                                             recoveryCommGuard)
import           Pos.Core                   (SlotId (..), flattenEpochOrSlot,
                                             flattenSlotId, headerHash, headerLeaderKeyL,
                                             prevBlockL)
import           Pos.Core.Block             (BlockHeader)
import           Pos.Core.Configuration     (HasConfiguration, genesisHash)
import           Pos.Crypto                 (PublicKey)
import           Pos.DB                     (DBError (DBMalformed))
import           Pos.DB.Block               (MonadBlockDB, blkGetHeader)
import           Pos.DB.DB                  (getTipHeader)
import           Pos.Reporting              (reportMisbehaviour, reportOrLogE)
import           Pos.Slotting               (getCurrentSlot, getNextEpochSlotDuration)
import           Pos.WorkMode.Class         (WorkMode)

-- | Workers which perform security checks.
securityWorkers :: WorkMode ctx m => ([WorkerSpec m], OutSpecs)
securityWorkers = merge [checkForReceivedBlocksWorker]
  where
    merge = mconcat . map (first pure)

checkForReceivedBlocksWorker ::
    (WorkMode ctx m)
    => (WorkerSpec m, OutSpecs)
checkForReceivedBlocksWorker =
    worker requestTipOuts checkForReceivedBlocksWorkerImpl

checkEclipsed
    :: (MonadBlockDB m, HasConfiguration, HasNodeConfiguration)
    => PublicKey -> SlotId -> BlockHeader -> m Bool
checkEclipsed ourPk slotId x = notEclipsed x
  where
    onBlockLoadFailure header = do
        throwM $ DBMalformed $
            sformat ("Eclipse check: didn't manage to find parent of "%build%
                     " with hash "%build%", which is not genesis")
                    (headerHash header)
                    (header ^. prevBlockL)
    -- We stop looking for blocks when we've gone earlier than
    -- 'mdNoBlocksSlotThreshold':
    pastThreshold header =
        (flattenSlotId slotId - flattenEpochOrSlot header) >
        mdNoBlocksSlotThreshold
    -- Run the iteration starting from tip block; if we have found
    -- that we're eclipsed, we report it and ask neighbors for
    -- headers. If there are no main blocks generated by someone else
    -- in the past 'mdNoBlocksSlotThreshold' slots, it's bad and we've
    -- been eclipsed.  Here's how we determine that a block is good
    -- (i.e. main block generated not by us):
    isGoodBlock (Left _)   = False
    isGoodBlock (Right mb) = mb ^. headerLeaderKeyL /= ourPk
    -- Okay, now let's iterate until we see a good blocks or until we
    -- go past the threshold and there's no point in looking anymore:
    notEclipsed header = do
        let prevBlock = header ^. prevBlockL
        if | pastThreshold header     -> pure False
           | prevBlock == genesisHash -> pure True
           | isGoodBlock header       -> pure True
           | otherwise                ->
                 blkGetHeader prevBlock >>= \case
                     Just h  -> notEclipsed h
                     Nothing -> onBlockLoadFailure header $> True

-- FIX: CSL-1470 Do we need this logic? It's duplicated in practice by chain quality check
checkForReceivedBlocksWorkerImpl
    :: forall ctx m.
       (WorkMode ctx m)
    => SendActions m -> m ()
checkForReceivedBlocksWorkerImpl SendActions {..} = afterDelay $ do
    repeatOnInterval (const (sec' 4)) . recoveryCommGuard "security worker" $
        whenM (needRecovery @ctx) $ triggerRecovery enqueueMsg
    -- FIXME: 'repeatOnInterval' is looped, will the code below ever be called?
    repeatOnInterval (min (sec' 20)) . recoveryCommGuard "security worker" $ do
        ourPk <- getOurPublicKey
        let onSlotDefault slotId = do
                header <- getTipHeader
                unlessM (checkEclipsed ourPk slotId header) onEclipsed
        whenJustM getCurrentSlot onSlotDefault
  where
    sec' :: Int -> Millisecond
    sec' = convertUnit . sec
    afterDelay action = delay (sec 3) >> action
    onEclipsed = do
        logWarning $
            "Our neighbors are likely trying to carry out an eclipse attack! " <>
            "There are no blocks younger " <>
            "than 'mdNoBlocksSlotThreshold' that we didn't generate " <>
            "by ourselves"
        reportEclipse
    repeatOnInterval delF action = () <$ do
        -- REPORT:ERROR 'reportOrLogE' in block retrieval worker.
        () <$ action `catchAny` \e -> reportOrLogE "Security worker" e
        getNextEpochSlotDuration >>= delay . delF
        repeatOnInterval delF action
    reportEclipse = do
        bootstrapMin <- (+ sec 10) . convertUnit <$> getNextEpochSlotDuration
        nonTrivialUptime <- (> bootstrapMin) <$> getUptime
        let reason =
                "Eclipse attack was discovered, mdNoBlocksSlotThreshold: " <>
                show (mdNoBlocksSlotThreshold :: Int)
        -- REPORT:MISBEHAVIOUR(F) Possible eclipse attack was detected: new blocks are not propagated to us from other nodes
        when nonTrivialUptime $ recoveryCommGuard "security worker" $
            reportMisbehaviour True reason
