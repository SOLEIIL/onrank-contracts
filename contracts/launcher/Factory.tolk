import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/vendor/jetton/messages"
import "factory-messages"
import "factory-types"
import "fee-splitter-messages"
import "fee-splitter-types"
import "launcher-messages"
import "launcher-types"
import "reward-messages"
import "reward-types"

contract Factory {
    author: "GRAMDESKS"
    version: "0.1.0"
    description: "Launchpad factory: deploys RewardMaster, RewardVault, FeeSplitter and Curve for a new coin in one transaction, wires them, opens the curve and performs the creator's first buy."
    storage: FactoryStorage
    incomingMessages: AllowedMessageToFactory
}

type AllowedMessageToFactory =
    | CreateLaunch
    | SetFactoryPaused
    | SetFactoryConfig
    | SetFactoryRoles
    | TopUpTons
    | ReturnExcessesBack

/// Gas budget of a launch on top of launchFee + firstBuyTon (deploys, wiring, discovery, first buy gas).
const LAUNCH_GAS = ton("1")
const MASTER_DEPLOY_VALUE = ton("0.1")
const VAULT_DEPLOY_VALUE = ton("0.1")
const VAULT_DISCOVERY_PER_REWARD = ton("0.04")
const SPLITTER_DEPLOY_VALUE = ton("0.1")
const CURVE_DEPLOY_VALUE = ton("0.1")
const WIRE_VALUE = ton("0.05")
const OPEN_VALUE = ton("0.05")
/// Gas the Curve keeps from a Buy (must match Curve.BUY_GAS).
const CURVE_BUY_GAS = ton("0.15")

fun emitFactoryEvent<T>(topic: int, body: T) {
    val ev = createExternalLogMessage({
        dest: ExtOutLogBucket { topic: topic as uint248 },
        body,
    });
    ev.send(SEND_MODE_REGULAR);
}

fun masterInit(codes: FactoryCodes, seq: uint64, metadata: cell): AutoDeployAddress {
    return {
        workchain: BASECHAIN,
        stateInit: {
            code: codes.master,
            data: RewardMasterStorage {
                totalSupply: 0,
                excluded: 0,
                curveOpen: false,
                pool: null,
                roles: RewardMasterRoles { factory: contract.getAddress(), seq, curve: null, vault: null }.toCell(),
                indices: createEmptyMap(),
                remainders: createEmptyMap(),
                metadata,
            }.toCell(),
        },
    };
}

fun vaultInit(codes: FactoryCodes, roles: FactoryRoles, config: FactoryConfig, master: address, rewards: map<uint8, address>): AutoDeployAddress {
    var slots: map<uint8, RewardSlot> = createEmptyMap();
    var count = 0;
    var r = rewards.findFirst();
    while (r.isFound) {
        assert (r.getKey() == count && count < MAX_REWARDS) throw Errors.TooManyRewards;
        slots.set(r.getKey(), RewardSlot { rewardMaster: r.loadValue(), vaultWallet: null, carry: 0, paid: 0 });
        count += 1;
        r = rewards.iterateNext(r);
    }
    return {
        workchain: BASECHAIN,
        stateInit: {
            code: codes.vault,
            data: RewardVaultStorage {
                rewardCount: count as uint8,
                cycleNext: 0,
                totalTonIn: 0,
                totalTonSpent: 0,
                reserve: config.vaultReserve,
                pendingTimeout: config.vaultPendingTimeout,
                roles: RewardVaultRoles { admin: roles.admin, keeper: roles.keeper, master }.toCell(),
                rewards: slots,
                dexVault: config.dexVault,
                dexPools: config.dexPools,
                pending: null,
            }.toCell(),
        },
    };
}

