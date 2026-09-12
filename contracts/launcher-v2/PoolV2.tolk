import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/vendor/jetton/messages"
import "fee-splitter-messages"
import "launcher-messages"
import "launcher-types"
import "reward-messages"
import "reward-types"

contract PoolV2 {
    author: "GRAMDESKS"
    version: "2.0.0"
    description: "Constant-product TON/coin pool with permanently locked liquidity. Owns its coins through the RewardMaster (no wallet): buyers are delivered by the master, sells arrive as burns. Every trade pays an LP fee (kept) and a creator fee (FeeSplitter). No admin."
    storage: PoolStorage
    incomingMessages: AllowedMessageToPool
}

type AllowedMessageToPool =
    | SwapTonForCoin
    | SellNotify
    | PoolOutFailed
    | TransferNotificationForRecipient
    | ReturnExcessesBack
    | TopUpTons

/// Gas kept from a TON->coin swap: PoolOut (master compute + wallet deploy + notification), FeeIn, excess.
const SWAP_GAS = ton("0.15")
/// Value attached to the PoolOut towards the master.
const POOL_OUT_VALUE = ton("0.1")
/// Minimum value a SellNotify must carry for the pool's own messages (PoolCredit + FeeIn + payout).
const SELL_GAS = ton("0.06")
const SPLIT_GAS_POOL = ton("0.03")
const POOL_CREDIT_VALUE = ton("0.01")

