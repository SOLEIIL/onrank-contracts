import "creator-fee-storage"
import "curve-dex-storage"
import "dedust-pool"
import "gas-station-types"
import "reward-types"
import "../common/errors"
import "../launcher-v2/fee-splitter-types"
import "../launcher-v2/launcher-messages"
import "../launcher-v2/launcher-types"
import "../launcher-v2/reward-messages"
import "../vendor/jetton/messages"

// LIVE replacement of FactoryDex, with the anti-freeze fixes the DESTT rehearsal demanded and the
// second rehearsal (FactoryDexTest2 + CurveDex2, coin seq 20002, 2026-10-05) proved on mainnet:
// launch -> curve trading -> graduation -> keeper relay -> pool trading, all automatic, zero funds frozen.
// Same economics as FactoryDex, byte for byte: virtualTon 510 (curve sells out at ~1494.5 GRAM),
// graduationTon 3000 (unused ceiling), graduationFee 26 (covers the 1.1 DeDust gas and opens the pool
// exactly at the curve's final price), 800M curve / 200M pool, 1% trade fee, 70-15-10-5 split.
// Differences from FactoryDex, and nothing else:
//   RelayConfirmDedust (below)  — admin/keeper relay that finalizes a graduation stuck in CURVE_DEDUST_SENT
//   curveCode = CurveDex2       — same CurveDex plus the public RetryDedustConfirm re-check (its own net)
//
// Why the relay exists (the single root cause of the DESTT freeze): the curve only finalizes a DeDust
// graduation when its factory sends it ConfirmDedustDeposit, and the real DeDust position never notifies
// spontaneously (it answers Excesses, not DedustDepositNote). Without a factory relay nothing on-chain
// could ever emit that message, so every graduation froze in state 4. RelayConfirmDedust closes the loop.

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

struct FactoryDexKeeper {
    keeper: address
}

struct FactoryDexStorage {
    admin: address
    protocol: address
    station: address
    nextSeq: uint64
    codes: Cell<FactoryDexCodes>
    last: Cell<FactoryDexLast>?
    /// Ref: a fourth address in the root cell would pass 1023 bits.
    keeper: Cell<FactoryDexKeeper>
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
}

/// Admin -> factory. Deploys master, splitter, creator fee and curve, then wires and opens the curve.
struct (0x43550030) LaunchDex {
    queryId: uint64
    metadata: cell
    vault: address
    pot: address
    buyback: address
}

/// Admin or keeper -> factory. Relays ConfirmDedustDeposit to a curve waiting in CURVE_DEDUST_SENT,
/// so it asks its DeDust position for the deposited liquidity and finalizes the graduation.
/// Retryable and idempotent: the factory keeps no state, the curve refuses it outside state 4, and
/// a confirmed curve ignores a late position answer (confirmDedust checks state again).
struct (0x43550031) RelayConfirmDedust {
    queryId: uint64
    curve: address
}

/// What a relay must carry: the curve spends 0.07 asking the position, plus fees on both hops.
const RELAY_CONFIRM_GAS: coins = ton("0.15")

contract FactoryDex2 {
    author: "GRAMDESKS"
    version: "3.1.0"
    description: "Live FactoryDex with the ConfirmDedustDeposit relay and CurveDex2's public re-check. Same economics as FactoryDex (graduation ~1494.5 GRAM)."
    storage: FactoryDexStorage
    incomingMessages: AllowedMessageToFactoryDex
}

type AllowedMessageToFactoryDex =
    | LaunchDex
    | RelayConfirmDedust
    | TopUpTons

fun onInternalMessage(in: InMessage) {
    if (in.body.isEmpty()) {
        return;
    }
    var storage = lazy FactoryDexStorage.load();
    val msg = lazy AllowedMessageToFactoryDex.fromSlice(in.body);
    match (msg) {
        LaunchDex => {
            assert (in.senderAddress == storage.admin) throw Errors.NotFromAdmin;
            assert (in.valueCoins >= ton("1")) throw Errors.InsufficientValue;
            val seq = storage.nextSeq;
            storage.nextSeq = seq + 1;
            val codes = storage.codes.load();
            val more = codes.more.load();
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
                            pot: msg.pot,
                            buyback: msg.buyback,
                        }.toCell(),
                        reward: RewardRoute {
                            vault: msg.vault,
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
            val creator = AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit: {
                    code: more.creatorCode,
                    data: CreatorFeeStorage {
                        splitter: splitter.calculateAddress(),
                        accrued: 0,
                        master: master.calculateAddress(),
                        keeper: storage.keeper.load().keeper,
                    }.toCell(),
                },
            };
            val curve = AutoDeployAddress {
                workchain: BASECHAIN,
                stateInit: {
                    code: codes.curveCode,
                    data: CurveDexStorage {
                        state: CURVE_INIT,
                        virtualTon: ton("510"),
                        virtualToken: 1073000000 * ton("1"),
                        realTon: 0,
                        sold: 0,
                        pool: null,
                        roles: CurveRoles {
                            factory: contract.getAddress(),
                            master: master.calculateAddress(),
                            splitter: splitter.calculateAddress(),
                        }.toCell(),
                        params: CurveParams {
                            protocol: storage.protocol,
                            feeBps: 100,
                            curveSupply: 800000000 * ton("1"),
                            poolSupply: 200000000 * ton("1"),
                            graduationTon: ton("3000"),
                            graduationFee: ton("26"),
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
                master: master.calculateAddress(),
                splitter: splitter.calculateAddress(),
                more: FactoryDexLastMore {
                    creator: creator.calculateAddress(),
                    curve: curve.calculateAddress(),
                }.toCell(),
            }.toCell();
            storage.save();
            val dSplitter = createMessage({
                bounce: BounceMode.NoBounce,
                dest: splitter,
                value: ton("0.1"),
                body: TopUpTons {},
            });
            dSplitter.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dCreator = createMessage({
                bounce: BounceMode.NoBounce,
                dest: creator,
                value: ton("0.05"),
                body: TopUpTons {},
            });
            dCreator.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dMaster = createMessage({
                bounce: BounceMode.NoBounce,
                dest: master,
                value: ton("0.2"),
                body: TopUpTons {},
            });
            dMaster.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val dCurve = createMessage({
                bounce: BounceMode.NoBounce,
                dest: curve,
                value: ton("0.2"),
                body: TopUpTons {},
            });
            dCurve.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val wire = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: master.calculateAddress(),
                value: ton("0.05"),
                body: WireMaster {
                    queryId: msg.queryId,
                    curve: curve.calculateAddress(),
                    vault: msg.vault,
                },
            });
            wire.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val open = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                dest: curve.calculateAddress(),
                value: ton("0.05"),
                body: OpenCurve { queryId: msg.queryId },
            });
            open.send(SEND_MODE_PAY_FEES_SEPARATELY);
            val reg = createMessage({
                bounce: BounceMode.NoBounce,
                dest: storage.station,
                value: ton("0.05"),
                body: RegisterCreator {
                    queryId: msg.queryId,
                    creator: creator.calculateAddress(),
                },
            });
            reg.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }
        RelayConfirmDedust => {
            val keeper = storage.keeper.load().keeper;
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
    };
}
