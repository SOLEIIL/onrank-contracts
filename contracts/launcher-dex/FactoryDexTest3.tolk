import "creator-fee-storage"
import "curve-dex-storage"
import "dedust-pool"
import "dividend-messages"
import "gas-station-types"
import "reward-types"
import "../common/errors"
import "../launcher-v2/fee-splitter-types"
import "../launcher-v2/launcher-messages"
import "../launcher-v2/launcher-types"
import "../launcher-v2/reward-messages"
import "../launcher-v2/vault-types"
import "../vendor/jetton/messages"

// SANDBOX copy of FactoryDex3 (the PUBLIC launcher-dex factory) with a tiny curve: graduation at
// ~10 GRAM instead of ~1494.5, to rehearse the full public pipeline on mainnet at minimal cost —
// a NON-admin wallet launches, dev-buys, graduates, sells on DeDust and claims dividends.
// Differences from FactoryDex3, and nothing else:
//   virtualTon    510  -> 3.4   (curve sells out at ~9.96 GRAM instead of ~1494.5)
//   graduationTon 3000 -> 20    (proportional ceiling, still unused)
//   graduationFee 26   -> 1.5   (must stay >= dedustGasFromFee() = 1.1; leaves ~0.4 to the protocol)
// Note: at this scale the DeDust pool opens ~13% below the curve's final price (the live 26 GRAM fee
// is what makes both prices equal). Harmless for a sandbox coin.
// Everything below this block mirrors FactoryDex3:
//   LaunchDexPublic              — public launch: metadata + whitelisted rewards + optional dev buy.
//     The creator is the sender: he owns the coin's CreatorFee claims and metadata verification.
//     pot/buyback/vault routes come from the factory's own storage — a launcher cannot divert fees.
//   RewardVaultDex per coin      — the real dividend circuit: the splitter's 70% goes to a vault that
//     converts and bumps the RewardMasterDex indices, holders claim like on v2 coins (the rehearsal
//     coins skipped this: their "vault" was a plain wallet address).
//   ExcludeFromDividends(pool)   — sent automatically at launch: the DeDust pool's 200M never dilute
//     the holders (the rehearsal coins had to do this by hand; coin 20002 shipped without it).
//   SetDexFactoryPaused          — admin switch, same shape as FactoryV2's.
//   V2 value discipline          — reserve-then-carry excesses: a public sender gets his change back
//     and can never drain the factory's own balance.

struct FactoryDexCodesMore {
    creatorCode: cell
    walletCode: cell
}

struct FactoryDexCodes {
    masterCode: cell
    curveCode: cell
    splitterCode: cell
    more: Cell<FactoryDexCodesMore>
}

struct FactoryDexLastMore {
    creator: address
    curve: address
}

struct FactoryDexLast {
    master: address
    splitter: address
    more: Cell<FactoryDexLastMore>
}

/// Keeper + the fee routes a public launcher must never choose (SEC: a message-supplied pot/buyback
/// would let anyone route protocol fees to himself).
struct FactoryDexOps {
    keeper: address
    pot: address
    buyback: address
    vaultCfg: Cell<FactoryDexVaultCfg>
}

/// Everything a per-coin RewardVaultDex needs (mirrors FactoryV2's FactoryConfig vault fields).
struct FactoryDexVaultCfg {
    vaultCode: cell
    /// DeDust native vault — the only TON destination of a reward conversion.
    dexVault: address
    vaultReserve: coins
    vaultPendingTimeout: uint32
    rewardWhitelist: map<address, bool>
    dexPools: map<address, bool>
}

struct FactoryDexStorage {
    admin: address
    protocol: address
    station: address
    nextSeq: uint64
    paused: bool
    codes: Cell<FactoryDexCodes>
    last: Cell<FactoryDexLast>?
    ops: Cell<FactoryDexOps>
}

fun FactoryDexStorage.load(): FactoryDexStorage {
    return FactoryDexStorage.fromCell(contract.getData());
}

fun FactoryDexStorage.save(self) {
    contract.setData(self.toCell());
}

struct FactoryDexData {
    admin: address
    protocol: address
    station: address
    nextSeq: uint64
    lastMaster: address?
    lastSplitter: address?
    lastCreator: address?
    lastCurve: address?
    // last so the app's shared FactoryDex decoder keeps reading FactoryDex/FactoryDex2 replies too
    paused: bool
}

/// Anyone -> factory. Launches a DeDust coin for the sender: deploys master, splitter, creator fee,
/// reward vault and curve, wires them, excludes the future pool from dividends, opens the curve and
/// performs the sender's first buy. Value must cover DEX_LAUNCH_FEE + firstBuyTon (+ CURVE_BUY_GAS)
/// + rewards × VAULT_DISCOVERY_PER_REWARD + DEX_LAUNCH_GAS; the change comes back to the sender.
struct (0x43550032) LaunchDexPublic {
    queryId: uint64
    metadata: cell
    rewards: map<uint8, address>
    firstBuyTon: coins
}

