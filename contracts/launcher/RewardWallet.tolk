import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/vendor/jetton/messages"
import "@contracts/vendor/jetton/storage"
import "reward-messages"
import "reward-types"

contract RewardWallet {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Reward-bearing jetton wallet (TEP-74 surface). Syncs its dividend position with the master before every transfer, burn or claim."
    storage: RewardWalletStorage
    incomingMessages: AllowedMessageToRewardWallet
}

type AllowedMessageToRewardWallet =
    | AskToTransfer
    | AskToBurn
    | ClaimRewards
    | RewardTransferStep
    | SettleAck
    | TopUpTons

/// Gas the owner must attach on top of `forwardTonAmount` for a transfer
/// (Settle round trip + transfer step + possible recipient wallet deploy + notification).
const WALLET_TRANSFER_GAS = ton("0.1")
/// Gas for a burn (Settle round trip + SellNotify to the curve + payout).
const WALLET_BURN_GAS = ton("0.12")
/// Gas for a claim excluding payouts (the master adds PAYOUT_VALUE per reward actually paid).
const WALLET_CLAIM_GAS = ton("0.05")

fun RewardWalletStorage.assertIdle(self) {
    assert (self.pending == null) throw Errors.SettleInFlight;
}

/// Snapshot of the position when a Settle leaves, so that a claim can be reconciled exactly
/// even if tokens arrive while the answer is in flight.
fun RewardWalletStorage.openPending(mutate self, action: uint8, amount: coins, transfer: Cell<PendingTransfer>?) {
    self.pending = PendingOp {
        action,
        amount,
        balanceAtSend: self.balance,
        transfer,
        stampsAtSend: self.stamps,
        accruedAtSend: self.accrued,
    }.toCell();
}

