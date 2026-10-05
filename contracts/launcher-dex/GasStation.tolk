import "gas-station-types"
import "../common/errors"
import "../vendor/jetton/messages"

// Holds the protocol leg of future coins. Pays the keeper and the creator contracts from that float.
// Already-launched coins do not send here. Not deployed.

contract GasStation {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Capped protocol float for future coins. Overflow returns to the Ledger. Offline until a future factory is deployed."
    storage: GasStationStorage
}

fun GasStationStorage.load(): GasStationStorage {
    return GasStationStorage.fromCell(contract.getData());
}

fun GasStationStorage.save(self) {
    contract.setData(self.toCell());
}

fun sweep(ledger: address, floatMax: coins) {
    val full = contract.getOriginalBalance();
    if (full <= floatMax) {
        return;
    }
    val extra = full - floatMax;
    val out = createMessage({
        bounce: BounceMode.NoBounce,
        dest: ledger,
        value: extra,
        body: TopUpTons {},
    });
    out.send(SEND_MODE_REGULAR);
}

fun spendable(inbound: coins, floatMax: coins): coins {
    val full = contract.getOriginalBalance();
    val capped = full > floatMax ? floatMax : full;
    if (capped <= inbound) {
        return ton("0");
    }
    return capped - inbound;
}

fun pay(dest: address, amount: coins) {
    val out = createMessage({
        bounce: BounceMode.NoBounce,
        dest: dest,
        value: amount,
        body: TopUpTons {},
    });
    out.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        var storage = lazy GasStationStorage.load();
        sweep(storage.roles.load().ledger, storage.params.load().floatMax);
        return;
    }
    val opcode = in.body.preloadUint(32);
    if (opcode == OP_PULL_GAS) {
        val msg = PullGas.fromSlice(in.body);
        var storage = lazy GasStationStorage.load();
        val roles = storage.roles.load();
        val params = storage.params.load();
        assert (in.senderAddress == roles.keeper) throw Errors.NotFromKeeper;
        assert (!storage.paused) throw Errors.FactoryPaused;
        sweep(roles.ledger, params.floatMax);
        val now = blockchain.now();
        assert (now >= storage.lastPullAt + GAS_DAY) throw Errors.PendingNotExpired;
        val held = spendable(in.valueCoins, params.floatMax);
        val room: coins = held > GAS_RESERVE ? held - GAS_RESERVE : ton("0");
        val amount = room < params.pullAmount ? room : params.pullAmount;
        // Bounce rather than keep the keeper's attached gas. The 24 h lock starts only when a payment actually leaves.
        if (amount < GAS_MIN_SEND) {
            throw Errors.BelowThreshold;
        }
        storage.lastPullAt = now as uint32;
        storage.save();
        pay(roles.keeper, amount);
        return;
    }
    if (opcode == OP_REFILL_CREATOR) {
        val msg = RefillCreator.fromSlice(in.body);
        var storage = lazy GasStationStorage.load();
        val roles = storage.roles.load();
        val params = storage.params.load();
        assert (in.senderAddress == roles.keeper) throw Errors.NotFromKeeper;
        assert (!storage.paused) throw Errors.FactoryPaused;
        val found = storage.creators.get(msg.creator);
        assert (found.isFound) throw Errors.DestNotWhitelisted;
        val last = found.loadValue();
        val now = blockchain.now();
        assert (now >= last + GAS_DAY) throw Errors.PendingNotExpired;
        sweep(roles.ledger, params.floatMax);
        val held = spendable(in.valueCoins, params.floatMax);
        assert (held >= GAS_RESERVE + GAS_REFILL) throw Errors.BelowThreshold;
        storage.creators.set(msg.creator, now as uint32);
        storage.save();
        pay(msg.creator, GAS_REFILL);
        return;
    }
    if (opcode == OP_REGISTER_CREATOR) {
        val msg = RegisterCreator.fromSlice(in.body);
        var storage = lazy GasStationStorage.load();
        val factory = storage.params.load().factory;
        assert (factory != null && in.senderAddress == factory!) throw Errors.NotFromFactory;
        storage.creators.set(msg.creator, 0);
        storage.save();
        return;
    }
    val msg32 = in.body.preloadUint(32);
    if (
        msg32 == OP_SET_GAS_PAUSED || msg32 == OP_SET_GAS_KEEPER || msg32 == OP_SET_GAS_FACTORY ||
        msg32 == OP_PROPOSE_GAS_CAPS ||
        msg32 == OP_APPLY_GAS_CAPS ||
        msg32 == OP_LOWER_GAS_FLOAT ||
        msg32 == OP_LOWER_GAS_PULL
    ) {
        var storage = lazy GasStationStorage.load();
        val roles = storage.roles.load();
        assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
        if (msg32 == OP_SET_GAS_PAUSED) {
            val body = SetGasPaused.fromSlice(in.body);
            storage.paused = body.paused;
            storage.save();
            return;
        }
        if (msg32 == OP_SET_GAS_KEEPER) {
            val body = SetGasKeeper.fromSlice(in.body);
            storage.roles = GasStationRoles {
                ledger: roles.ledger,
                keeper: body.keeper,
                admin: roles.admin,
            }.toCell();
            storage.save();
            return;
        }
        if (msg32 == OP_SET_GAS_FACTORY) {
            val body = SetGasFactory.fromSlice(in.body);
            val params = storage.params.load();
            assert (params.factory == null) throw Errors.AlreadyWired;
            storage.params = GasStationParams {
                floatMax: params.floatMax,
                pullAmount: params.pullAmount,
                factory: body.factory,
            }.toCell();
            storage.save();
            return;
        }
        if (msg32 == OP_PROPOSE_GAS_CAPS) {
            val body = ProposeGasCaps.fromSlice(in.body);
            val params = storage.params.load();
            assert (
                body.floatMax >= params.floatMax && body.pullAmount >= params.pullAmount
            ) throw Errors.InvalidParams;
            assert (
                body.floatMax > params.floatMax || body.pullAmount > params.pullAmount
            ) throw Errors.InvalidParams;
            storage.proposal = GasRaise {
                floatMax: body.floatMax,
                pullAmount: body.pullAmount,
                readyAt: (blockchain.now() + GAS_DELAY) as uint32,
            }.toCell();
            storage.save();
            return;
        }
        if (msg32 == OP_APPLY_GAS_CAPS) {
            assert (storage.proposal != null) throw Errors.NothingPending;
            val raise = storage.proposal!.load();
            assert (blockchain.now() >= raise.readyAt) throw Errors.PendingNotExpired;
            val params = storage.params.load();
            storage.params = GasStationParams {
                floatMax: raise.floatMax,
                pullAmount: raise.pullAmount,
                factory: params.factory,
            }.toCell();
            storage.proposal = null;
            storage.save();
            return;
        }
        if (msg32 == OP_LOWER_GAS_FLOAT) {
            val body = LowerGasFloat.fromSlice(in.body);
            val params = storage.params.load();
            assert (body.floatMax < params.floatMax) throw Errors.InvalidParams;
            storage.params = GasStationParams {
                floatMax: body.floatMax,
                pullAmount: params.pullAmount,
                factory: params.factory,
            }.toCell();
            storage.save();
            sweep(roles.ledger, body.floatMax);
            return;
        }
        val body = LowerGasPull.fromSlice(in.body);
        val params = storage.params.load();
        assert (body.pullAmount < params.pullAmount) throw Errors.InvalidParams;
        storage.params = GasStationParams {
            floatMax: params.floatMax,
            pullAmount: body.pullAmount,
            factory: params.factory,
        }.toCell();
        storage.save();
        return;
    }
    var storage = lazy GasStationStorage.load();
    if (opcode == 0xd372158c) {
        sweep(storage.roles.load().ledger, storage.params.load().floatMax);
        return;
    }
    throw 0xFFFF;
}

get fun get_gas_station_data(): GasStationData {
    var storage = lazy GasStationStorage.load();
    val roles = storage.roles.load();
    val params = storage.params.load();
    return {
        ledger: roles.ledger,
        keeper: roles.keeper,
        admin: roles.admin,
        factory: params.factory,
        floatMax: params.floatMax,
        pullAmount: params.pullAmount,
        paused: storage.paused,
        lastPullAt: storage.lastPullAt,
    };
}

get fun get_creator_refill(creator: address): uint32? {
    var storage = lazy GasStationStorage.load();
    val found = storage.creators.get(creator);
    if (!found.isFound) {
        return null;
    }
    return found.loadValue();
}
