// The anti-freeze net: RetryDedustConfirm is public, but it only triggers the same verification the
// factory relay does — the position's own answer decides. Nobody can force a graduation that did
// not happen, and a dead keeper can no longer freeze a coin (the DESTT lesson, 2026-10-05).
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CurveDex2.gen"
import "@wrappers/FactoryDexTest2.gen"
import "@wrappers/GasStation.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/CurveDex2"
import "@contracts/launcher-dex/FactoryDexTest2"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"

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

struct RetryWorld {
    admin: Treasury
    stranger: Treasury
    curve: CurveDex2
    pool: address
}

/// The DESTT scene: a coin bought to 100%, deposit credited on the DeDust pool, graduation waiting
/// in CURVE_DEDUST_SENT — and no keeper nor admin in sight.
fun setupStuck(): RetryWorld {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("retry-admin");
    val protocol = testing.treasury("retry-protocol");
    val vault = testing.treasury("retry-vault");
    val pot = testing.treasury("retry-pot");
    val buyback = testing.treasury("retry-buyback");
    val buyer = testing.treasury("retry-buyer");
    val keeper = testing.treasury("retry-keeper");
    val stranger = testing.treasury("retry-stranger");
    val station = deployGasStation(admin.address, protocol.address, keeper.address, ton("0.05"));
    val factory = FactoryDexTest2.fromStorage({
        admin: admin.address,
        protocol: protocol.address,
        station: station.address,
        nextSeq: 1,
        codes: FactoryDexCodes {
            masterCode: build("RewardMasterDex"),
            curveCode: build("CurveDex2"),
            splitterCode: build("FeeSplitterV2"),
            more: FactoryDexCodesMore {
                creatorCode: build("CreatorFee"),
                walletCode: build("RewardWalletDex"),
            }.toCell(),
        }.toCell(),
        last: null,
        keeper: FactoryDexKeeper { keeper: keeper.address }.toCell(),
    });
    expect(
        factory.deploy(admin.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    bindFactory(station, admin.address, factory.address);
    expect(
        factory.sendLaunchDex(
            admin.address,
            1,
            jettonMetadata("COIN"),
            vault.address,
            pot.address,
            buyback.address,
            { value: ton("1"), bounce: true },
        ),
    ).toHaveSuccessfulTx<LaunchDex>({ to: factory.address });
    val curve = CurveDex2.fromAddress(factory.getFactoryDexData().lastCurve!);
    val bought = curve.sendBuy(buyer.address, 3, 0, null, { value: ton("12"), bounce: true });
    expect(bought).toHaveSuccessfulTx<Buy>({ to: curve.address });
    expect(curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    return {
        admin,
        stranger,
        curve,
        pool: curve.getCurveData().pool!,
    };
}

get fun `test dedust retry: anyone can trigger the verification and unfreeze a real graduation`() {
    val w = setupStuck();
    val retried = w
        .curve
        .sendRetryDedustConfirm(
            w.stranger.address,
            21,
            { value: RETRY_CONFIRM_GAS, bounce: true },
        );
    expect(retried).toHaveSuccessfulTx<RetryDedustConfirm>({ to: w.curve.address });
    expect(retried).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    expect(w.curve.getCurveData().realTon).toEqual(0);
}

get fun `test dedust retry: refused outside state 4, with a short value, and after graduation`() {
    val w = setupStuck();
    // short value: nothing happens, the graduation stays available
    expect(
        w
            .curve
            .sendRetryDedustConfirm(w.stranger.address, 22, { value: ton("0.03"), bounce: true }),
    ).toHaveFailedTx<RetryDedustConfirm>({
        to: w.curve.address,
        exitCode: Errors.InsufficientValue,
    });
    expect(w.curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    // real retry succeeds
    expect(
        w
            .curve
            .sendRetryDedustConfirm(
                w.stranger.address,
                23,
                { value: RETRY_CONFIRM_GAS, bounce: true },
            ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    // after graduation the net refuses: no replay surface
    expect(
        w
            .curve
            .sendRetryDedustConfirm(
                w.stranger.address,
                24,
                { value: RETRY_CONFIRM_GAS, bounce: true },
            ),
    ).toHaveFailedTx<RetryDedustConfirm>({
        to: w.curve.address,
        exitCode: Errors.CurveNotOpen,
    });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
}

get fun `test dedust retry: a forged position answer still cannot graduate the curve`() {
    val w = setupStuck();
    // the stranger answers in place of the position: ignored, the state does not move
    expect(
        w
            .curve
            .sendDedustPositionState(
                w.stranger.address,
                25,
                1000000000000000,
                1000000000000000,
                beginCell().endCell().beginParse(),
                { value: ton("0.05"), bounce: false },
            ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
}
