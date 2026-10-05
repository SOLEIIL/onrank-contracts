// Test sink. Records whatever message arrives so the DeDust payout body is observed, not guessed.

struct FeeSinkStorage {
    hits: uint32
    opcode: uint32
    value: coins
    body: cell?
}

fun FeeSinkStorage.load(): FeeSinkStorage {
    return FeeSinkStorage.fromCell(contract.getData());
}

fun FeeSinkStorage.save(self) {
    contract.setData(self.toCell());
}

contract FeeSink {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Records one incoming internal message. Test only. Not deployed."
    storage: FeeSinkStorage
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy FeeSinkStorage.load();
    storage.hits += 1;
    storage.value = in.valueCoins;
    if (in.body.isEmpty()) {
        storage.opcode = 0;
        storage.body = null;
    } else {
        storage.opcode = in.body.preloadUint(32) as uint32;
        storage.body = beginCell().storeSlice(in.body).endCell();
    }
    storage.save();
}

get fun get_fee_sink(): FeeSinkStorage {
    return FeeSinkStorage.load();
}
