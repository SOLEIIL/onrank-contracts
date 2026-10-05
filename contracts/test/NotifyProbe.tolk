import "../vendor/jetton/messages"

/// Accepts the notification layout this repo already sends (`TransferNotificationForRecipient`).
contract NotifyProbe {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Test sink for the jetton notification this codebase emits."
    storage: NotifyProbeStorage
    incomingMessages: AllowedMessageToNotifyProbe
}

struct NotifyProbeStorage {
    hits: uint32
    amount: coins
}

fun NotifyProbeStorage.load(): NotifyProbeStorage {
    return NotifyProbeStorage.fromCell(contract.getData());
}

fun NotifyProbeStorage.save(self) {
    contract.setData(self.toCell());
}

type AllowedMessageToNotifyProbe =
    | TransferNotificationForRecipient
    | TopUpTons

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    var storage = lazy NotifyProbeStorage.load();
    val msg = lazy AllowedMessageToNotifyProbe.fromSlice(in.body);
    match (msg) {
        TransferNotificationForRecipient => {
            storage.hits += 1;
            storage.amount = msg.jettonAmount;
            storage.save();
        }
        TopUpTons => {
            // gas
        }
    }
}

get fun get_notify_probe(): (uint32, coins) {
    val storage = lazy NotifyProbeStorage.load();
    return (storage.hits, storage.amount);
}
