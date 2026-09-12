import "@contracts/common/errors"
import "@contracts/pot/pot-messages"
import "fee-splitter-messages"
import "fee-splitter-types"
import "reward-types"

contract FeeSplitterV2 {
    author: "GRAMDESKS"
    version: "2.0.0"
    description: "4-way split of a launched coin's TON fees: holders (RewardVault), protocol, Pot, buyback. Splits change through a 48 h timelock with a protocol floor; the holders share stays locked until the reward is activated."
    storage: FeeSplitterStorage
    incomingMessages: AllowedMessageToSplitter
}

type AllowedMessageToSplitter =
    | FeeIn
    | Distribute
    | SetSplitterVault
    | SetSplitterActive
    | ProposeSplits
    | ApplySplits
    | ChangeSplitterAdmin

/// Gas kept from an incoming FeeIn so that the 4 outgoing messages can be paid.
const SPLIT_GAS = ton("0.03")
const POT_TOPUP_SOURCE_LAUNCHER = 2

fun emitSplitterEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun sendTon(dest: address, value: coins) {
    if (value == 0) {
        return;
    }
    val m = createMessage({ bounce: BounceMode.NoBounce, dest, value });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun sendTonWith<T>(dest: address, value: coins, body: T) {
    if (value == 0) {
        return;
    }
    val m = createMessage({ bounce: BounceMode.NoBounce, dest, value, body });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

/// Splits `storage.accrued`.
fun FeeSplitterStorage.distribute(mutate self, queryId: uint64) {
    val amount = self.accrued;
    if (amount == 0) {
        return;
    }
    val r = self.routes.load();
    val rw = self.reward.load();
    val s = rw.splits;
    val holders = (amount * s.holdersBps) / 10000;
    val pot = (amount * s.potBps) / 10000;
    val buyback = (amount * s.buybackBps) / 10000;
    val protocol = amount - holders - pot - buyback;
    self.accrued = 0;

    val canPayHolders = self.active && rw.vault != null;
    if (canPayHolders) {
        sendTonWith(rw.vault!, holders, RewardIn { queryId });
    } else {
        self.locked += holders;
    }
    sendTonWith(
        r.pot,
        pot,
        PotTopUp {
            queryId,
            source: POT_TOPUP_SOURCE_LAUNCHER,
        },
    );
    sendTonWith(r.buyback, buyback, BuybackIn { queryId });
    sendTon(r.protocol, protocol);
    emitSplitterEvent(
        EVENT_TOPIC_FEE_SPLIT,
        FeeSplitEvent {
            amount,
            holders,
            protocol,
            pot,
            buyback,
            lockedHolders: !canPayHolders,
        },
    );
}

/// Turns the holders share on: `locked` leaves for the vault (the caller pays the gas).
fun FeeSplitterStorage.activate(mutate self, inValue: coins, queryId: uint64) {
    val rw = self.reward.load();
    assert (rw.vault != null) throw Errors.NotWired;
    self.active = true;
    if (self.locked > 0) {
        assert (inValue >= SPLIT_GAS) throw Errors.InsufficientValue;
        val release = self.locked;
        self.locked = 0;
        sendTonWith(rw.vault!, release, RewardIn { queryId });
    }
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy FeeSplitterStorage.load();
    val msg = lazy AllowedMessageToSplitter.fromSlice(in.body);

    match (msg) {
        FeeIn => {
            assert (msg.amount + SPLIT_GAS <= in.valueCoins) throw Errors.InsufficientValue;
            storage.accrued += msg.amount;
            storage.totalIn += msg.amount;
            if (storage.accrued >= storage.minSplit) {
                storage.distribute(msg.queryId);
            }
            storage.save();
        }

        Distribute => {
            assert (in.valueCoins >= SPLIT_GAS) throw Errors.InsufficientValue;
            assert (storage.accrued >= storage.minSplit) throw Errors.BelowThreshold;
            storage.distribute(msg.queryId);
            storage.save();
        }

        ChangeSplitterAdmin => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            storage.admin = msg.newAdmin;
            storage.save();
        }

        SetSplitterVault => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            var reward = storage.reward.load();
            // one-shot: once a vault is set, nobody (admin included) can redirect the holders share
            assert (reward.vault == null) throw Errors.AlreadyWired;
            reward.vault = msg.vault;
            storage.reward = reward.toCell();
            if (msg.active) {
                storage.activate(in.valueCoins, msg.queryId);
            }
            storage.save();
        }

        SetSplitterActive => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            if (msg.active) {
                storage.activate(in.valueCoins, msg.queryId);
            } else {
                storage.active = false;
            }
            storage.save();
        }

        ProposeSplits => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            assert (msg.splits.isValid(storage.minProtocolBps)) throw Errors.InvalidSplits;
            val readyAt = (blockchain.now() + SPLITS_DELAY) as uint32;
            storage.proposal = SplitsProposal {
                splits: msg.splits,
                readyAt,
            }.toCell();
            storage.save();
            emitSplitterEvent(
                EVENT_TOPIC_SPLITS_CHANGED,
                SplitsChangedEvent {
                    splits: msg.splits,
                    applied: false,
                    readyAt,
                },
            );
        }

        ApplySplits => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            assert (storage.proposal != null) throw Errors.NothingPending;
            val proposal = storage.proposal.load();
            assert (blockchain.now() >= proposal.readyAt) throw Errors.PendingNotExpired;
            var reward = storage.reward.load();
            reward.splits = proposal.splits;
            storage.reward = reward.toCell();
            storage.proposal = null;
            storage.save();
            emitSplitterEvent(
                EVENT_TOPIC_SPLITS_CHANGED,
                SplitsChangedEvent {
                    splits: proposal.splits,
                    applied: true,
                    readyAt: proposal.readyAt,
                },
            );
        }

        else => {
            // plain TON / TopUpTons (deploy, gas top-up): kept as reserve, never split. Unknown opcodes bounce.
            assert (
                in.body.isEmpty() || in.body.preloadUint(32) == 0 ||
                in.body.preloadUint(32) == 0xd372158c
            ) throw 0xFFFF;
        }
    }
}

get fun get_splitter_data(): FeeSplitterDataReply {
    val storage = lazy FeeSplitterStorage.load();
    return {
        admin: storage.admin,
        active: storage.active,
        locked: storage.locked,
        accrued: storage.accrued,
        totalIn: storage.totalIn,
        minSplit: storage.minSplit,
        minProtocolBps: storage.minProtocolBps,
        routes: storage.routes.load(),
        reward: storage.reward.load(),
        proposal: storage.proposal != null ? storage.proposal.load() : null,
    };
}

get fun get_code_version(): int {
    return LAUNCHER_CODE_VERSION;
}
