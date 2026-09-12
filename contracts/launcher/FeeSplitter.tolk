import "../common/consts"
import "../common/errors"
import "../pot/pot-messages"
import "fee-splitter-messages"
import "fee-splitter-types"

contract FeeSplitter {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Immutable 4-way split of a launched coin's TON fees: holders (RewardVault), protocol, Pot, buyback. Holders share stays locked until the reward is activated."
    storage: FeeSplitterStorage
    incomingMessages: AllowedMessageToSplitter
}

type AllowedMessageToSplitter =
    | FeeIn
    | Distribute
    | SetSplitterVault
    | ChangeSplitterAdmin

/// Gas kept from an incoming FeeIn so that the 4 outgoing messages can be paid.
const SPLIT_GAS = ton("0.03")
const POT_TOPUP_SOURCE_LAUNCHER = 2

fun emitSplit(body: FeeSplitEvent) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: EVENT_TOPIC_FEE_SPLIT as uint248 },
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

/// Splits `storage.accrued` (and `locked` when the reward just became active).
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
    sendTonWith(r.pot, pot, PotTopUp { queryId, source: POT_TOPUP_SOURCE_LAUNCHER });
    sendTonWith(r.buyback, buyback, BuybackIn { queryId });
    sendTon(r.protocol, protocol);
    emitSplit({ amount, holders, protocol, pot, buyback, lockedHolders: !canPayHolders });
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
            // one-shot: once the holders share flows to a vault, nobody (admin included) can redirect it (F-03)
            assert (!storage.active) throw Errors.AlreadyWired;
            var reward = storage.reward.load();
            reward.vault = msg.vault;
            storage.reward = reward.toCell();
            storage.active = msg.active;
            if (msg.active && storage.locked > 0) {
                assert (in.valueCoins >= SPLIT_GAS) throw Errors.InsufficientValue;
                val release = storage.locked;
                storage.locked = 0;
                sendTonWith(msg.vault, release, RewardIn { queryId: msg.queryId });
            }
            storage.save();
        }

        else => {
            // plain TON / TopUpTons (deploy, gas top-up): kept as reserve, never split. Unknown opcodes bounce.
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0 || in.body.preloadUint(32) == 0xd372158c) throw 0xFFFF;
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
        routes: storage.routes.load(),
        reward: storage.reward.load(),
    };
}
