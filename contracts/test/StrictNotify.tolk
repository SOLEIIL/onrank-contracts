/// Parses opcode 0x7362d09c the way a standard TEP-74 receiver does:
/// query_id, amount, sender as MsgAddress (not an optional address), then the payload.
contract StrictNotify {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Test sink that only accepts a standard TEP-74 transfer notification."
    storage: StrictNotifyStorage
}

struct StrictNotifyStorage {
    hits: uint32
    amount: coins
}

fun StrictNotifyStorage.load(): StrictNotifyStorage {
    return StrictNotifyStorage.fromCell(contract.getData());
}

fun StrictNotifyStorage.save(self) {
    contract.setData(self.toCell());
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    var body = in.body;
    val op = body.loadUint(32);
    assert (op == 0x7362d09c) throw 101;
    body.loadUint(64);
    val amount = body.loadCoins();
    // standard jetton: sender is MsgAddress, not Maybe Address
    body.loadAddress();
    var storage = lazy StrictNotifyStorage.load();
    storage.hits += 1;
    storage.amount = amount;
    storage.save();
}

get fun get_strict_notify(): (uint32, coins) {
    val storage = lazy StrictNotifyStorage.load();
    return (storage.hits, storage.amount);
}