fun splitterInit(codes: FactoryCodes, roles: FactoryRoles, routes: FactoryRoutes, config: FactoryConfig, splits: FeeSplits, vault: address, active: bool): AutoDeployAddress {
    return {
        workchain: BASECHAIN,
        stateInit: {
            code: codes.splitter,
            data: FeeSplitterStorage {
                admin: roles.admin,
                active,
                locked: 0,
                accrued: 0,
                totalIn: 0,
                minSplit: config.minSplit,
                routes: FeeRoutes { protocol: roles.protocol, pot: routes.pot, buyback: routes.buyback }.toCell(),
                reward: RewardRoute { vault, splits }.toCell(),
            }.toCell(),
        },
    };
}

fun curveInit(codes: FactoryCodes, roles: FactoryRoles, config: FactoryConfig, master: address, splitter: address): AutoDeployAddress {
    val d = config.curve.load();
    val more = codes.more.load();
    return {
        workchain: BASECHAIN,
        stateInit: {
            code: more.curve,
            data: CurveStorage {
                state: CURVE_INIT,
                virtualTon: d.virtualTon0,
                virtualToken: d.virtualToken0,
                realTon: 0,
                sold: 0,
                pool: null,
                roles: CurveRoles { factory: contract.getAddress(), master, splitter }.toCell(),
                params: CurveParams {
                    protocol: roles.protocol,
                    feeBps: d.feeBps,
                    curveSupply: d.curveSupply,
                    poolSupply: d.poolSupply,
                    graduationTon: d.graduationTon,
                    graduationFee: d.graduationFee,
                    minBuy: d.minBuy,
                    poolLpFeeBps: d.poolLpFeeBps,
                    poolProtocolFeeBps: d.poolProtocolFeeBps,
                    walletCode: more.wallet,
                }.toCell(),
            }.toCell(),
        },
    };
}

fun deployWith<T>(dest: AutoDeployAddress, value: coins, body: T) {
    val m = createMessage({ bounce: BounceMode.NoBounce, dest, value, body });
    m.send(SEND_MODE_PAY_FEES_SEPARATELY);
}

