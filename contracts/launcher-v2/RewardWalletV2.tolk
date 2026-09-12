import "../common/consts"
import "../common/errors"
import "../vendor/jetton/messages"
import "../vendor/jetton/storage"
import "reward-messages"
import "reward-types"

contract RewardWalletV2 {
    author: "GRAMDESKS"
    version: "2.0.0"
    description: "Reward-bearing jetton wallet (TEP-74 surface). Syncs its dividend position with the master before every transfer, burn or claim; every pending state has an exit."
    storage: RewardWalletStorage
    incomingMessages: AllowedMessageToRewardWallet
}

type AllowedMessageToRewardWallet =
    | AskToTransfer
    | AskToBurn
    | ClaimRewards
    | CancelSettle
    | RewardTransferStep
    | PoolDeliver
    | SettleAck
    | RestoreAccrued
    | TopUpTons

/// Gas the owner must attach on top of `forwardTonAmount` for a transfer
/// (Settle round trip + transfer step + possible recipient wallet deploy + notification).
const WALLET_TRANSFER_GAS = ton("0.1")
/// Gas for a burn (Settle round trip + SellNotify to the market + payout).
const WALLET_BURN_GAS = ton("0.16")
/// Gas for a claim excluding payouts (the owner adds PAYOUT_VALUE per reward to be paid).
const WALLET_CLAIM_GAS = ton("0.05")
/// Value sent to the vault for each reward payout (jetton transfer + possible wallet deploy).
const PAYOUT_VALUE = ton("0.07")
/// Kept out of the payout budget for the wallet's own compute and its excess message.
const CLAIM_KEEP = ton("0.02")
/// Minimum value that must remain with a transfer notification for the recipient's own compute.
const NOTIFY_MIN = ton("0.005")

fun RewardWalletStorage.assertIdle(self) {
    assert (self.pending == null) throw Errors.SettleInFlight;
}

fun RewardWalletStorage.openPending(
    mutate self,
    action: uint8,
    queryId: uint64,
    amount: coins,
    transfer: Cell<PendingTransfer>?,
) {
    self.pending = PendingOp {
        action,
        queryId,
        amount,
        startedAt: blockchain.now() as uint32,
        transfer,
    }.toCell();
}

fun RewardWalletStorage.sendSettle(
    self,
    queryId: uint64,
    action: uint8,
    burnAmount: coins,
    sellMinTon: coins?,
) {
    val settle = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: self.master,
        value: 0,
        body: Settle {
            queryId,
            owner: self.owner,
            action,
            burnAmount,
            sellMinTon,
        },
    });
    settle.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

/// Keeps what the wallet held before this message (at least the storage reserve).
fun keepOwnBalance(inValue: coins) {
    reserveToncoinsOnBalance(
        max(contract.getOriginalBalance() - inValue, MIN_STORAGE_RESERVE),
        RESERVE_MODE_AT_MOST,
    );
}

