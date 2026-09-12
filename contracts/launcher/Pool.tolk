import "../common/consts"
import "../common/errors"
import "../vendor/jetton/messages"
import "fee-splitter-messages"
import "launcher-messages"
import "launcher-types"
import "reward-messages"
import "reward-types"

contract Pool {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Constant-product TON/coin pool with permanently locked liquidity. Every trade pays an LP fee (kept in the pool) and a creator fee (FeeSplitter). No admin."
    storage: PoolStorage
    incomingMessages: AllowedMessageToPool
}

type AllowedMessageToPool =
    | SwapTonForCoin
    | TransferNotificationForRecipient
    | ReturnExcessesBack
    | TopUpTons

/// Gas kept from a TON->coin swap: coin transfer (settle round trip), FeeIn, ExcludedUpdate.
const SWAP_GAS = ton("0.2")
/// Value attached to the coin transfer towards the buyer.
const POOL_COIN_TRANSFER_VALUE = ton("0.11")
/// Value attached to ExcludedUpdate towards the master.
const EXCLUDED_UPDATE_VALUE = ton("0.01")
/// Gas kept from a coin->TON swap for the pool's own messages.
const SELL_GAS = ton("0.06")
const SPLIT_GAS_POOL = ton("0.03")

fun emitPoolEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun PoolStorage.coinWallet(self, roles: PoolRoles): address {
    return calcRewardWalletAddress(contract.getAddress(), roles.master, roles.walletCode);
}