fun onInternalMessage(in: InMessage) {
    var storage = lazy FactoryStorage.load();
    val msg = lazy AllowedMessageToFactory.fromSlice(in.body);

    match (msg) {
        CreateLaunch => {
            assert (!storage.paused) throw Errors.FactoryPaused;
            val roles = storage.roles.load();
            val routes = storage.routes.load();
            val config = storage.config.load();
            val codes = storage.codes.load();
            assert (in.valueCoins >= config.launchFee + msg.firstBuyTon + LAUNCH_GAS) throw Errors.LaunchFeeUnpaid;
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            var splits = config.splits;
            if (msg.splits != null) {
                assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
                val s = msg.splits;
                assert (s.holdersBps + s.protocolBps + s.potBps + s.buybackBps == 10000) throw Errors.InvalidSplits;
                splits = s;
            }

            val seq = storage.seq;
            storage.seq += 1;
            storage.save();

            val master = masterInit(codes, seq, msg.metadata);
            val masterAddress = master.calculateAddress();
            val vault = vaultInit(codes, roles, config, masterAddress, msg.rewards);
            val vaultAddress = vault.calculateAddress();
            val rewardCount = vaultInitRewardCount(msg.rewards);
            val splitter = splitterInit(codes, roles, routes, config, splits, vaultAddress, rewardCount > 0);
            val splitterAddress = splitter.calculateAddress();
            val curve = curveInit(codes, roles, config, masterAddress, splitterAddress);
            val curveAddress = curve.calculateAddress();

            // keep our previous balance; everything attached to this message is spent on the launch
            reserveToncoinsOnBalance(contract.getOriginalBalance() - in.valueCoins, RESERVE_MODE_EXACT_AMOUNT);

            deployWith(master, MASTER_DEPLOY_VALUE, TopUpTons {});
            deployWith(vault, VAULT_DEPLOY_VALUE + rewardCount * VAULT_DISCOVERY_PER_REWARD, TopUpTons {});
            deployWith(splitter, SPLITTER_DEPLOY_VALUE, TopUpTons {});
            deployWith(curve, CURVE_DEPLOY_VALUE, TopUpTons {});

            val wire = createMessage({
                bounce: BounceMode.NoBounce,
                dest: masterAddress,
                value: WIRE_VALUE,
                body: WireMaster { queryId: msg.queryId, curve: curveAddress, vault: vaultAddress },
            });
            wire.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val open = createMessage({
                bounce: BounceMode.NoBounce,
                dest: curveAddress,
                value: OPEN_VALUE,
                body: OpenCurve { queryId: msg.queryId },
            });
            open.send(SEND_MODE_PAY_FEES_SEPARATELY);
            if (msg.firstBuyTon > 0) {
                val firstBuy = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: curveAddress,
                    value: msg.firstBuyTon + CURVE_BUY_GAS,
                    body: Buy { queryId: msg.queryId, minOut: 0, recipient: in.senderAddress },
                });
                firstBuy.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            if (config.launchFee > 0) {
                val fee = createMessage({ bounce: BounceMode.NoBounce, dest: roles.protocol, value: config.launchFee });
                fee.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            emitFactoryEvent(EVENT_TOPIC_LAUNCH_CREATED, LaunchCreatedEvent {
                seq,
                creator: in.senderAddress,
                addresses: LaunchAddresses {
                    master: masterAddress,
                    vault: vaultAddress,
                    more: LaunchAddressesMore { splitter: splitterAddress, curve: curveAddress }.toCell(),
                }.toCell(),
                rewardCount: rewardCount as uint8,
                firstBuyTon: msg.firstBuyTon,
            });
            // whatever is left of the gas budget goes back to the creator
            val excesses = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        SetFactoryPaused => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            storage.paused = msg.paused;
            storage.save();
        }

        SetFactoryConfig => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            val c = msg.config.load();
            assert (c.splits.holdersBps + c.splits.protocolBps + c.splits.potBps + c.splits.buybackBps == 10000) throw Errors.InvalidSplits;
            storage.config = msg.config;
            storage.save();
        }

        SetFactoryRoles => {
            val roles = lazy storage.roles.load();
            assert (in.senderAddress == roles.admin) throw Errors.NotFromAdmin;
            storage.roles = msg.roles;
            storage.routes = msg.routes;
            storage.save();
        }

        TopUpTons => {
            // accept
        }

        ReturnExcessesBack => {
            // excess of the creator's first buy comes back to us (the Buy sender): kept as gas reserve
        }

        else => {
            assert (in.body.isEmpty() || in.body.preloadUint(32) == 0) throw 0xFFFF;
        }
    }
}

fun vaultInitRewardCount(rewards: map<uint8, address>): int {
    var count = 0;
    var r = rewards.findFirst();
    while (r.isFound) {
        count += 1;
        r = rewards.iterateNext(r);
    }
    return count;
}

get fun get_factory_data(): FactoryDataReply {
    val storage = lazy FactoryStorage.load();
    return {
        seq: storage.seq,
        paused: storage.paused,
        roles: storage.roles.load(),
        routes: storage.routes.load(),
        config: storage.config.load(),
    };
}

/// Deterministic addresses of a launch, computable before it happens.
/// `splits` = null for the factory default (regular launch), or the admin override used for that launch.
get fun get_launch_addresses(seq: uint64, metadata: cell, rewards: map<uint8, address>, splits: Cell<FeeSplits>?): LaunchAddresses {
    val storage = lazy FactoryStorage.load();
    val roles = storage.roles.load();
    val routes = storage.routes.load();
    val config = storage.config.load();
    val codes = storage.codes.load();
    val master = masterInit(codes, seq, metadata).calculateAddress();
    val vault = vaultInit(codes, roles, config, master, rewards).calculateAddress();
    val s = splits == null ? config.splits : splits.load();
    val splitter = splitterInit(codes, roles, routes, config, s, vault, vaultInitRewardCount(rewards) > 0).calculateAddress();
    val curve = curveInit(codes, roles, config, master, splitter).calculateAddress();
    return { master, vault, more: LaunchAddressesMore { splitter, curve }.toCell() };
}