fun sendExcesses(to: address, queryId: uint64) {
    val excesses = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: ReturnExcessesBack { queryId },
    });
    // SAFETY: last action after a RESERVE of what we held before this message: carries the incoming value minus our fixed sends (rule 1, docs/10)
    excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy RewardWalletStorage.load();
    val msg = lazy AllowedMessageToRewardWallet.fromSlice(in.body);

    match (msg) {
        AskToTransfer => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.assertIdle();
            msg.forwardPayload.checkIsCorrectTlbEither();
            assert (
                msg.transferRecipient.getWorkchain() == BASECHAIN
            ) throw Errors.InvalidWorkchain;
            assert (
                in.valueCoins >= msg.forwardTonAmount + WALLET_TRANSFER_GAS
            ) throw Errors.InsufficientValue;
            assert (
                msg.jettonAmount > 0 && storage.balance >= msg.jettonAmount
            ) throw Errors.BudgetExceeded;
            val transfer = PendingTransfer {
                queryId: msg.queryId,
                amount: msg.jettonAmount,
                recipient: msg.transferRecipient,
                sendExcessesTo: msg.sendExcessesTo,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: beginCell().storeSlice(msg.forwardPayload).endCell(),
            }.toCell();
            storage.balance -= msg.jettonAmount;
            storage.openPending(ACTION_SYNC, msg.queryId, msg.jettonAmount, transfer);
            storage.save();
            storage.sendSettle(msg.queryId, ACTION_SYNC, 0, null);
        }

        AskToBurn => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.assertIdle();
            assert (in.valueCoins >= WALLET_BURN_GAS) throw Errors.InsufficientValue;
            assert (
                msg.jettonAmount > 0 && storage.balance >= msg.jettonAmount
            ) throw Errors.BudgetExceeded;
            var sellMinTon: coins? = null;
            if (msg.customPayload != null) {
                val intent = SellIntent.fromCell(msg.customPayload);
                sellMinTon = intent.minTon;
            }
            storage.balance -= msg.jettonAmount;
            storage.openPending(ACTION_BURN, msg.queryId, msg.jettonAmount, null);
            storage.save();
            storage.sendSettle(msg.queryId, ACTION_BURN, msg.jettonAmount, sellMinTon);
        }

        ClaimRewards => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.assertIdle();
            assert (in.valueCoins >= WALLET_CLAIM_GAS) throw Errors.InsufficientValue;
            storage.openPending(ACTION_CLAIM, msg.queryId, 0, null);
            storage.save();
            storage.sendSettle(msg.queryId, ACTION_CLAIM, 0, null);
        }

        SettleAck => {
            assert (in.senderAddress == storage.master) throw Errors.NotFromMaster;
            assert (storage.pending != null) throw Errors.NothingPending;
            val op = storage.pending.load();
            assert (op.queryId == msg.queryId) throw ERR_PENDING_MISMATCH;
            // the lot in flight earned until the master processed the Settle; on a retry the master's
            // indices may be newer than that, so the lot is left out (conservative)
            val earning: coins = msg.retry ? storage.balance : storage.balance + op.amount;
            storage.freezeAt(msg.indices, earning);
            storage.pending = null;

            if (op.action == ACTION_SYNC) {
                val t = op.transfer!.load();
                storage.save();
                val step = createMessage({
                    bounce: BounceMode.Only256BitsOfBody,
                    dest: calcDeployedRewardWallet(t.recipient, storage.master, contract.getCode()),
                    value: 0,
                    body: RewardTransferStep {
                        queryId: t.queryId,
                        jettonAmount: t.amount,
                        transferInitiator: storage.owner,
                        sendExcessesTo: t.sendExcessesTo,
                        forwardTonAmount: t.forwardTonAmount,
                        indices: storage.stamps,
                        forwardPayload: t.forwardPayload.beginParse(),
                    },
                });
                step.send(
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                );
                return;
            }

            keepOwnBalance(in.valueCoins);
            if (op.action == ACTION_CLAIM) {
                assert (msg.vault != null) throw Errors.NotWired;
                // pay as many rewards as the attached value allows; the rest stays claimable
                var budget: coins = in.valueCoins > CLAIM_KEEP
                    ? in.valueCoins - CLAIM_KEEP
                    : (0 as coins);
                var rest: map<uint8, coins> = [];
                var r = storage.accrued.findFirst();
                while (r.isFound) {
                    val id = r.getKey();
                    val amount = r.loadValue();
                    if (amount > 0 && budget >= PAYOUT_VALUE) {
                        val pay = createMessage({
                            bounce: BounceMode.Only256BitsOfBody,
                            dest: msg.vault!,
                            value: PAYOUT_VALUE,
                            body: PayRewardReq {
                                queryId: msg.queryId,
                                rewardId: id,
                                amount,
                                owner: storage.owner,
                            },
                        });
                        pay.send(SEND_MODE_PAY_FEES_SEPARATELY);
                        budget -= PAYOUT_VALUE;
                    } else if (amount > 0) {
                        rest.set(id, amount);
                    }
                    r = storage.accrued.iterateNext(r);
                }
                storage.accrued = rest;
            }
            storage.save();
            sendExcesses(storage.owner, msg.queryId);
        }

        CancelSettle => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            assert (storage.pending != null) throw Errors.NothingPending;
            val op = storage.pending.load();
            assert (op.queryId == msg.queryId) throw ERR_PENDING_MISMATCH;
            assert (
                blockchain.now() >= op.startedAt + PENDING_TIMEOUT
            ) throw Errors.PendingNotExpired;
            // SYNC / CLAIM: the master changed nothing, the lot comes back. BURN: the master burned
            // (a refused Settle bounces within seconds), the coins are gone for good.
            if (op.action == ACTION_SYNC) {
                storage.balance += op.amount;
            }
            storage.pending = null;
            storage.save();
            val excesses = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.owner,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            excesses.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
        }

        RewardTransferStep => {
            if (in.senderAddress != storage.master) {
                assert (msg.transferInitiator != null) throw Errors.NotFromRewardWallet;
                val initiator: address = msg.transferInitiator;
                assert (
                    in.senderAddress ==
                    calcRewardWalletAddress(initiator, storage.master, contract.getCode())
                ) throw Errors.NotFromRewardWallet;
            }
            storage.receiveStep(
                in.valueCoins,
                msg.queryId,
                msg.jettonAmount,
                msg.transferInitiator,
                msg.sendExcessesTo,
                msg.forwardTonAmount,
                msg.indices,
                msg.forwardPayload,
            );
        }

        PoolDeliver => {
            assert (in.senderAddress == storage.master) throw Errors.NotFromMaster;
            storage.receiveStep(
                in.valueCoins,
                msg.queryId,
                msg.jettonAmount,
                null,
                msg.sendExcessesTo,
                msg.forwardTonAmount,
                msg.indices,
                emptyForwardPayload(),
            );
        }

        RestoreAccrued => {
            assert (in.senderAddress == storage.master) throw Errors.NotFromMaster;
            storage
                .accrued
                .set(msg.rewardId, (amountOf(storage.accrued, msg.rewardId) + msg.amount) as coins);
            storage.save();
        }

        TopUpTons => {
            // accept
        }

        else => {
            // plain TON = gas top-up (reference jetton-wallet behaviour); anything else bounces
            assert (in.body.isEmpty()) throw 0xFFFF;
        }
    }
}

