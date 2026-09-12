import "@gen/RewardWallet.code"
import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/vendor/jetton/messages"
import "@contracts/vendor/jetton/storage"
import "reward-messages"
import "reward-types"

contract RewardMaster {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Jetton master of a launched coin (TEP-74/89 surface) and dividend hub: holds one cumulative reward index per reward id, settles wallets, mints for the Curve, forwards sells."
    storage: RewardMasterStorage
    incomingMessages: AllowedMessageToRewardMaster
}

type AllowedMessageToRewardMaster =
    | Settle
    | MintReward
    | IndexBump
    | ExcludedUpdate
    | CurveGraduated
    | WireMaster
    | RequestWalletAddress
    | QueryMarket
    | TopUpTons

/// Value forwarded to the vault for each reward payout (jetton transfer + possible wallet deploy).
const PAYOUT_VALUE = ton("0.07")
/// Value forwarded to the curve with a SellNotify (curve compute + TON payout to the seller).
const SELL_NOTIFY_VALUE = ton("0.05")
/// Minimum left for the SettleAck back to the wallet.
const ACK_VALUE = ton("0.02")

fun emitMasterEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun walletCode(): cell {
    return rewardWalletCompiledCode();
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy RewardMasterStorage.load();
    val msg = lazy AllowedMessageToRewardMaster.fromSlice(in.body);

    match (msg) {
        Settle => {
            assert (in.senderAddress == calcRewardWalletAddress(msg.owner, contract.getAddress(), walletCode())) throw Errors.NotFromRewardWallet;
            val roles = lazy storage.roles.load();
            var claimed = false;

            if (msg.action == ACTION_CLAIM) {
                assert (roles.vault != null) throw Errors.NotWired;
                val excluded = storage.pool != null && storage.pool == msg.owner;
                // first pass: how many payouts, to check the attached value before sending anything
                var payouts = 0;
                var r = storage.indices.findFirst();
                while (r.isFound) {
                    val id = r.getKey();
                    val owed = owedFor(msg.balance, r.loadValue() as int, indexOf(msg.stamps, id), amountOf(msg.accrued, id));
                    if (owed > 0 && !excluded) {
                        payouts += 1;
                    }
                    r = storage.indices.iterateNext(r);
                }
                assert (in.valueCoins >= payouts * PAYOUT_VALUE + ACK_VALUE) throw Errors.InsufficientValue;
                r = storage.indices.findFirst();
                while (r.isFound) {
                    val id = r.getKey();
                    val owed = owedFor(msg.balance, r.loadValue() as int, indexOf(msg.stamps, id), amountOf(msg.accrued, id));
                    if (owed > 0 && !excluded) {
                        val pay = createMessage({
                            bounce: BounceMode.NoBounce,
                            dest: roles.vault!,
                            value: PAYOUT_VALUE,
                            body: PayReward { queryId: msg.queryId, owner: msg.owner, rewardId: id, amount: owed as coins },
                        });
                        pay.send(SEND_MODE_PAY_FEES_SEPARATELY);
                    }
                    r = storage.indices.iterateNext(r);
                }
                claimed = true;
            }

            if (msg.action == ACTION_BURN) {
                assert (msg.burnAmount > 0 && msg.burnAmount <= storage.totalSupply) throw Errors.BudgetExceeded;
                storage.totalSupply -= msg.burnAmount;
                storage.save();
                if (msg.sellMinTon != null) {
                    assert (storage.curveOpen && roles.curve != null) throw Errors.CurveClosed;
                    assert (in.valueCoins >= SELL_NOTIFY_VALUE + ACK_VALUE) throw Errors.InsufficientValue;
                    val sell = createMessage({
                        bounce: BounceMode.NoBounce,
                        dest: roles.curve!,
                        value: SELL_NOTIFY_VALUE,
                        body: SellNotify { queryId: msg.queryId, owner: msg.owner, amount: msg.burnAmount, minTon: msg.sellMinTon! },
                    });
                    sell.send(SEND_MODE_PAY_FEES_SEPARATELY);
                }
            }

            val ack = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: SettleAck { queryId: msg.queryId, claimed, indices: storage.indices },
            });
            ack.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        MintReward => {
            val roles = lazy storage.roles.load();
            assert (roles.curve != null && in.senderAddress == roles.curve) throw Errors.NotFromCurve;
            assert (msg.to.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            storage.totalSupply += msg.amount;
            storage.save();
            reserveToncoinsOnBalance(max(contract.getOriginalBalance() - in.valueCoins, MIN_STORAGE_RESERVE), RESERVE_MODE_AT_MOST);
            val step = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: calcDeployedRewardWallet(msg.to, contract.getAddress(), walletCode()),
                value: 0,
                body: RewardTransferStep {
                    queryId: msg.queryId,
                    jettonAmount: msg.amount,
                    transferInitiator: null,
                    sendExcessesTo: msg.to,
                    forwardTonAmount: msg.forwardTonAmount,
                    indices: storage.indices,
                    forwardPayload: beginCell().storeMaybeRef(msg.forwardPayload).endCell().beginParse(),
                },
            });
            step.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        IndexBump => {
            val roles = lazy storage.roles.load();
            assert (roles.vault != null && in.senderAddress == roles.vault) throw Errors.NotFromVault;
            assert (msg.rewardId < MAX_REWARDS) throw Errors.RewardUnknown;
            val circulating: coins = storage.totalSupply > storage.excluded ? storage.totalSupply - storage.excluded : (0 as coins);
            if (circulating == 0 || msg.amount == 0) {
                val refused = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: in.senderAddress,
                    value: 0,
                    body: IndexBumpRefused { queryId: msg.queryId, rewardId: msg.rewardId, amount: msg.amount },
                });
                refused.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                return;
            }
            // exact division: the remainder is carried so rounding never loses reward units
            val scaled = msg.amount * INDEX_SCALE + amountOf(storage.remainders, msg.rewardId);
            val newIndex = indexOf(storage.indices, msg.rewardId) + scaled / circulating;
            assert (newIndex < (1 << 128)) throw Errors.IndexOverflow;
            val index = newIndex as uint128;
            storage.indices.set(msg.rewardId, index);
            storage.remainders.set(msg.rewardId, (scaled % circulating) as coins);
            storage.save();
            emitMasterEvent(EVENT_TOPIC_INDEX_BUMPED, IndexBumpedEvent { rewardId: msg.rewardId, amount: msg.amount, circulating, index });
        }

        ExcludedUpdate => {
            assert (storage.pool != null && in.senderAddress == storage.pool) throw Errors.NotFromPool;
            storage.excluded = msg.balance;
            storage.save();
        }

        CurveGraduated => {
            val roles = lazy storage.roles.load();
            assert (roles.curve != null && in.senderAddress == roles.curve) throw Errors.NotFromCurve;
            storage.pool = msg.pool;
            storage.curveOpen = false;
            storage.save();
        }

        WireMaster => {
            var roles = storage.roles.load();
            assert (in.senderAddress == roles.factory) throw Errors.NotFromFactory;
            assert (roles.curve == null) throw Errors.AlreadyWired;
            roles.curve = msg.curve;
            roles.vault = msg.vault;
            storage.roles = roles.toCell();
            storage.curveOpen = true;
            storage.save();
        }

        RequestWalletAddress => {
            val ownerAddress: Cell<address>? = msg.includeOwnerAddress ? msg.ownerAddress.toCell() : null;
            var walletAddress: address? = null;
            if (msg.ownerAddress.getWorkchain() == BASECHAIN) {
                walletAddress = calcRewardWalletAddress(msg.ownerAddress, contract.getAddress(), walletCode());
            }
            val respond = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ResponseWalletAddress { queryId: msg.queryId, jettonWalletAddress: walletAddress, ownerAddress },
            });
            respond.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        QueryMarket => {
            val roles = lazy storage.roles.load();
            val answer = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: MarketAnswer { queryId: msg.queryId, curveOpen: storage.curveOpen, curve: roles.curve, pool: storage.pool },
            });
            answer.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
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
    var storage = lazy RewardMasterStorage.load();
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op == 0x52570003) {
        // mint step bounced: supply never reached the wallet
        in.bouncedBody.skipBits(64);
        val amount = in.bouncedBody.loadCoins();
        storage.totalSupply -= amount;
        storage.save();
    }
}

get fun get_jetton_data(): JettonDataReply {
    val storage = lazy RewardMasterStorage.load();
    val roles = storage.roles.load();
    return {
        totalSupply: storage.totalSupply,
        mintable: storage.curveOpen,
        adminAddress: roles.curve,
        jettonContent: storage.metadata as Cell<OnchainMetadataReply>,
        jettonWalletCode: walletCode(),
    };
}

get fun get_wallet_address(ownerAddress: address): address {
    return calcRewardWalletAddress(ownerAddress, contract.getAddress(), walletCode());
}

get fun get_reward_master_data(): RewardMasterDataReply {
    val storage = lazy RewardMasterStorage.load();
    return {
        totalSupply: storage.totalSupply,
        excluded: storage.excluded,
        curveOpen: storage.curveOpen,
        pool: storage.pool,
        roles: storage.roles.load(),
        indices: storage.indices,
        remainders: storage.remainders,
    };
}