fun RewardWalletStorage.sendSettle(self, queryId: uint64, action: uint8, burnAmount: coins, sellMinTon: coins?) {
    val settle = createMessage({
        bounce: BounceMode.Only256BitsOfBody,
        dest: self.master,
        value: 0,
        body: Settle {
            queryId,
            owner: self.owner,
            balance: self.balance,
            action,
            burnAmount,
            sellMinTon,
            stamps: self.stamps,
            accrued: self.accrued,
        },
    });
    settle.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

/// Removes from `accrued` what the master just paid: accruedAtSend + balanceAtSend * (index - stampAtSend).
fun RewardWalletStorage.settleClaim(mutate self, op: PendingOp, indices: map<uint8, uint128>) {
    var r = indices.findFirst();
    while (r.isFound) {
        val id = r.getKey();
        val index = r.loadValue() as int;
        val paid = owedFor(op.balanceAtSend, index, indexOf(op.stampsAtSend, id), amountOf(op.accruedAtSend, id));
        val now = amountOf(self.accrued, id);
        // tokens received meanwhile were frozen locally and are not part of `paid`
        val rest = now > paid ? now - paid : 0;
        if (rest > 0) {
            self.accrued.set(id, rest as coins);
        } else {
            self.accrued.delete(id);
        }
        r = indices.iterateNext(r);
    }
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy RewardWalletStorage.load();
    val msg = lazy AllowedMessageToRewardWallet.fromSlice(in.body);

    match (msg) {
        AskToTransfer => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.assertIdle();
            msg.forwardPayload.checkIsCorrectTlbEither();
            assert (msg.transferRecipient.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            assert (in.valueCoins >= msg.forwardTonAmount + WALLET_TRANSFER_GAS) throw Errors.InsufficientValue;
            assert (msg.jettonAmount > 0 && storage.balance >= msg.jettonAmount) throw Errors.BudgetExceeded;
            val transfer = PendingTransfer {
                queryId: msg.queryId,
                amount: msg.jettonAmount,
                recipient: msg.transferRecipient,
                sendExcessesTo: msg.sendExcessesTo,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: beginCell().storeSlice(msg.forwardPayload).endCell(),
            }.toCell();
            storage.openPending(ACTION_SYNC, msg.jettonAmount, transfer);
            storage.save();
            storage.sendSettle(msg.queryId, ACTION_SYNC, 0, null);
        }

        AskToBurn => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.assertIdle();
            assert (in.valueCoins >= WALLET_BURN_GAS) throw Errors.InsufficientValue;
            assert (msg.jettonAmount > 0 && storage.balance >= msg.jettonAmount) throw Errors.BudgetExceeded;
            var sellMinTon: coins? = null;
            if (msg.customPayload != null) {
                val intent = SellIntent.fromCell(msg.customPayload);
                sellMinTon = intent.minTon;
            }
            storage.openPending(ACTION_BURN, msg.jettonAmount, null);
            storage.save();
            storage.sendSettle(msg.queryId, ACTION_BURN, msg.jettonAmount, sellMinTon);
        }

        ClaimRewards => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            storage.assertIdle();
            assert (in.valueCoins >= WALLET_CLAIM_GAS) throw Errors.InsufficientValue;
            storage.openPending(ACTION_CLAIM, 0, null);
            storage.save();
            storage.sendSettle(msg.queryId, ACTION_CLAIM, 0, null);
        }

        SettleAck => {
            assert (in.senderAddress == storage.master) throw Errors.NotFromMaster;
            assert (storage.pending != null) throw Errors.NothingPending;
            val op = storage.pending.load();
            // every token still here earned until the master's current index
            storage.freezeAt(msg.indices);
            if (msg.claimed) {
                storage.settleClaim(op, msg.indices);
            }
            storage.pending = null;

            if (op.action == ACTION_SYNC) {
                val t = op.transfer!.load();
                storage.balance -= t.amount;
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
                step.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                return;
            }
            if (op.action == ACTION_BURN) {
                storage.balance -= op.amount;
            }
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
                assert (in.senderAddress == calcRewardWalletAddress(initiator, storage.master, contract.getCode())) throw Errors.NotFromRewardWallet;
            }
            // freeze our position, then merge the lot with the position it was frozen at by the sender
            storage.receiveLot(msg.jettonAmount, msg.indices);
            storage.save();

            if (msg.forwardTonAmount != 0) {
                val notify = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: storage.owner,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForRecipient {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        transferInitiator: msg.transferInitiator,
                        forwardPayload: msg.forwardPayload,
                    },
                });
                notify.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }
            if (msg.sendExcessesTo != null) {
                val keep = max(contract.getOriginalBalance() - in.valueCoins, MIN_STORAGE_RESERVE);
                reserveToncoinsOnBalance(keep, RESERVE_MODE_AT_MOST);
                val excesses = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.sendExcessesTo,
                    value: 0,
                    body: ReturnExcessesBack { queryId: msg.queryId },
                });
                excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            }
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

fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy RewardWalletStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op == 0x52570001) {
        // Settle refused by the master (e.g. sell while the curve is closed): nothing moved.
        storage.pending = null;
        storage.save();
        return;
    }
    if (op == 0x52570003) {
        // RewardTransferStep bounced: the recipient wallet refused, tokens come back.
        in.bouncedBody.skipBits(64);
        val amount = in.bouncedBody.loadCoins();
        storage.balance += amount;
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
        busy: storage.pending != null,
    };
}

/// Rewards claimable at `indices` (as returned by the master's get_reward_master_data).
get fun get_claimable(indices: map<uint8, uint128>): map<uint8, coins> {
    val storage = lazy RewardWalletStorage.load();
    var out: map<uint8, coins> = createEmptyMap();
    var r = indices.findFirst();
    while (r.isFound) {
        val id = r.getKey();
        val owed = owedFor(storage.balance, r.loadValue() as int, indexOf(storage.stamps, id), amountOf(storage.accrued, id));
        if (owed > 0) {
            out.set(id, owed as coins);
        }
        r = indices.iterateNext(r);
    }
    return out;
}