/// Credits an incoming lot frozen at `indices`, notifies the owner, returns the excess.
fun RewardWalletStorage.receiveStep(
    mutate self,
    inValue: coins,
    queryId: uint64,
    amount: coins,
    initiator: address?,
    sendExcessesTo: address?,
    forwardTonAmount: coins,
    indices: map<uint8, uint128>,
    forwardPayload: slice,
) {
    // checked before any state change so a bounce of the step gives the coins back to the sender
    assert (
        forwardTonAmount == 0 || inValue >= forwardTonAmount + NOTIFY_MIN
    ) throw Errors.InsufficientValue;
    self.receiveLot(amount, indices);
    self.save();
    if (forwardTonAmount != 0) {
        val notify = createMessage({
            bounce: BounceMode.NoBounce,
            dest: self.owner,
            value: forwardTonAmount,
            body: TransferNotificationForRecipient {
                queryId,
                jettonAmount: amount,
                transferInitiator: initiator,
                forwardPayload,
            },
        });
        notify.send(SEND_MODE_PAY_FEES_SEPARATELY);
    }
    if (sendExcessesTo != null) {
        keepOwnBalance(inValue);
        sendExcesses(sendExcessesTo, queryId);
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy RewardWalletStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op == 0x52570001) {
        // Settle refused by the master (sell while the curve is closed, master out of value...):
        // nothing was committed there, the lot comes back
        assert (in.senderAddress == storage.master) throw Errors.NotFromMaster;
        if (storage.pending == null) {
            return;
        }
        val pending = storage.pending.load();
        val queryId = in.bouncedBody.loadUint(64);
        if (pending.queryId != queryId) {
            return;
        }
        storage.balance += pending.amount;
        storage.pending = null;
        storage.save();
        return;
    }
    // Rule 3 (sender checks on bounces) is relaxed below on purpose: a bounced message can only originate from a
    // message this very wallet sent (the network sets `bounced` itself, a third party cannot forge the flag), and the
    // wallet does not store the vault's address nor every recipient wallet it ever paid. Only the opcode and the
    // 256-bit bounced body identify what came back. (Audit 3, SEC-216.)
    if (op == 0x52570003) {
        // RewardTransferStep bounced: the recipient wallet refused, tokens come back
        assert (in.senderAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
        in.bouncedBody.skipBits(64);
        val amount = in.bouncedBody.loadCoins();
        storage.balance += amount;
        storage.save();
        return;
    }
    if (op == 0x52570026) {
        // PayRewardReq refused by the vault: the reward is claimable again
        in.bouncedBody.skipBits(64);
        val rewardId = in.bouncedBody.loadUint(8) as uint8;
        val amount = in.bouncedBody.loadCoins();
        storage.accrued.set(rewardId, (amountOf(storage.accrued, rewardId) + amount) as coins);
        storage.save();
    }
}

get fun get_wallet_data(): JettonWalletDataReply {
    val storage = lazy RewardWalletStorage.load();
    return {
        jettonBalance: storage.balance,
        ownerAddress: storage.owner,
        minterAddress: storage.master,
        jettonWalletCode: contract.getCode(),
    };
}

get fun get_reward_wallet_data(): RewardWalletDataReply {
    val storage = lazy RewardWalletStorage.load();
    return {
        balance: storage.balance,
        owner: storage.owner,
        master: storage.master,
        stamps: storage.stamps,
        accrued: storage.accrued,
        pending: storage.pending != null ? storage.pending.load() : null,
    };
}

/// Rewards claimable at `indices` (as returned by the master's get_reward_master_data).
get fun get_claimable(indices: map<uint8, uint128>): map<uint8, coins> {
    val storage = lazy RewardWalletStorage.load();
    var out: map<uint8, coins> = [];
    var r = indices.findFirst();
    while (r.isFound) {
        val id = r.getKey();
        val owed = owedFor(
            storage.balance,
            r.loadValue() as int,
            indexOf(storage.stamps, id),
            amountOf(storage.accrued, id),
        );
        if (owed > 0) {
            out.set(id, owed as coins);
        }
        r = indices.iterateNext(r);
    }
    return out;
}

get fun get_code_version(): int {
    return LAUNCHER_CODE_VERSION;
}
