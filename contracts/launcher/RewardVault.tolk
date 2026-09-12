import "@contracts/common/consts"
import "@contracts/common/dedust"
import "@contracts/common/errors"
import "@contracts/vendor/jetton/messages"
import "fee-splitter-messages"
import "reward-messages"
import "reward-types"

contract RewardVault {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Holds the holders' TON share of a launched coin, converts it to reward jettons through a whitelisted DEX (keeper-triggered, bounded), bumps the master's indices and pays claims."
    storage: RewardVaultStorage
    incomingMessages: AllowedMessageToRewardVault
}

type AllowedMessageToRewardVault =
    | RewardIn
    | ConvertReward
    | CancelVaultPending
    | TransferNotificationForRecipient
    | IndexBumpRefused
    | PayReward
    | AddReward
    | ResponseWalletAddress
    | SetVaultDex
    | SetVaultRoles
    | ReturnExcessesBack
    | DedustPayout
    | TopUpTons

/// Value attached to IndexBump towards the master.
const BUMP_VALUE = ton("0.03")
/// Value kept from a keeper ConvertReward for our own compute; the rest funds the DEX gas chain.
const CONVERT_KEEPER_GAS = ton("0.02")
/// Value attached to each TEP-89 wallet discovery request.
const DISCOVERY_VALUE = ton("0.03")

/// Asks every reward jetton master whose wallet is still unknown for our wallet address.
fun RewardVaultStorage.discoverWallets(self, queryId: uint64) {
    var r = self.rewards.findFirst();
    while (r.isFound) {
        val slot = r.loadValue();
        if (slot.vaultWallet == null) {
            val req = createMessage({
                bounce: BounceMode.NoBounce,
                dest: slot.rewardMaster,
                value: DISCOVERY_VALUE,
                body: RequestWalletAddress { queryId, ownerAddress: contract.getAddress(), includeOwnerAddress: true },
            });
            req.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }
        r = self.rewards.iterateNext(r);
    }
}

fun RewardVaultStorage.findRewardByMaster(self, master: address): int {
    var r = self.rewards.findFirst();
    while (r.isFound) {
        if (r.loadValue().rewardMaster == master) {
            return r.getKey();
        }
        r = self.rewards.iterateNext(r);
    }
    return -1;
}