/// Admin or keeper -> factory. Relays ConfirmDedustDeposit to a curve waiting in CURVE_DEDUST_SENT,
/// so it asks its DeDust position for the deposited liquidity and finalizes the graduation.
/// Retryable and idempotent: the factory keeps no state, the curve refuses it outside state 4, and
/// a confirmed curve ignores a late position answer (confirmDedust checks state again).
struct (0x43550031) RelayConfirmDedust {
    queryId: uint64
    curve: address
}

/// Admin: stops future launches. Live coins, trading and graduations are untouched.
struct (0x43550033) SetDexFactoryPaused {
    queryId: uint64
    paused: bool
}

/// What a relay must carry: the curve spends 0.07 asking the position, plus fees on both hops.
const RELAY_CONFIRM_GAS: coins = ton("0.15")
/// Protocol profit per launch — the same price a FactoryV2 launch charges (config.launchFee).
const DEX_LAUNCH_FEE: coins = ton("0.5")
/// The fixed sends of a launch: splitter 0.1 + creator 0.05 + master 0.2 + vault 0.2 + curve 0.2
/// + wire 0.05 + open 0.05 + register 0.05 + exclude 0.15 = 1.05, plus our own compute.
const DEX_LAUNCH_GAS: coins = ton("1.2")
/// Gas of the optional first buy (same as FactoryV2's CURVE_BUY_GAS).
const CURVE_BUY_GAS: coins = ton("0.15")
/// Per reward slot: the vault's TEP-89 wallet discovery (same as FactoryV2).
const VAULT_DISCOVERY_PER_REWARD: coins = ton("0.04")

const SPLITTER_DEPLOY_VALUE: coins = ton("0.1")
const CREATOR_DEPLOY_VALUE: coins = ton("0.05")
const MASTER_DEPLOY_VALUE: coins = ton("0.2")
const VAULT_DEPLOY_VALUE: coins = ton("0.2")
const CURVE_DEPLOY_VALUE: coins = ton("0.2")
const WIRE_VALUE: coins = ton("0.05")
const OPEN_VALUE: coins = ton("0.05")
const REGISTER_VALUE: coins = ton("0.05")
const EXCLUDE_VALUE: coins = ton("0.15")

contract FactoryDexTest3 {
    author: "GRAMDESKS"
    version: "3.2.0"
    description: "Sandbox FactoryDex3 with a ~10 GRAM graduation: public launch rehearsal only; never user-facing."
    storage: FactoryDexStorage
    incomingMessages: AllowedMessageToFactoryDex
}

type AllowedMessageToFactoryDex =
    | LaunchDexPublic
    | RelayConfirmDedust
    | SetDexFactoryPaused
    | TopUpTons

fun countRewards(rewards: map<uint8, address>): int {
    var count = 0;
    var r = rewards.findFirst();
    while (r.isFound) {
        count += 1;
        r = rewards.iterateNext(r);
    }
    return count;
}

