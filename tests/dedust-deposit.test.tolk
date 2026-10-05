// DeDust deposit driven by StartDedustDeposit. CurveDex.graduate still builds PoolV2.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/dedust-fixtures"
import "@tests/fixtures"
import "@wrappers/CreatorFee.gen"
import "@wrappers/CurveDex.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/RewardMasterDex.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/curve-dex-storage"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/dividend-messages"
import "@contracts/launcher-dex/reward-types"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/vendor/jetton/messages"

struct SeenPool {
    status: int
    depositActive: bool
    swapActive: bool
    assetX: slice
    assetY: slice
    walletsByAssets: cell?
    assetsByWallets: cell?
    walletsResolutions: cell?
    baseFeeBPS: int
    reserveX: coins
    reserveY: coins
    liquidity: coins
    protocolFeeX: coins
    protocolFeeY: coins
    creatorFeeX: coins
    creatorFeeY: coins
    xLPFeePerToken: int
    yLPFeePerToken: int
    rewards: cell?
}

struct SeenPosition {
    poolAddress: address
    ownerAddress: address
    liquidity: coins
    lockedLiquidity: coins
    rewards: cell?
    xPending: coins
    yPending: coins
    xFeePerTokenCheckpoint: int
    yFeePerTokenCheckpoint: int
}

const P_COIN = 1000000000
const P_VTON = ton("510")
const P_VTOKEN = 1073000000 * P_COIN
const P_CURVE = 800000000 * P_COIN
const P_POOL = 200000000 * P_COIN
const P_FEE = ton("26")
const REWARD = 100000000

fun selloutNet(): coins {
    val endToken = P_VTOKEN - P_CURVE;
    return (P_VTON * P_CURVE + endToken - 1) / endToken;
}

fun loadDedustLibraries() {
    val pool = build("DeDustPool", "tests/data/dedust-pool-v2.boc");
    val deposit = build("DeDustDeposit", "tests/data/dedust-deposit-v2.boc");
    val position = build("DeDustPosition", "tests/data/dedust-position-v2.boc");
    expect(pool.hash()).toEqual(DEDUST_POOL_V2_LIBRARY_HASH);
    expect(deposit.hash()).toEqual(DEDUST_DEPOSIT_V2_LIBRARY_HASH);
    expect(position.hash()).toEqual(DEDUST_POSITION_V2_LIBRARY_HASH);
    testing.registerLibrary(pool);
    testing.registerLibrary(deposit);
    testing.registerLibrary(position);
}