fun sendFee(splitter: address, fee: coins, queryId: uint64) {
    if (fee == 0) {
        return;
    }
    val m = createMessage({
        bounce: BounceMode.NoBounce,
        dest: splitter,
        value: fee + SPLIT_GAS_POOL,
        body: FeeIn { queryId, amount: fee },
    });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun sendExcludedUpdate(master: address, balance: coins, queryId: uint64) {
    val m = createMessage({
        bounce: BounceMode.NoBounce,
        dest: master,
        value: EXCLUDED_UPDATE_VALUE,
        body: ExcludedUpdate { queryId, balance },
    });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

/// Coins -> TON quote: gross TON out for `coinIn`, before fees.
fun PoolStorage.grossTonOut(self, coinIn: coins): coins {
    return ((self.reserveTon * coinIn) / (self.reserveCoin + coinIn)) as coins;
}

/// Sends the coins back to `to` (refused swap).
fun PoolStorage.returnCoins(self, roles: PoolRoles, to: address, amount: coins, queryId: uint64) {
    val back = createMessage({
        bounce: BounceMode.NoBounce,
        dest: self.coinWallet(roles),
        value: 0,
        body: AskToTransfer {
            queryId,
            jettonAmount: amount,
            transferRecipient: to,
            sendExcessesTo: to,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: emptyForwardPayload(),
        },
    });
    back.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy PoolStorage.load();
    val msg = lazy AllowedMessageToPool.fromSlice(in.body);

    match (msg) {
        SwapTonForCoin => {
            val roles = lazy storage.roles.load();
            assert (storage.reserveCoin > 0 && storage.reserveTon > 0) throw Errors.PoolEmpty;
            assert (in.valueCoins > SWAP_GAS) throw Errors.InsufficientValue;
            val amountIn = in.valueCoins - SWAP_GAS;
            val lpFee = (amountIn * storage.lpFeeBps) / 10000;
            val protocolFee = (amountIn * storage.protocolFeeBps) / 10000;
            val net = amountIn - lpFee - protocolFee;
            val out = ((storage.reserveCoin * net) / (storage.reserveTon + net)) as coins;
            assert (out > 0 && out >= msg.minOut) throw Errors.SlippageExceeded;

            storage.reserveTon += net + lpFee;
            storage.reserveCoin -= out;
            storage.volumeTon += amountIn;
            storage.save();

            // keep the previous balance plus what the pool gains; the rest of the value pays our messages
            reserveToncoinsOnBalance(contract.getOriginalBalance() - in.valueCoins + net + lpFee, RESERVE_MODE_EXACT_AMOUNT);
            val transfer = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.coinWallet(roles),
                value: POOL_COIN_TRANSFER_VALUE,
                body: AskToTransfer {
                    queryId: msg.queryId,
                    jettonAmount: out,
                    transferRecipient: in.senderAddress,
                    sendExcessesTo: in.senderAddress,
                    customPayload: null,
                    forwardTonAmount: 1,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            transfer.send(SEND_MODE_PAY_FEES_SEPARATELY);
            sendFee(roles.splitter, protocolFee, msg.queryId);
            sendExcludedUpdate(roles.master, storage.reserveCoin, msg.queryId);
            emitPoolEvent(EVENT_TOPIC_POOL_SWAP, PoolSwapEvent {
                isBuy: true,
                trader: in.senderAddress,
                ton: amountIn,
                coin: out,
                lpFee,
                protocolFee,
                reserveTon: storage.reserveTon,
                reserveCoin: storage.reserveCoin,
            });
            val excesses = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        TransferNotificationForRecipient => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == storage.coinWallet(roles)) throw Errors.NotFromCoinWallet;

            if (msg.transferInitiator == null) {
                // minted by the master on the Curve's order: initial (or additional) liquidity
                storage.reserveCoin += msg.jettonAmount;
                storage.save();
                sendExcludedUpdate(roles.master, storage.reserveCoin, msg.queryId);
                return;
            }
            val trader: address = msg.transferInitiator;

            // payload must be SwapCoinForTon (inline or in a ref); anything else is refunded
            var payload = msg.forwardPayload;
            val inRef = payload.loadBool();
            if (inRef) {
                payload = payload.loadRef().beginParse();
            }
            var minOut: coins = 0;
            var valid = payload.remainingBitsCount() >= 32 && payload.preloadUint(32) == 0x504F0002 && in.valueCoins >= SELL_GAS + SPLIT_GAS_POOL;
            if (valid) {
                payload.skipBits(32);
                minOut = payload.loadCoins();
            }
            var gross: coins = 0;
            var lpFee: coins = 0;
            var protocolFee: coins = 0;
            var net: coins = 0;
            if (valid && storage.reserveCoin > 0) {
                gross = storage.grossTonOut(msg.jettonAmount);
                lpFee = (gross * storage.lpFeeBps) / 10000;
                protocolFee = (gross * storage.protocolFeeBps) / 10000;
                net = gross - lpFee - protocolFee;
                valid = net > 0 && net >= minOut && gross < storage.reserveTon;
            } else {
                valid = false;
            }
            if (!valid) {
                storage.returnCoins(roles, trader, msg.jettonAmount, msg.queryId);
                return;
            }

            storage.reserveCoin += msg.jettonAmount;
            storage.reserveTon -= net + protocolFee;
            storage.volumeTon += gross;
            storage.save();

            // reserves stay; the trader's gas (in.valueCoins) pays for our messages
            reserveToncoinsOnBalance(contract.getOriginalBalance() - in.valueCoins - net - protocolFee, RESERVE_MODE_EXACT_AMOUNT);
            sendFee(roles.splitter, protocolFee, msg.queryId);
            sendExcludedUpdate(roles.master, storage.reserveCoin, msg.queryId);
            emitPoolEvent(EVENT_TOPIC_POOL_SWAP, PoolSwapEvent {
                isBuy: false,
                trader,
                ton: net,
                coin: msg.jettonAmount,
                lpFee,
                protocolFee,
                reserveTon: storage.reserveTon,
                reserveCoin: storage.reserveCoin,
            });
            val payout = createMessage({
                bounce: BounceMode.NoBounce,
                dest: trader,
                value: net,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            payout.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        ReturnExcessesBack => {
            // gas back from our own coin transfers: stays as reserve buffer
        }

        TopUpTons => {
            // accept
        }

        else => {
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0) throw 0xFFFF;
        }
    }
}

get fun get_pool_data(): PoolDataReply {
    val storage = lazy PoolStorage.load();
    val roles = storage.roles.load();
    return {
        reserveTon: storage.reserveTon,
        reserveCoin: storage.reserveCoin,
        lpFeeBps: storage.lpFeeBps,
        protocolFeeBps: storage.protocolFeeBps,
        volumeTon: storage.volumeTon,
        master: roles.master,
        splitter: roles.splitter,
        coinWallet: storage.coinWallet(roles),
    };
}

/// Coin received for `tonIn` TON attached (SWAP_GAS excluded by the caller).
get fun get_buy_quote(tonIn: coins): Quote {
    val storage = lazy PoolStorage.load();
    val lpFee = (tonIn * storage.lpFeeBps) / 10000;
    val protocolFee = (tonIn * storage.protocolFeeBps) / 10000;
    val net = tonIn - lpFee - protocolFee;
    if (storage.reserveCoin == 0) {
        return { amountOut: 0, fee: lpFee + protocolFee };
    }
    return { amountOut: ((storage.reserveCoin * net) / (storage.reserveTon + net)) as coins, fee: lpFee + protocolFee };
}

/// Net TON received for `coinIn` coins.
get fun get_sell_quote(coinIn: coins): Quote {
    val storage = lazy PoolStorage.load();
    if (storage.reserveCoin == 0) {
        return { amountOut: 0, fee: 0 };
    }
    val gross = storage.grossTonOut(coinIn);
    val lpFee = (gross * storage.lpFeeBps) / 10000;
    val protocolFee = (gross * storage.protocolFeeBps) / 10000;
    return { amountOut: gross - lpFee - protocolFee, fee: lpFee + protocolFee };
}

get fun get_swap_gas(): coins {
    return SWAP_GAS;
}
