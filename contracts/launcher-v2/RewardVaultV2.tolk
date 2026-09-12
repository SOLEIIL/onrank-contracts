import "../common/consts"
import "../common/dedust"
import "../common/errors"
import "../vendor/jetton/messages"
import "fee-splitter-messages"
import "reward-messages"
import "reward-types"
import "vault-messages"
import "vault-types"

contract RewardVaultV2 {
    author: "GRAMDESKS"
    version: "2.0.0"
    description: "Holds the holders' TON share of a launched coin, converts it to reward jettons through a whitelisted DEX (keeper-triggered, bounded), bumps the master's indices and pays the claims of the coin's wallets. Every failure path gives the reward back."
    storage: RewardVaultStorage
    incomingMessages: AllowedMessageToRewardVault
}

type AllowedMessageToRewardVault =
    | RewardIn
    | ConvertReward
    | CancelVaultPending
    | TransferNotificationForRecipient
    | IndexBumpRefused
    | PayRewardReq
    | AddReward
    | Rediscover
    | ResponseWalletAddress
    | ProposeVaultChange
    | ApplyVaultChange
    | ReturnExcessesBack
    | DedustPayout
    | TopUpTons

/// Value attached to IndexBump towards the master.
const BUMP_VALUE = ton("0.03")
/// Value kept from a keeper ConvertReward for our own compute; the rest funds the DEX gas chain.
const CONVERT_KEEPER_GAS = ton("0.02")
/// Value attached to each TEP-89 wallet discovery request.
const DISCOVERY_VALUE = ton("0.03")
/// Our own compute on AddReward / Rediscover, on top of the discovery requests.
const DISCOVERY_MARGIN = ton("0.01")
/// Value forwarded to the master with a PayRewardFailed (master compute + RestoreAccrued to the wallet).
const PAY_FAILED_VALUE = ton("0.02")