fun emitVaultEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun RewardVaultStorage.findRewardByWallet(self, wallet: address): int {
    var r = self.rewards.findFirst();
    while (r.isFound) {
        val slot = r.loadValue();
        if (slot.vaultWallet != null && slot.vaultWallet == wallet) {
            return r.getKey();
        }
        r = self.rewards.iterateNext(r);
    }
    return -1;
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy RewardVaultStorage.load();
    val msg = lazy AllowedMessageToRewardVault.fromSlice(in.body);

    match (msg) {
        RewardIn => {
            storage.totalTonIn += in.valueCoins;
            storage.save();
        }

        ConvertReward => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.keeper) throw Errors.NotFromKeeper;
            assert (storage.pending == null) throw Errors.OperationInFlight;
            assert (storage.rewardCount > 0 && storage.rewards.exists(msg.rewardId)) throw Errors.RewardUnknown;
            assert (msg.rewardId == storage.cycleNext) throw Errors.NotRotationNext;
            assert (storage.dexPools.exists(msg.pool)) throw Errors.DestNotWhitelisted;
            val available = contract.getOriginalBalance() - in.valueCoins - storage.reserve;
            assert (msg.spend > 0 && msg.spend <= available) throw Errors.BudgetExceeded;
            assert (msg.minOut > 0) throw Errors.InvalidParams;
            assert (in.valueCoins >= DEDUST_SWAP_GAS + CONVERT_KEEPER_GAS) throw Errors.InsufficientValue;

            storage.totalTonSpent += msg.spend;
            storage.pending = VaultPending {
                rewardId: msg.rewardId,
                spend: msg.spend,
                minOut: msg.minOut,
                startedAt: blockchain.now() as uint32,
            }.toCell();
            storage.save();

            // receiver and limit are ours (F-01): the keeper only picks a whitelisted pool, amount and minimum
            val swap = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.dexVault,
                value: msg.spend + in.valueCoins - CONVERT_KEEPER_GAS,
                body: buildDedustNativeSwap(msg.queryId, msg.spend, msg.pool, msg.minOut, contract.getAddress()),
            });
            swap.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        CancelVaultPending => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.keeper) throw Errors.NotFromKeeper;
            assert (storage.pending != null) throw Errors.NothingPending;
            val pending = storage.pending.load();
            assert (blockchain.now() >= pending.startedAt + storage.pendingTimeout) throw Errors.PendingNotExpired;
            storage.pending = null;
            storage.save();
        }

        TransferNotificationForRecipient => {
            val id = storage.findRewardByWallet(in.senderAddress);
            assert (id >= 0) throw Errors.UnknownJettonWallet;
            var slot = storage.rewards.mustGet(id as uint8);
            val pending = storage.pending != null ? storage.pending.load() : null;
            if (pending != null && pending.rewardId == id) {
                emitVaultEvent(EVENT_TOPIC_REWARD_CONVERTED, RewardConvertedEvent {
                    rewardId: id as uint8,
                    spendTon: pending.spend,
                    received: msg.jettonAmount,
                    minOut: pending.minOut,
                });
                storage.pending = null;
                storage.cycleNext = ((id + 1) % storage.rewardCount) as uint8;
            }
            val amount = msg.jettonAmount + slot.carry;
            slot.carry = 0;
            storage.rewards.set(id as uint8, slot);
            storage.save();

            val roles = lazy storage.roles.load();
            // bounceable: a refused bump (index overflow) comes back and is kept as carry
            val bump = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: roles.master,
                value: BUMP_VALUE,
                body: IndexBump { queryId: msg.queryId, rewardId: id as uint8, amount },
            });
            bump.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        IndexBumpRefused => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.master) throw Errors.NotFromMaster;
            var slot = storage.rewards.mustGet(msg.rewardId, Errors.RewardUnknown as int);
            slot.carry += msg.amount;
            storage.rewards.set(msg.rewardId, slot);
            storage.save();
            emitVaultEvent(EVENT_TOPIC_REWARD_UNALLOCATED, IndexBumpRefused { queryId: msg.queryId, rewardId: msg.rewardId, amount: msg.amount });
        }

        PayReward => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.master) throw Errors.NotFromMaster;
            var slot = storage.rewards.mustGet(msg.rewardId, Errors.RewardUnknown as int);
            assert (slot.vaultWallet != null) throw Errors.NotWired;
            slot.paid += msg.amount;
            storage.rewards.set(msg.rewardId, slot);
            storage.save();
            val transfer = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: slot.vaultWallet!,
                value: 0,
                body: AskToTransfer {
                    queryId: msg.queryId,
                    jettonAmount: msg.amount,
                    transferRecipient: msg.owner,
                    sendExcessesTo: msg.owner,
                    customPayload: null,
                    forwardTonAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            transfer.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            emitVaultEvent(EVENT_TOPIC_REWARD_PAID, RewardPaidEvent { owner: msg.owner, rewardId: msg.rewardId, amount: msg.amount });
        }

        AddReward => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            assert (msg.rewardId == storage.rewardCount && msg.rewardId < MAX_REWARDS) throw Errors.TooManyRewards;
            assert (in.valueCoins >= DISCOVERY_VALUE + ton("0.01")) throw Errors.InsufficientValue;
            storage.rewards.set(msg.rewardId, RewardSlot { rewardMaster: msg.rewardMaster, vaultWallet: null, carry: 0, paid: 0 });
            storage.rewardCount += 1;
            storage.save();
            storage.discoverWallets(msg.queryId);
        }

        ResponseWalletAddress => {
            val id = storage.findRewardByMaster(in.senderAddress);
            assert (id >= 0) throw Errors.RewardUnknown;
            assert (msg.jettonWalletAddress != null) throw Errors.InvalidParams;
            if (msg.ownerAddress != null) {
                assert (msg.ownerAddress.load() == contract.getAddress()) throw Errors.InvalidParams;
            }
            var slot = storage.rewards.mustGet(id as uint8);
            slot.vaultWallet = msg.jettonWalletAddress;
            storage.rewards.set(id as uint8, slot);
            storage.save();
        }

        TopUpTons => {
            // deploy / gas top-up: discover wallets of rewards configured at deployment
            storage.discoverWallets(0);
        }

        SetVaultDex => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            if (msg.allowed) {
                storage.dexPools.set(msg.pool, true);
            } else {
                storage.dexPools.delete(msg.pool);
            }
            storage.save();
        }

        SetVaultRoles => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            storage.roles = RewardVaultRoles { admin: msg.admin, keeper: msg.keeper, master: msg.master }.toCell();
            storage.save();
        }

        ReturnExcessesBack => {
            // gas back from our own jetton transfers
        }

        DedustPayout => {
            // TON back from the DEX vault: a rejected swap returns the whole amount (conversion undone),
            // anything smaller is leftover gas kept as reserve.
            assert (in.senderAddress == storage.dexVault) throw Errors.DestNotWhitelisted;
            if (storage.pending != null) {
                val pending = storage.pending.load();
                if (in.valueCoins + DEDUST_SWAP_GAS >= pending.spend) {
                    storage.totalTonSpent -= pending.spend;
                    storage.pending = null;
                    storage.save();
                }
            }
        }

        else => {
            // plain TON (gas top-up, DEX excess): kept as reserve, not counted as holders income
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy RewardVaultStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op == 0x52570014) {
        // IndexBump refused by the master (index would overflow): the reward stays here as carry
        in.bouncedBody.skipBits(64);
        val rewardId = in.bouncedBody.loadUint(8) as uint8;
        val amount = in.bouncedBody.loadCoins();
        var slot = storage.rewards.mustGet(rewardId, Errors.RewardUnknown as int);
        slot.carry += amount;
        storage.rewards.set(rewardId, slot);
        storage.save();
        emitVaultEvent(EVENT_TOPIC_REWARD_UNALLOCATED, IndexBumpRefused { queryId: 0, rewardId, amount });
        return;
    }
    if (storage.pending == null) {
        return;
    }
    // AskToTransfer (payout) or RequestWalletAddress bounced: nothing to restore in pending.
    // Anything else while pending is the DEX refusing our swap: TON came back.
    if (op != 0x0f8a7ea5 && op != 0x2c76b973) {
        val pending = storage.pending.load();
        storage.totalTonSpent -= pending.spend;
        storage.pending = null;
        storage.save();
    }
}

get fun get_vault_data(): RewardVaultDataReply {
    val storage = lazy RewardVaultStorage.load();
    return {
        rewardCount: storage.rewardCount,
        cycleNext: storage.cycleNext,
        totalTonIn: storage.totalTonIn,
        totalTonSpent: storage.totalTonSpent,
        reserve: storage.reserve,
        roles: storage.roles.load(),
        rewards: storage.rewards,
        pending: storage.pending != null ? storage.pending.load() : null,
    };
}
