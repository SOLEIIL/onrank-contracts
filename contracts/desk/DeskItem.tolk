import "@stdlib/reflection"
import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/common/tep-nft"
import "@contracts/vendor/jetton/messages"
import "desk-messages"
import "desk-types"

contract DeskItem {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Desk NFT (TEP-62) acting as a vault: owns its jetton wallets, sweeps owed stock from the Pot, withdraws only when nothing is owed."
    storage: DeskItemStorage
    storageAtDeployment: DeskItemStorageNotInitialized
    incomingMessages: AllowedMessageToDeskItem
}

type AllowedMessageToDeskItem =
    | AskToChangeOwnership
    | RequestStaticData
    | StampsInit
    | Sweep
    | SweepAck
    | Withdraw
    | WithdrawOk
    | TransferNotificationForRecipient
    | ReturnExcessesBack

fun popcount64(mask: int): int {
    var m = mask;
    var n = 0;
    while (m != 0) {
        n += m & 1;
        m >>= 1;
    }
    return n;
}

/// Keeps the balance the desk had before this message (at least the storage reserve) and
/// returns everything else to `to`.
fun returnExcessesTo(to: address, queryId: uint64, incomingValue: coins) {
    val keep = max(contract.getOriginalBalance() - incomingValue, MIN_STORAGE_RESERVE);
    reserveToncoinsOnBalance(keep, RESERVE_MODE_AT_MOST);
    val excessesMsg = createMessage({
        bounce: BounceMode.NoBounce,
        dest: to,
        value: 0,
        body: ReturnExcessesBack { queryId },
    });
    excessesMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    var loading = DeskItemStorage.startLoading();
    if (loading.isNotInitialized()) {
        assert (in.senderAddress == loading.collection) throw Errors.NotFromCollection;
        val init = DeskItemInit.fromSlice(in.body);
        val storage: DeskItemStorage = {
            serial: loading.serial,
            collection: loading.collection,
            owner: init.owner,
            pot: init.pot,
            stampsReady: false,
            stamps: createEmptyMap(),
            pending: createEmptyMap(),
        };
        storage.save();
        return;
    }

    var storage = loading.endLoading();
    val msg = lazy AllowedMessageToDeskItem.fromSlice(in.body);

    match (msg) {
        StampsInit => {
            assert (in.senderAddress == storage.pot) throw Errors.NotFromPot;
            assert (!storage.stampsReady) throw Errors.AlreadyInitialized;
            storage.stamps = msg.stamps;
            storage.stampsReady = true;
            storage.save();
        }

        Sweep => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            assert (storage.stampsReady) throw Errors.StampsNotReady;
            val n = popcount64(msg.slotsMask);
            assert (n > 0) throw Errors.NoSlotsSelected;
            assert (in.valueCoins >= n * SWEEP_REQUEST_VALUE + ton("0.02")) throw Errors.InsufficientValue;

            var mask = msg.slotsMask;
            var slot = 0;
            while (mask != 0) {
                if ((mask & 1) == 1) {
                    assert (!storage.pending.exists(slot as uint8)) throw Errors.SlotBusy;
                    val found = storage.stamps.get(slot as uint8);
                    val stamp: uint128 = found.isFound ? found.loadValue() : (0 as uint128);
                    storage.pending.set(slot as uint8, stamp);
                    val req = createMessage({
                        bounce: BounceMode.Only256BitsOfBody,
                        dest: storage.pot,
                        value: SWEEP_REQUEST_VALUE,
                        body: SweepRequest {
                            queryId: msg.queryId,
                            serial: storage.serial,
                            slot: slot as uint8,
                            stamp,
                        },
                    });
                    req.send(SEND_MODE_PAY_FEES_SEPARATELY);
                }
                mask >>= 1;
                slot += 1;
            }
            storage.save();
            returnExcessesTo(storage.owner, msg.queryId, in.valueCoins);
        }

        SweepAck => {
            assert (in.senderAddress == storage.pot) throw Errors.NotFromPot;
            val current = storage.stamps.get(msg.slot);
            val currentStamp: uint128 = current.isFound ? current.loadValue() : (0 as uint128);
            if (msg.newStamp > currentStamp) {
                storage.stamps.set(msg.slot, msg.newStamp);
            }
            storage.pending.delete(msg.slot);
            storage.save();
            returnExcessesTo(storage.owner, msg.queryId, in.valueCoins);
        }

        Withdraw => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            assert (storage.stampsReady) throw Errors.StampsNotReady;
            assert (!storage.pending.exists(msg.slot)) throw Errors.SlotBusy;
            assert (msg.to.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            assert (in.valueCoins >= WITHDRAW_REQUEST_VALUE + POT_JETTON_TRANSFER_VALUE) throw Errors.InsufficientValue;
            val found = storage.stamps.get(msg.slot);
            val stamp: uint128 = found.isFound ? found.loadValue() : (0 as uint128);
            storage.pending.set(msg.slot, stamp);
            storage.save();
            val req = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: storage.pot,
                value: 0,
                body: WithdrawViaPot {
                    queryId: msg.queryId,
                    serial: storage.serial,
                    slot: msg.slot,
                    stamp,
                    jettonWallet: msg.jettonWallet,
                    amount: msg.amount,
                    to: msg.to,
                },
            });
            req.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        WithdrawOk => {
            assert (in.senderAddress == storage.pot) throw Errors.NotFromPot;
            storage.pending.delete(msg.slot);
            storage.save();
            val transfer = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: msg.jettonWallet,
                value: 0,
                body: AskToTransfer {
                    queryId: msg.queryId,
                    jettonAmount: msg.amount,
                    transferRecipient: msg.to,
                    sendExcessesTo: storage.owner,
                    customPayload: null,
                    forwardTonAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            transfer.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        AskToChangeOwnership => {
            assert (in.senderAddress == storage.owner) throw Errors.NotFromOwner;
            val (fwdBits, fwdRefs) = msg.forwardPayload.remainingBitsAndRefsCount();
            assert (fwdBits != 0) throw Errors.IncorrectForwardPayload;
            if (msg.forwardPayload.preloadUint(1) != 0) {
                assert (fwdBits == 1 && fwdRefs == 1) throw Errors.IncorrectForwardPayload;
            }
            assert (msg.newOwnerAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;

            val fwdFee = in.originalForwardFee;
            var restAmount = in.valueCoins;
            if (msg.forwardTonAmount != 0) {
                restAmount -= (msg.forwardTonAmount + fwdFee);
            }
            if (msg.sendExcessesTo != null) {
                assert (msg.sendExcessesTo.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
                restAmount -= fwdFee;
            }
            assert (restAmount >= 0) throw Errors.InsufficientValue;

            if (msg.forwardTonAmount != 0) {
                val ownershipMsg = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: msg.newOwnerAddress,
                    value: msg.forwardTonAmount,
                    body: NotificationForNewOwner {
                        queryId: msg.queryId,
                        oldOwnerAddress: storage.owner,
                        payload: msg.forwardPayload,
                    },
                });
                ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            storage.owner = msg.newOwnerAddress;
            storage.save();
            if (msg.sendExcessesTo != null) {
                returnExcessesTo(msg.sendExcessesTo, msg.queryId, in.valueCoins);
            }
        }

        RequestStaticData => {
            val respondMsg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: UnsafeBodyNoRef {
                    forceInline: ResponseStaticData {
                        queryId: msg.queryId,
                        itemIndex: storage.serial as uint256,
                        collectionAddress: storage.collection,
                    },
                },
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        TransferNotificationForRecipient => {
            // stock arriving in one of the desk's jetton wallets: nothing to do, keep the TON
        }

        ReturnExcessesBack => {
            // excesses from our own jetton transfers: keep
        }

        else => {
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var loading = DeskItemStorage.startLoading();
    if (loading.isNotInitialized()) {
        return;
    }
    var storage = loading.endLoading();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    val queryId = in.bouncedBody.loadUint(64);
    if (op == reflect.serializationPrefixOf<SweepRequest>().0 || op == reflect.serializationPrefixOf<WithdrawViaPot>().0) {
        in.bouncedBody.skipBits(32); // serial
        val slot = in.bouncedBody.loadUint(8);
        storage.pending.delete(slot as uint8);
        storage.save();
    }
    // AskToTransfer bounced (wrong jetton wallet) or Pot refused: give the TON back to the owner.
    returnExcessesTo(storage.owner, queryId, in.valueCoins);
}

get fun get_nft_data(): NftDataReply {
    var loading = DeskItemStorage.startLoading();
    if (loading.isNotInitialized()) {
        return {
            isInitialized: false,
            itemIndex: loading.serial,
            collectionAddress: loading.collection,
        };
    }
    val storage = loading.endLoading();
    return {
        isInitialized: true,
        itemIndex: storage.serial,
        collectionAddress: storage.collection,
        ownerAddress: storage.owner,
        content: "",
    };
}

get fun get_desk_data(): DeskDataReply {
    var loading = DeskItemStorage.startLoading();
    val storage = loading.endLoading();
    return {
        serial: storage.serial,
        owner: storage.owner,
        pot: storage.pot,
        stampsReady: storage.stampsReady,
        stamps: storage.stamps,
        pending: storage.pending,
    };
}