fun dexVaultInit(
    admin: address,
    keeper: address,
    master: address,
    walletCode: cell,
    cfg: FactoryDexVaultCfg,
    rewards: map<uint8, address>,
): AutoDeployAddress {
    var slots: map<uint8, RewardSlot> = [];
    var seen: map<address, bool> = [];
    var count = 0;
    var r = rewards.findFirst();
    while (r.isFound) {
        assert (r.getKey() == count && count < MAX_REWARDS) throw Errors.TooManyRewards;
        val rewardMaster = r.loadValue();
        assert (cfg.rewardWhitelist.exists(rewardMaster)) throw Errors.DestNotWhitelisted;
        // one slot per jetton master: the vault attributes TEP-89 answers by master, a duplicate would
        // leave its slot undiscovered for ever and stall every conversion of the coin (SEC-201)
        assert (!seen.exists(rewardMaster)) throw Errors.InvalidParams;
        seen.set(rewardMaster, true);
        slots.set(
            r.getKey(),
            RewardSlot {
                rewardMaster,
                vaultWallet: null,
                carry: 0,
                paid: 0,
            },
        );
        count += 1;
        r = rewards.iterateNext(r);
    }
    return {
        workchain: BASECHAIN,
        stateInit: {
            code: cfg.vaultCode,
            data: RewardVaultStorage {
                rewardCount: count as uint8,
                cycleNext: 0,
                totalTonIn: 0,
                totalTonSpent: 0,
                reserve: cfg.vaultReserve,
                pendingTimeout: cfg.vaultPendingTimeout,
                payoutNonce: 0,
                roles: RewardVaultRoles {
                    admin,
                    keeper,
                    master,
                    walletCode,
                }.toCell(),
                rewards: slots,
                dexVault: cfg.dexVault,
                pending: null,
                extra: VaultExtra {
                    dexPools: cfg.dexPools,
                    payouts: [],
                    proposal: null,
                }.toCell(),
            }.toCell(),
        },
    };
}

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    var storage = lazy FactoryDexStorage.load();
    val msg = lazy AllowedMessageToFactoryDex.fromSlice(in.body);
    match (msg) {
        LaunchDexPublic => {
            assert (!storage.paused) throw Errors.FactoryPaused;
            assert (in.senderAddress.getWorkchain() == BASECHAIN) throw Errors.InvalidWorkchain;
            val ops = storage.ops.load();
            val vaultCfg = ops.vaultCfg.load();
            val rewardsGas = countRewards(msg.rewards) * VAULT_DISCOVERY_PER_REWARD;
            val firstBuyGas: coins = msg.firstBuyTon > 0 ? CURVE_BUY_GAS : (0 as coins);
            assert (
                in.valueCoins >=
                DEX_LAUNCH_FEE + msg.firstBuyTon + firstBuyGas + rewardsGas + DEX_LAUNCH_GAS
            ) throw Errors.LaunchFeeUnpaid;

            val seq = storage.nextSeq;
            storage.nextSeq = seq + 1;
            val codes = storage.codes.load();
            val more = codes.more.load();
            val master = AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit: {
                    code: codes.masterCode,
                    data: RewardMasterStorage {
                        totalSupply: 0,
                        poolReserve: 0,
                        curveOpen: false,
                        pool: null,
                        roles: RewardMasterRoles {
                            factory: contract.getAddress(),
                            seq,
                            curve: null,
                            vault: null,
                        }.toCell(),
                        indices: [],
                        remainders: [],
                        metadata: msg.metadata,
                        excludedOwner: null,
                        excludedBalance: 0,
                    }.toCell(),
                },
            };
            val masterAddress = master.calculateAddress();
            val vault = dexVaultInit(
                storage.admin,
                ops.keeper,
                masterAddress,
                more.walletCode,
                vaultCfg,
                msg.rewards,
            );
            val vaultAddress = vault.calculateAddress();
            val splitter = AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit: {
                    code: codes.splitterCode,
                    data: FeeSplitterStorage {
                        admin: storage.admin,
                        active: true,
                        locked: 0,
                        accrued: 0,
                        totalIn: 0,
                        minSplit: ton("0.1"),
                        minProtocolBps: 1000,
                        routes: FeeRoutes {
                            protocol: storage.station,
                            pot: ops.pot,
                            buyback: ops.buyback,
                        }.toCell(),
                        reward: RewardRoute {
                            // no reward chosen: the holders' share stays locked in the splitter (v2 parity)
                            // until the admin wires a vault — it never sits in a vault with zero slots
                            vault: countRewards(msg.rewards) > 0 ? vaultAddress : null,
                            splits: {
                                holdersBps: 7000,
                                protocolBps: 1500,
                                potBps: 1000,
                                buybackBps: 500,
                            },
                        }.toCell(),
                        proposal: null,
                    }.toCell(),
                },
            };
            val creator = AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit: {
                    code: more.creatorCode,
                    data: CreatorFeeStorage {
                        splitter: splitter.calculateAddress(),
                        accrued: 0,
                        master: masterAddress,
                        keeper: ops.keeper,
                    }.toCell(),
                },
            };
            val curve = AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit: {
                    code: codes.curveCode,
                    data: CurveDexStorage {
                        state: CURVE_INIT,
                        virtualTon: ton("3.4"),
                        virtualToken: 1073000000 * ton("1"),
                        realTon: 0,
                        sold: 0,
                        pool: null,
                        roles: CurveRoles {
                            factory: contract.getAddress(),
                            master: masterAddress,
                            splitter: splitter.calculateAddress(),
                        }.toCell(),
                        params: CurveParams {
                            protocol: storage.protocol,
                            feeBps: 100,
                            curveSupply: 800000000 * ton("1"),
                            poolSupply: 200000000 * ton("1"),
                            graduationTon: ton("20"),
                            graduationFee: ton("1.5"),
                            minBuy: ton("0.1"),
                            poolLpFeeBps: 100,
                            poolProtocolFeeBps: 100,
                            walletCode: more.walletCode,
                        }.toCell(),
                        extra: CurveDexExtra { creator: creator.calculateAddress() }.toCell(),
                    }.toCell(),
                },
            };
            storage.last = FactoryDexLast {
                master: masterAddress,
                splitter: splitter.calculateAddress(),
                more: FactoryDexLastMore {
                    creator: creator.calculateAddress(),
                    curve: curve.calculateAddress(),
                }.toCell(),
            }.toCell();
            storage.save();

            // keep our previous balance; everything attached to this message is spent on the launch
            reserveToncoinsOnBalance(
                contract.getOriginalBalance() - in.valueCoins,
                RESERVE_MODE_EXACT_AMOUNT,
            );

            val dSplitter = createMessage({
                bounce: BounceMode.NoBounce,
                dest: splitter,
                value: SPLITTER_DEPLOY_VALUE,
                body: TopUpTons {},
            });
            dSplitter.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dCreator = createMessage({
                bounce: BounceMode.NoBounce,
                dest: creator,
                value: CREATOR_DEPLOY_VALUE,
                body: TopUpTons {},
            });
            dCreator.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dMaster = createMessage({
                bounce: BounceMode.NoBounce,
                dest: master,
                value: MASTER_DEPLOY_VALUE,
                body: TopUpTons {},
            });
            dMaster.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dVault = createMessage({
                bounce: BounceMode.NoBounce,
                dest: vault,
                value: VAULT_DEPLOY_VALUE + rewardsGas,
                body: TopUpTons {},
            });
            dVault.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dCurve = createMessage({
                bounce: BounceMode.NoBounce,
                dest: curve,
                value: CURVE_DEPLOY_VALUE,
                body: TopUpTons {},
            });
            dCurve.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val wire = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: masterAddress,
                value: WIRE_VALUE,
                body: WireMaster {
                    queryId: msg.queryId,
                    curve: curve.calculateAddress(),
                    vault: vaultAddress,
                },
            });
            wire.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val open = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: curve.calculateAddress(),
                value: OPEN_VALUE,
                body: OpenCurve { queryId: msg.queryId },
            });
            open.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val reg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.station,
                value: REGISTER_VALUE,
                body: RegisterCreator {
                    queryId: msg.queryId,
                    creator: creator.calculateAddress(),
                },
            });
            reg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            // the coin's future DeDust pool never earns dividends: its 200M would dilute every holder
            // (the factory is the only sender the curve accepts for this)
            val exclude = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: curve.calculateAddress(),
                value: EXCLUDE_VALUE,
                body: ExcludeFromDividends {
                    queryId: msg.queryId,
                    owner: calcDedustPool(masterAddress, creator.calculateAddress()).calculateAddress(),
                },
            });
            exclude.send(SEND_MODE_PAY_FEES_SEPARATELY);
            if (msg.firstBuyTon > 0) {
                val firstBuy = createMessage({
                    bounce: BounceMode.NoBounce,
                    dest: curve.calculateAddress(),
                    value: msg.firstBuyTon + CURVE_BUY_GAS,
                    body: Buy {
                        queryId: msg.queryId,
                        minOut: 0,
                        recipient: in.senderAddress,
                    },
                });
                firstBuy.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            val fee = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.protocol,
                value: DEX_LAUNCH_FEE,
            });
            fee.send(SEND_MODE_PAY_FEES_SEPARATELY);
            // whatever is left of the gas budget goes back to the launcher
            val excesses = createMessage({
                bounce: BounceMode.NoBounce,
                dest: in.senderAddress,
                value: 0,
                body: ReturnExcessesBack { queryId: msg.queryId },
            });
            // SAFETY: last action after a RESERVE of what we held before this message
            excesses.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        RelayConfirmDedust => {
            val keeper = storage.ops.load().keeper;
            assert (
                in.senderAddress == storage.admin || in.senderAddress == keeper
            ) throw Errors.NotFromAdmin;
            assert (in.valueCoins >= RELAY_CONFIRM_GAS) throw Errors.InsufficientValue;
            val relay = createMessage({
                // a curve that is not in CURVE_DEDUST_SENT throws: the bounce keeps the value here
                bounce: BounceMode.Only256BitsOfBody,
                dest: msg.curve,
                value: 0,
                body: ConfirmDedustDeposit { queryId: msg.queryId },
            });
            relay.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        SetDexFactoryPaused => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            storage.paused = msg.paused;
            storage.save();
        }
        TopUpTons => {}
    }
}

get fun get_factory_dex_data(): FactoryDexData {
    val storage = lazy FactoryDexStorage.load();
    return {
        admin: storage.admin,
        protocol: storage.protocol,
        station: storage.station,
        nextSeq: storage.nextSeq,
        lastMaster: storage.last != null ? storage.last!.load().master : null,
        lastSplitter: storage.last != null ? storage.last!.load().splitter : null,
        lastCreator: storage.last != null ? storage.last!.load().more.load().creator : null,
        lastCurve: storage.last != null ? storage.last!.load().more.load().curve : null,
        paused: storage.paused,
    };
}