fun emitPoolEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun sendFee(splitter: address, fee: coins, queryId: uint64) {
    if (fee == 0) {
        return;
    }
    val m = createMessage({
        bounce: BounceMode.NoBounce,
        dest: splitter,
        value: fee + SPLIT_GAS_POOL,
        body: FeeIn {
            queryId,
            amount: fee,
        },
    });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

/// Coins -> TON quote: gross TON out for `coinIn`, before fees.
fun PoolStorage.grossTonOut(self, coinIn: coins): coins {
    return ((self.reserveTon * coinIn) / (self.reserveCoin + coinIn)) as coins;
}

/// A delivery did not reach the buyer: the coins are back in the reserve (the master already
/// restored `poolReserve`) and the buyer gets his TON back if the entry is still known.
fun PoolStorage.deliveryFailed(mutate self, inValue: coins, nonce: uint64, amount: coins) {
    self.reserveCoin += amount;
    val found = self.inFlight.get(nonce);
    if (!found.isFound) {
        self.save();
        emitPoolEvent(
            EVENT_TOPIC_POOL_REFUND,
            PoolRefundEvent {
                nonce,
                coin: amount,
                ton: 0,
                refunded: false,
            },
        );
        return;
    }
    val entry = found.loadValue();
    self.inFlight.delete(nonce);
    self.reserveTon -= entry.ton;
    self.save();
    emitPoolEvent(
        EVENT_TOPIC_POOL_REFUND,
        PoolRefundEvent {
            nonce,
            coin: amount,
            ton: entry.ton,
            refunded: true,
        },
    );
    // the refund is the last action: the buyer's TON plus whatever value came back with the failure
    reserveToncoinsOnBalance(
        contract.getOriginalBalance() - inValue - entry.ton,
        RESERVE_MODE_EXACT_AMOUNT,
    );
    val refund = createMessage({
        bounce: BounceMode.NoBounce,
        dest: entry.to,
        value: 0,
        body: ReturnExcessesBack { queryId: nonce },
    });
    // SAFETY: last action after a RESERVE of what we held before this message: carries the incoming value minus our fixed sends (rule 1, docs/10)
    refund.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy PoolStorage.load();
    val msg = lazy AllowedMessageToPool.fromSlice(in.body);

    match (msg) {
        SwapTonForCoin => {
            val roles = lazy storage.roles.load();
            assert (storage.reserveCoin > 0 && storage.reserveTon > 0) throw Errors.PoolEmpty;
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            assert (in.valueCoins > SWAP_GAS) throw Errors.InsufficientValue;
            val amountIn = in.valueCoins - SWAP_GAS;
            val lpFee = (amountIn * storage.lpFeeBps) / 10000;
            val protocolFee = (amountIn * storage.protocolFeeBps) / 10000;
            val net = amountIn - lpFee - protocolFee;
            val out = ((storage.reserveCoin * net) / (storage.reserveTon + net)) as coins;
            assert (out > 0 && out >= msg.minOut) throw Errors.SlippageExceeded;

            storage.nonce += 1;
            if (storage.nonce > POOL_INFLIGHT_RING) {
                storage.inFlight.delete(storage.nonce - POOL_INFLIGHT_RING);
            }
            storage
                .inFlight
                .set(
                    storage.nonce,
                    {
                        to: in.senderAddress,
                        ton: net + lpFee,
                        coin: out,
                    },
                );
            storage.reserveTon += net + lpFee;
            storage.reserveCoin -= out;
            storage.volumeTon += amountIn;
            storage.save();

            // keep the previous balance plus what the pool gains; the rest of the value pays our messages
            reserveToncoinsOnBalance(
                contract.getOriginalBalance() - in.valueCoins + net + lpFee,
                RESERVE_MODE_EXACT_AMOUNT,
            );
            val deliver = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: roles.master,
                value: POOL_OUT_VALUE,
                body: PoolOut {
                    queryId: storage.nonce,
                    amount: out,
                    to: in.senderAddress,
                    forwardTonAmount: 1,
                },
            });
            deliver.send(SEND_MODE_PAY_FEES_SEPARATELY);
            sendFee(roles.splitter, protocolFee, msg.queryId);
            emitPoolEvent(
                EVENT_TOPIC_POOL_SWAP,
                PoolSwapEvent {
                    isBuy: true,
                    trader: in.senderAddress,
                    ton: amountIn,
                    coin: out,
                    lpFee,
                    protocolFee,
                    reserveTon: storage.reserveTon,
                    reserveCoin: storage.reserveCoin,
                },
            );
            val excesses = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            // SAFETY: last action after a RESERVE of what we held before this message: carries the incoming value minus our fixed sends (rule 1, docs/10)
            excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        SellNotify => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.master) throw Errors.NotFromMaster;

            var gross: coins = 0;
            var lpFee: coins = 0;
            var protocolFee: coins = 0;
            var net: coins = 0;
            var ok = storage.reserveCoin > 0 && in.valueCoins >= SELL_GAS + SPLIT_GAS_POOL;
            if (ok) {
                gross = storage.grossTonOut(msg.amount);
                lpFee = (gross * storage.lpFeeBps) / 10000;
                protocolFee = (gross * storage.protocolFeeBps) / 10000;
                net = gross - lpFee - protocolFee;
                ok = net > 0 && net >= msg.minTon && gross < storage.reserveTon;
            }
            if (!ok) {
                // refused: the master burned the coins on the Settle, it mints them back to the seller
                val back = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: roles.master,
                    value: 0,
                    body: Remint {
                        queryId: msg.queryId,
                        to: msg.owner,
                        amount: msg.amount,
                    },
                });
                back.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }

            storage.reserveCoin += msg.amount;
            storage.reserveTon -= net + protocolFee;
            storage.volumeTon += gross;
            storage.save();

            // reserves stay; the value forwarded by the master pays for our messages
            reserveToncoinsOnBalance(
                contract.getOriginalBalance() - in.valueCoins - net - protocolFee,
                RESERVE_MODE_EXACT_AMOUNT,
            );
            val credit = createMessage({
                bounce: BounceMode.NoBounce,
                dest: roles.master,
                value: POOL_CREDIT_VALUE,
                body: PoolCredit {
                    queryId: msg.queryId,
                    amount: msg.amount,
                },
            });
            credit.send(SEND_MODE_PAY_FEES_SEPARATELY);
            sendFee(roles.splitter, protocolFee, msg.queryId);
            emitPoolEvent(
                EVENT_TOPIC_POOL_SWAP,
                PoolSwapEvent {
                    isBuy: false,
                    trader: msg.owner,
                    ton: net,
                    coin: msg.amount,
                    lpFee,
                    protocolFee,
                    reserveTon: storage.reserveTon,
                    reserveCoin: storage.reserveCoin,
                },
            );
            val payout = createMessage({
                bounce: BounceMode.NoBounce,
                dest: msg.owner,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            // SAFETY: last action after a RESERVE of what we held before this message: carries the incoming value minus our fixed sends (rule 1, docs/10)
            payout.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        PoolOutFailed => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.master) throw Errors.NotFromMaster;
            storage.deliveryFailed(in.valueCoins, msg.queryId, msg.amount);
        }

        TransferNotificationForRecipient => {
            // Coins sent to the pool by a jetton transfer (the v1 sell path of a stale client, a manual transfer): the pool
            // owns no coins through a wallet, so they go straight back to whoever sent them, on the value they attached.
            // A transfer without notification (forwardTonAmount 0) never reaches this handler: those coins stay in the
            // pool's wallet, which nobody can move — that is what a raw transfer to a contract address means.
            val roles = lazy storage.roles.load();
            val ownWallet = calcRewardWalletAddress(
                contract.getAddress(),
                roles.master,
                roles.walletCode,
            );
            if (in.senderAddress != ownWallet || msg.transferInitiator == null) {
                return; // foreign jetton or a mint: nothing we can do, keep the gas
            }
            val initiator: address = msg.transferInitiator;
            val back = createMessage({
                bounce: BounceMode.NoBounce,
                dest: ownWallet,
                value: 0,
                body: AskToTransfer {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    transferRecipient: initiator,
                    sendExcessesTo: initiator,
                    customPayload: null,
                    forwardTonAmount: 0,
                    forwardPayload: emptyForwardPayload(),
                },
            });
            back.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        ReturnExcessesBack => {
            // gas back from the wallet after a return: kept as reserve buffer
        }

        TopUpTons => {
            // accept
        }

        else => {
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0) throw 0xFFFF;
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var storage = lazy PoolStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op == 0x52570030) {
        // PoolOut refused by the master (its state did not change): same as a failed delivery
        val roles = lazy storage.roles.load();
        assert (in.senderAddress == roles.master) throw Errors.NotFromMaster;
        val nonce = in.bouncedBody.loadUint(64);
        val amount = in.bouncedBody.loadCoins();
        storage.deliveryFailed(in.valueCoins, nonce, amount);
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
        nonce: storage.nonce,
        master: roles.master,
        splitter: roles.splitter,
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
    return {
        amountOut: ((storage.reserveCoin * net) / (storage.reserveTon + net)) as coins,
        fee: lpFee + protocolFee,
    };
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

get fun get_code_version(): int {
    return LAUNCHER_CODE_VERSION;
}