fun setupSellout(): DexWorld {
    testing.setNow(WORLD_T0);
    val factory = testing.treasury("dep-factory");
    val vault = testing.treasury("dep-vault");
    val protocol = testing.treasury("dep-protocol");
    val pot = testing.treasury("dep-pot");
    val buyback = testing.treasury("dep-buyback");
    val net = selloutNet();
    val master = RewardMasterDex.fromStorage({
        totalSupply: 0,
        poolReserve: 0,
        curveOpen: true,
        pool: null,
        roles: RewardMasterRoles {
            factory: factory.address,
            seq: 1,
            curve: null,
            vault: vault.address,
        }.toCell(),
        indices: createEmptyMap(),
        remainders: createEmptyMap(),
        metadata: jettonMetadata("COIN"),
        excludedOwner: null,
        excludedBalance: 0,
    });
    expect(
        master.deploy(factory.address, { value: ton("0.2"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: master.address,
    });
    val splitter = FeeSplitterV2.fromStorage({
        admin: factory.address,
        active: true,
        locked: 0,
        accrued: 0,
        totalIn: 0,
        minSplit: 0,
        minProtocolBps: 1000,
        routes: FeeRoutes {
            protocol: protocol.address,
            pot: pot.address,
            buyback: buyback.address,
        }.toCell(),
        reward: RewardRoute {
            vault: vault.address,
            splits: {
                holdersBps: 7000,
                protocolBps: 1500,
                potBps: 1000,
                buybackBps: 500,
            },
        }.toCell(),
        proposal: null,
    });
    expect(
        splitter.deploy(factory.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: splitter.address,
    });
    val curve = CurveDex.fromStorage({
        state: CURVE_OPEN,
        virtualTon: P_VTON + net,
        virtualToken: P_VTOKEN - P_CURVE,
        realTon: net,
        sold: P_CURVE,
        pool: null,
        roles: CurveRoles {
            factory: factory.address,
            master: master.address,
            splitter: splitter.address,
        }.toCell(),
        params: CurveParams {
            protocol: protocol.address,
            feeBps: 100,
            curveSupply: P_CURVE,
            poolSupply: P_POOL,
            graduationTon: ton("3000"),
            graduationFee: P_FEE,
            minBuy: ton("0.1"),
            poolLpFeeBps: 100,
            poolProtocolFeeBps: 100,
            walletCode: build("RewardWalletDex"),
        }.toCell(),
        extra: CurveDexExtra { creator: null }.toCell(),
    });
    expect(
        curve.deploy(factory.address, { value: ton("0.2"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: curve.address,
    });
    expect(
        master.sendWireMaster(
            factory.address,
            1,
            curve.address,
            vault.address,
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<WireMaster>({ to: master.address });
    expect(
        curve.sendTopUpTons(factory.address, { value: net + ton("0.2"), bounce: false }),
    ).toHaveSuccessfulTx<TopUpTons>({ to: curve.address });
    return {
        factory,
        vault,
        protocol,
        pot,
        buyback,
        master,
        splitter,
        curve,
    };
}

get fun `test dedust deposit: init failure leaves the curve open and the GRAM in place`() {
    val w = setupSellout();
    val probe = testing.treasury("dep-probe");
    val parked = CurveDex.fromStorage({
        state: CURVE_DEDUST_INIT,
        virtualTon: w.curve.getCurveData().virtualTon,
        virtualToken: w.curve.getCurveData().virtualToken,
        realTon: w.curve.getCurveData().realTon,
        sold: P_CURVE,
        pool: probe.address,
        roles: w.curve.getCurveData().roles.toCell(),
        params: w.curve.getCurveData().params.toCell(),
        extra: CurveDexExtra { creator: null }.toCell(),
    });
    // The live curve above is the funded one. This second curve only checks the abort branch.
    expect(
        parked.deploy(w.factory.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: parked.address,
    });
    val before = parked.getCurveData().realTon;
    expect(
        net.send(
            probe.address,
            createMessage({
                bounce: true,
                value: ton("0.05"),
                dest: parked.address,
                body: DedustInitResult {
                    queryId: 4,
                    exitCode: 7,
                    customPayload: null,
                },
            }),
        ),
    ).toHaveSuccessfulTx<DedustInitResult>({ to: parked.address });
    expect(parked.getCurveData().state).toEqual(CURVE_OPEN);
    expect(parked.getCurveData().pool == null).toBeTrue();
    expect(parked.getCurveData().realTon).toEqual(before);
}

get fun `test dedust deposit: a short position does not count as graduated`() {
    val w = setupSellout();
    val creator = testing.treasury("dep-short-creator");
    val pool = calcDedustPool(w.master.address, creator.address).calculateAddress();
    val parked = CurveDex.fromStorage({
        state: CURVE_DEDUST_SENT,
        virtualTon: P_VTON + selloutNet(),
        virtualToken: P_VTOKEN - P_CURVE,
        realTon: selloutNet(),
        sold: P_CURVE,
        pool,
        roles: CurveRoles {
            factory: w.factory.address,
            master: w.master.address,
            splitter: w.splitter.address,
        }.toCell(),
        params: w.curve.getCurveData().params.toCell(),
        extra: CurveDexExtra { creator: null }.toCell(),
    });
    expect(
        parked.deploy(w.factory.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: parked.address,
    });
    val position = calcDedustPosition(pool, parked.address);
    expect(
        net.send(
            position,
            createMessage({
                bounce: false,
                value: ton("0.05"),
                dest: parked.address,
                body: DedustDepositNote {
                    queryId: 5,
                    liquidity: 1,
                    lockedLiquidity: 1,
                    payload: null,
                },
            }),
        ),
    ).toHaveSuccessfulTx<DedustDepositNote>({ to: parked.address });
    expect(parked.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    expect(parked.getCurveData().realTon).toEqual(selloutNet());
}

get fun `test dedust deposit: pool supply is excluded, locked, and priced like the curve`() {
    loadDedustLibraries();
    val w = setupSellout();
    val holder = testing.treasury("dep-holder");
    val creator = CreatorFee.fromStorage({
        splitter: w.splitter.address,
        accrued: 0,
        master: w.master.address,
        keeper: holder.address,
    });
    expect(
        creator.deploy(w.factory.address, { value: ton("0.05"), bounce: false }),
    ).toHaveSuccessfulDeploy({
        to: creator.address,
    });
    val pool = calcDedustPool(w.master.address, creator.address);
    val poolAddress = pool.calculateAddress();
    expect(dedustGasFromFee() < P_FEE).toBeTrue();
    expect(
        net.send(
            w.factory.address,
            createMessage({
                bounce: true,
                value: ton("0.15"),
                dest: w.curve.address,
                body: ExcludeFromDividends {
                    queryId: 1,
                    owner: poolAddress,
                },
            }),
        ),
    ).toHaveSuccessfulTx<SetDividendExcluded>({ from: w.curve.address, to: w.master.address });
    expect(masterData(w).excludedOwner).toEqual(poolAddress);
    expect(
        net.send(
            w.curve.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: w.master.address,
                body: MintReward {
                    queryId: 2,
                    to: holder.address,
                    amount: P_CURVE,
                    forwardTonAmount: 0,
                    forwardPayload: null,
                },
            }),
        ),
    ).toHaveSuccessfulTx<MintReward>({ to: w.master.address });
    expect(masterData(w).poolReserve).toEqual(0);
    val res = net.send(
        w.factory.address,
        createMessage({
            bounce: true,
            value: ton("0.05"),
            dest: w.curve.address,
            body: StartDedustDeposit {
                queryId: 3,
                creator: creator.address,
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<DedustInit>({ to: poolAddress });
    expect(res).toHaveSuccessfulTx<DedustInitResult>({ from: poolAddress, to: w.curve.address });
    val liquidity = selloutNet() - P_FEE;
    val protocolFee = P_FEE - dedustGasFromFee();
    expect(res).toHaveTx({ from: w.curve.address, to: w.protocol.address, value: protocolFee });
    expect(res).toHaveTx<DedustPayNative>({
        from: w.curve.address,
        to: poolAddress,
        value: liquidity + DEDUST_NATIVE_GAS,
    });
    expect(w.splitter.getSplitterData().totalIn).toEqual(0);
    expect(masterData(w).poolReserve).toEqual(0);
    expect(res).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.master.address });
    expect(balanceOf(w, poolAddress)).toEqual(P_POOL);
    val seen = net.runGetMethod<SeenPool>(poolAddress, "get_pool_data");
    val gram = seen.reserveX < seen.reserveY ? seen.reserveX : seen.reserveY;
    val jet = seen.reserveX > seen.reserveY ? seen.reserveX : seen.reserveY;
    expect(jet).toEqual(P_POOL);
    expect(gram).toEqual(liquidity);
    val position = net.runGetMethod<address>(
        poolAddress,
        "get_position_address",
        [w.curve.address],
    );
    expect(position).toEqual(calcDedustPosition(poolAddress, w.curve.address));
    val confirmed = net.send(
        w.factory.address,
        createMessage({
            bounce: true,
            value: ton("0.1"),
            dest: w.curve.address,
            body: ConfirmDedustDeposit { queryId: 9 },
        }),
    );
    expect(confirmed).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    expect(seen.baseFeeBPS).toEqual(DEDUST_BASE_FEE_BPS as int);
    val endTon = w.curve.getCurveData().virtualTon;
    val endToken = P_VTOKEN - P_CURVE;
    // realTon was cleared at confirmation, so the end price uses the stored virtual reserve.
    val curvePx = (endTon * P_COIN) / endToken;
    val poolPx = (gram * P_COIN) / jet;
    expect(poolPx).toEqual(curvePx);
    val lp = net.runGetMethod<SeenPosition>(position, "get_position_data");
    expect(lp.lockedLiquidity).toEqual(lp.liquidity);
    expect(lp.liquidity >= isqrt(liquidity * P_POOL)).toBeTrue();
    expect(masterData(w).excludedBalance).toEqual(P_POOL);
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    expect(claimable(w, poolAddress, 0)).toEqual(0);
    val due = claimable(w, holder.address, 0);
    val data = masterData(w);
    val rem = amountOf(data.remainders, 0);
    val delta = indexOf(data.indices, 0) - indexBefore;
    val scaled = REWARD * INDEX_SCALE + oldRem;
    val earning = balanceOf(w, holder.address);
    expect(delta).toEqual(scaled / earning);
    expect(rem).toEqual(scaled % earning);
    expect(due).toEqual((earning * delta) / INDEX_SCALE);
}