fun emitVaultEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun RewardVaultStorage.countUndiscovered(self): int {
    var n = 0;
    var r = self.rewards.findFirst();
    while (r.isFound) {
        if (r.loadValue().vaultWallet == null) {
            n += 1;
        }
        r = self.rewards.iterateNext(r);
    }
    return n;
}

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
                body: RequestWalletAddress {
                    queryId,
                    ownerAddress: contract.getAddress(),
                    includeOwnerAddress: true,
                },
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
            assert (
                storage.rewardCount > 0 && storage.rewards.exists(msg.rewardId)
            ) throw Errors.RewardUnknown;
            assert (msg.rewardId == storage.cycleNext) throw Errors.NotRotationNext;
            val extra = lazy storage.extra.load();
            assert (extra.dexPools.exists(msg.pool)) throw Errors.DestNotWhitelisted;
            val available = contract.getOriginalBalance() - in.valueCoins - storage.reserve;
            assert (msg.spend > 0 && msg.spend <= available) throw Errors.BudgetExceeded;
            assert (msg.minOut > 0) throw Errors.InvalidParams;
            assert (
                in.valueCoins >= DEDUST_SWAP_GAS + CONVERT_KEEPER_GAS
            ) throw Errors.InsufficientValue;

            storage.totalTonSpent += msg.spend;
            storage.pending = VaultPending {
                rewardId: msg.rewardId,
                spend: msg.spend,
                minOut: msg.minOut,
                startedAt: blockchain.now() as uint32,
                queryId: msg.queryId,
            }.toCell();
            storage.save();

            // receiver and limit are ours: the keeper only picks a whitelisted pool, amount and minimum
            val swap = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.dexVault,
                value: msg.spend + in.valueCoins - CONVERT_KEEPER_GAS,
                body: buildDedustNativeSwap(
                    msg.queryId,
                    msg.spend,
                    msg.pool,
                    msg.minOut,
                    contract.getAddress(),
                ),
            });
            swap.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        CancelVaultPending => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.keeper) throw Errors.NotFromKeeper;
            assert (storage.pending != null) throw Errors.NothingPending;
            val pending = storage.pending.load();
            assert (
                blockchain.now() >= pending.startedAt + storage.pendingTimeout
            ) throw Errors.PendingNotExpired;
            storage.pending = null;
            storage.save();
        }

        TransferNotificationForRecipient => {
            val id = storage.findRewardByWallet(in.senderAddress);
            assert (id >= 0) throw Errors.UnknownJettonWallet;
            var slot = storage.rewards.mustGet(id as uint8);
            val pending = storage.pending != null ? storage.pending.load() : null;
            if (pending != null && pending.rewardId == id) {
                emitVaultEvent(
                    EVENT_TOPIC_REWARD_CONVERTED,
                    RewardConvertedEvent {
                        rewardId: id as uint8,
                        spendTon: pending.spend,
                        received: msg.jettonAmount,
                        minOut: pending.minOut,
                    },
                );
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
                body: IndexBump {
                    queryId: msg.queryId,
                    rewardId: id as uint8,
                    amount,
                },
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
            emitVaultEvent(
                EVENT_TOPIC_REWARD_UNALLOCATED,
                IndexBumpRefused {
                    queryId: msg.queryId,
                    rewardId: msg.rewardId,
                    amount: msg.amount,
                },
            );
        }

        PayRewardReq => {
            val roles = lazy storage.roles.load();
            // only a wallet of our coin can ask (its address is derived from the master and the owner)
            assert (
                in.senderAddress ==
                calcRewardWalletAddress(msg.owner, roles.master, roles.walletCode)
            ) throw Errors.NotFromRewardWallet;
            var slot = storage.rewards.mustGet(msg.rewardId, Errors.RewardUnknown as int);
            assert (slot.vaultWallet != null) throw Errors.NotWired;
            assert (msg.amount > 0) throw Errors.InvalidParams;
            slot.paid += msg.amount;
            storage.rewards.set(msg.rewardId, slot);
            storage.payoutNonce += 1;
            var extra = storage.extra.load();
            if (storage.payoutNonce > VAULT_PAYOUT_RING) {
                extra.payouts.delete(storage.payoutNonce - VAULT_PAYOUT_RING);
            }
            extra
                .payouts
                .set(
                    storage.payoutNonce,
                    {
                        owner: msg.owner,
                        rewardId: msg.rewardId,
                        amount: msg.amount,
                    },
                );
            storage.extra = extra.toCell();
            storage.save();
            val transfer = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: slot.vaultWallet!,
                value: 0,
                body: AskToTransfer {
                    queryId: storage.payoutNonce,
                    jettonAmount: msg.amount,
                    transferRecipient: msg.owner,
                    sendExcessesTo: msg.owner,
                    customPayload: null,
                    forwardTonAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            transfer.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            emitVaultEvent(
                EVENT_TOPIC_REWARD_PAID,
                RewardPaidEvent {
                    owner: msg.owner,
                    rewardId: msg.rewardId,
                    amount: msg.amount,
                },
            );
        }

        AddReward => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            assert (
                msg.rewardId == storage.rewardCount && msg.rewardId < MAX_REWARDS
            ) throw Errors.TooManyRewards;
            // one slot per master (SEC-201): answers are attributed by master
            assert (storage.findRewardByMaster(msg.rewardMaster) < 0) throw Errors.InvalidParams;
            storage
                .rewards
                .set(
                    msg.rewardId,
                    RewardSlot {
                        rewardMaster: msg.rewardMaster,
                        vaultWallet: null,
                        carry: 0,
                        paid: 0,
                    },
                );
            storage.rewardCount += 1;
            storage.save();
            assert (
                in.valueCoins >= storage.countUndiscovered() * DISCOVERY_VALUE + DISCOVERY_MARGIN
            ) throw Errors.InsufficientValue;
            storage.discoverWallets(msg.queryId);
        }

        Rediscover => {
            val roles = lazy storage.roles.load();
            assert (
                in.senderAddress == roles.admin || in.senderAddress == roles.keeper
            ) throw Errors.NotFromAdmin;
            assert (
                in.valueCoins >= storage.countUndiscovered() * DISCOVERY_VALUE + DISCOVERY_MARGIN
            ) throw Errors.InsufficientValue;
            storage.discoverWallets(msg.queryId);
        }

        ResponseWalletAddress => {
            val id = storage.findRewardByMaster(in.senderAddress);
            assert (id >= 0) throw Errors.RewardUnknown;
            assert (msg.jettonWalletAddress != null) throw Errors.InvalidParams;
            if (msg.ownerAddress != null) {
                assert (
                    msg.ownerAddress.load() == contract.getAddress()
                ) throw Errors.InvalidParams;
            }
            var slot = storage.rewards.mustGet(id as uint8);
            slot.vaultWallet = msg.jettonWalletAddress;
            storage.rewards.set(id as uint8, slot);
            storage.save();
        }

        TopUpTons => {
            // deploy / gas top-up. The Factory funds the discovery of the rewards configured at deployment.
            if (
                storage.countUndiscovered() > 0 &&
                in.valueCoins >= storage.countUndiscovered() * DISCOVERY_VALUE + DISCOVERY_MARGIN
            ) {
                storage.discoverWallets(0);
            }
        }

        ProposeVaultChange => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            // the payload must parse now, not in 48 h
            if (msg.kind == VAULT_PROPOSAL_DEX) {
                VaultDexChange.fromCell(msg.payload);
            } else if (msg.kind == VAULT_PROPOSAL_ROLES) {
                VaultRolesChange.fromCell(msg.payload);
            } else {
                throw Errors.InvalidParams;
            }
            var extra = storage.extra.load();
            val readyAt = (blockchain.now() + VAULT_DELAY) as uint32;
            extra.proposal = VaultProposal {
                kind: msg.kind,
                payload: msg.payload,
                readyAt,
            }.toCell();
            storage.extra = extra.toCell();
            storage.save();
            emitVaultEvent(
                EVENT_TOPIC_VAULT_CHANGED,
                VaultChangedEvent {
                    kind: msg.kind,
                    applied: false,
                    readyAt,
                },
            );
        }

        ApplyVaultChange => {
            val roles = storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            var extra = storage.extra.load();
            assert (extra.proposal != null) throw Errors.NothingPending;
            val proposal = extra.proposal.load();
            assert (blockchain.now() >= proposal.readyAt) throw Errors.PendingNotExpired;
            if (proposal.kind == VAULT_PROPOSAL_DEX) {
                val change = VaultDexChange.fromCell(proposal.payload);
                if (change.allowed) {
                    extra.dexPools.set(change.pool, true);
                } else {
                    extra.dexPools.delete(change.pool);
                }
            } else {
                val change = VaultRolesChange.fromCell(proposal.payload);
                storage.roles = RewardVaultRoles {
                    admin: change.admin,
                    keeper: change.keeper,
                    master: roles.master,
                    walletCode: roles.walletCode,
                }.toCell();
            }
            extra.proposal = null;
            storage.extra = extra.toCell();
            storage.save();
            emitVaultEvent(
                EVENT_TOPIC_VAULT_CHANGED,
                VaultChangedEvent {
                    kind: proposal.kind,
                    applied: true,
                    readyAt: proposal.readyAt,
                },
            );
        }

        ReturnExcessesBack => {
            // gas back from our own jetton transfers (anyone can send this: no state change)
        }

        DedustPayout => {
            // TON back from the DEX vault: a rejected swap returns the whole amount (conversion undone),
            // anything smaller is leftover gas kept as reserve. Matched on the swap's queryId.
            assert (in.senderAddress == storage.dexVault) throw Errors.DestNotWhitelisted;
            if (storage.pending != null) {
                val pending = storage.pending.load();
                if (
                    pending.queryId == msg.queryId &&
                    in.valueCoins + DEDUST_SWAP_GAS >= pending.spend
                ) {
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
    val roles = lazy storage.roles.load();

    if (op == 0x52570014) {
        // IndexBump refused by the master (index would overflow): the reward stays here as carry
        assert (in.senderAddress == roles.master) throw Errors.NotFromMaster;
        in.bouncedBody.skipBits(64);
        val rewardId = in.bouncedBody.loadUint(8) as uint8;
        val amount = in.bouncedBody.loadCoins();
        var slot = storage.rewards.mustGet(rewardId, Errors.RewardUnknown as int);
        slot.carry += amount;
        storage.rewards.set(rewardId, slot);
        storage.save();
        emitVaultEvent(
            EVENT_TOPIC_REWARD_UNALLOCATED,
            IndexBumpRefused {
                queryId: 0,
                rewardId,
                amount,
            },
        );
        return;
    }
    if (op == 0x0f8a7ea5) {
        // a payout transfer bounced: the reward goes back to the holder's wallet through the master
        val queryId = in.bouncedBody.loadUint(64);
        val amount = in.bouncedBody.loadCoins();
        var extra = storage.extra.load();
        val found = extra.payouts.get(queryId);
        if (!found.isFound) {
            return;
        }
        val payout = found.loadValue();
        assert (
            storage.findRewardByWallet(in.senderAddress) == payout.rewardId
        ) throw Errors.UnknownJettonWallet;
        var slot = storage.rewards.mustGet(payout.rewardId);
        slot.paid -= min(amount, slot.paid);
        storage.rewards.set(payout.rewardId, slot);
        extra.payouts.delete(queryId);
        storage.extra = extra.toCell();
        storage.save();
        val failed = createMessage({
            bounce: BounceMode.NoBounce,
            dest: roles.master,
            value: 0,
            body: PayRewardFailed {
                queryId,
                owner: payout.owner,
                rewardId: payout.rewardId,
                amount,
            },
        });
        failed.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
        return;
    }
    // (discovery requests are NoBounce: nothing to handle for them)
    if (op == 0xea06185d && storage.pending != null) {
        // the DEX refused our swap: TON came back, conversion undone
        assert (in.senderAddress == storage.dexVault) throw Errors.DestNotWhitelisted;
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
        payoutNonce: storage.payoutNonce,
        roles: storage.roles.load(),
        rewards: storage.rewards,
        pending: storage.pending != null ? storage.pending.load() : null,
        proposal: storage.extra.load().proposal != null
            ? storage.extra.load().proposal!.load()
            : null,
    };
}

get fun get_code_version(): int {
    return LAUNCHER_CODE_VERSION;
}
