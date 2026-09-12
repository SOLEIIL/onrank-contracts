import "@contracts/common/consts"
import "@contracts/common/dedust"
import "@contracts/common/errors"
import "@contracts/vendor/jetton/messages"

/// TEST ONLY (testnet rehearsals — DeDust has no testnet deployment). One contract plays both the DeDust native
/// vault and a TON/jetton pool: it answers `estimate_swap_out` like a pool and executes `DedustNativeSwap` like the
/// vault, paying `amount × rate / 1e9` jettons to the recipient from its own jetton wallet, or refunding the whole
/// value with a `DedustPayout` when the limit / deadline is not met (or when the admin armed `refuseNext`).
contract MockDex {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Test-only DeDust look-alike: quotes and swaps TON for one jetton at a fixed rate."
    storage: MockDexStorage
    incomingMessages: AllowedMessageToMockDex
}

struct MockDexStorage {
    admin: address
    jettonMaster: address
    jettonWallet: address?
    /// Jetton units paid per 1 TON (1e9 nanoTON).
    rate: coins
    refuseNext: bool
    swaps: uint32
}

fun MockDexStorage.load(): MockDexStorage {
    return MockDexStorage.fromCell(contract.getData());
}

fun MockDexStorage.save(self) {
    contract.setData(self.toCell());
}

struct (0x4d440001) SetMockDex {
    queryId: uint64
    jettonWallet: address?
    rate: coins
    refuseNext: bool
}

type AllowedMessageToMockDex =
    | DedustNativeSwap
    | SetMockDex
    | TransferNotificationForRecipient
    | ReturnExcessesBack
    | TopUpTons

/// Value forwarded with the jetton transfer (wallet compute + notification to the recipient).
const PAYOUT_TRANSFER_VALUE = ton("0.1")

fun onInternalMessage(in: InMessage) {
    var storage = lazy MockDexStorage.load();
    val msg = lazy AllowedMessageToMockDex.fromSlice(in.body);

    match (msg) {
        DedustNativeSwap => {
            val params = msg.params.load();
            val out = (msg.amount * storage.rate) / 1000000000;
            val refuse = storage.refuseNext || out < msg.limit || params.deadline <
            blockchain.now() ||
            storage.jettonWallet == null;
            storage.refuseNext = false;
            if (!refuse) {
                storage.swaps += 1;
            }
            storage.save();
            if (refuse) {
                // DeDust refunds the whole value (swap amount + gas) with a payout carrying the query id
                val back = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: in.senderAddress,
                    value: 0,
                    body: DedustPayout {
                        queryId: msg.queryId,
                        payload: null,
                    },
                });
                back.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }
            // keep the swapped TON here (a real vault keeps it as liquidity); pay the jettons, return the gas
            reserveToncoinsOnBalance(
                contract.getOriginalBalance() - in.valueCoins + msg.amount,
                RESERVE_MODE_EXACT_AMOUNT,
            );
            val pay = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.jettonWallet!,
                value: PAYOUT_TRANSFER_VALUE,
                body: AskToTransfer {
                    queryId: msg.queryId,
                    jettonAmount: out,
                    transferRecipient: params.recipient,
                    sendExcessesTo: params.recipient,
                    customPayload: null,
                    forwardTonAmount: ton("0.05"),
                    forwardPayload: emptyForwardPayload(),
                },
            });
            pay.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val leftover = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: DedustPayout {
                    queryId: msg.queryId,
                    payload: null,
                },
            });
            // SAFETY: test contract; last action after an exact reserve, carries the leftover gas only
            leftover.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        SetMockDex => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            storage.jettonWallet = msg.jettonWallet;
            storage.rate = msg.rate;
            storage.refuseNext = msg.refuseNext;
            storage.save();
        }

        TransferNotificationForRecipient => {
            // jetton inventory arriving (funding): nothing to do, the balance lives in our jetton wallet
        }

        ReturnExcessesBack => {
            // gas back from our transfers
        }

        TopUpTons => {
            // accept
        }

        else => {
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0) throw 0xFFFF;
        }
    }
}

struct MockEstimate {
    asset: slice
    amountOut: coins
    tradeFee: coins
}

/// DeDust pool `estimate_swap_out(asset_in, amount_in)`: (asset_out, amount_out, trade_fee). Asset TL-B:
/// `jetton$0001 workchain_id:int8 address:uint256`.
get fun estimate_swap_out(_assetIn: slice, amountIn: coins): MockEstimate {
    val storage = lazy MockDexStorage.load();
    val (wc, hash) = storage.jettonMaster.getWorkchainAndHash();
    val asset = beginCell()
        .storeUint(1, 4)
        .storeInt(wc, 8)
        .storeUint(hash, 256)
        .endCell()
        .beginParse();
    return {
        asset,
        amountOut: (amountIn * storage.rate) / 1000000000,
        tradeFee: 0,
    };
}

get fun get_mock_data(): MockDexStorage {
    return MockDexStorage.load();
}
