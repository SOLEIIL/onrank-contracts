// FactoryDex2 — the live replacement. The only new code is the factory's live constants (CurveDex2,
// the relay handler and every child contract are byte-identical to what the rehearsals proved), so
// this run checks exactly that: the curve a FactoryDex2 launch deploys carries the LIVE economics
// (virtualTon 510 -> sell-out at ~1494.5 GRAM, graduationFee 26), and the relay + auth behave like
// FactoryDexTest2's. Real DeDust libraries, no impersonation.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CurveDex2.gen"
import "@wrappers/FactoryDex2.gen"
import "@wrappers/GasStation.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/FactoryDex2"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/dividend-messages"
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

struct Live2World {
    admin: Treasury
    keeper: Treasury
    buyer: Treasury
    factory: FactoryDex2
    curve: CurveDex2
    pool: address
}

/// Deploys the real FactoryDex2, launches a coin and buys it out at live scale (~1494.5 GRAM) to
/// CURVE_DEDUST_SENT: the exact state DESTT froze in, now at production economics.
fun setupLiveGraduation(): Live2World {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("live2-admin");
    val protocol = testing.treasury("live2-protocol");
    val vault = testing.treasury("live2-vault");
    val pot = testing.treasury("live2-pot");
    val buyback = testing.treasury("live2-buyback");
    val buyer = testing.treasury("live2-buyer");
    val keeper = testing.treasury("live2-keeper");
    val station = deployGasStation(admin.address, protocol.address, keeper.address, ton("0.05"));
    val factory = FactoryDex2.fromStorage({
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
    val launched = factory.sendLaunchDex(
        admin.address,
        1,
        jettonMetadata("LIVE"),
        vault.address,
        pot.address,
        buyback.address,
        { value: ton("1"), bounce: true },
    );
    expect(launched).toHaveSuccessfulTx<LaunchDex>({ to: factory.address });
    val curve = CurveDex2.fromAddress(factory.getFactoryDexData().lastCurve!);
    val master = factory.getFactoryDexData().lastMaster!;
    val creator = factory.getFactoryDexData().lastCreator!;
    expect(curve.getCurveData().state).toEqual(CURVE_OPEN);
    // the LIVE curve shape: virtualTon 510, nothing sold yet
    expect(curve.getCurveData().virtualTon).toEqual(ton("510"));
    expect(curve.getCurveData().virtualToken).toEqual(1073000000 * ton("1"));
    val pool = calcDedustPool(master, creator).calculateAddress();
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.15"),
                dest: curve.address,
                body: ExcludeFromDividends {
                    queryId: 2,
                    owner: pool,
                },
            }),
        ),
    ).toHaveSuccessfulTx<SetDividendExcluded>({ from: curve.address, to: master });
    // live sell-out at ~1494.5 GRAM + 26 fee: one 1600 GRAM buy graduates, the excess bounces back
    val bought = curve.sendBuy(buyer.address, 3, 0, null, { value: ton("1600"), bounce: true });
    expect(bought).toHaveSuccessfulTx<Buy>({ to: curve.address });
    expect(bought).toHaveSuccessfulTx<DedustInit>({ from: curve.address, to: pool });
    expect(bought).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    expect(curve.getCurveData().pool).toEqual(pool);
    return {
        admin,
        keeper,
        buyer,
        factory,
        curve,
        pool,
    };
}

get fun `test dedust live2: live params sell out at ~1494.5 GRAM and the keeper relay finalizes`() {
    val w = setupLiveGraduation();
    // the sell-out the live virtualTon implies: 510 * 800M / (1073M - 800M) = ~1494.5 GRAM
    val d = w.curve.getCurveData();
    expect(d.realTon > ton("1494")).toEqual(true);
    expect(d.realTon < ton("1495")).toEqual(true);
    expect(d.sold).toEqual(800000000 * ton("1"));
    val relayed = w
        .factory
        .sendRelayConfirmDedust(
            w.keeper.address,
            9,
            w.curve.address,
            { value: RELAY_CONFIRM_GAS, bounce: true },
        );
    expect(relayed).toHaveSuccessfulTx<RelayConfirmDedust>({ to: w.factory.address });
    expect(relayed).toHaveSuccessfulTx<ConfirmDedustDeposit>({
        from: w.factory.address,
        to: w.curve.address,
    });
    expect(relayed).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    expect(w.curve.getCurveData().realTon).toEqual(0);
}

get fun `test dedust live2: a stranger cannot relay, a short value is refused, the real relay still lands`() {
    val w = setupLiveGraduation();
    expect(
        w
            .factory
            .sendRelayConfirmDedust(
                w.buyer.address,
                12,
                w.curve.address,
                { value: RELAY_CONFIRM_GAS, bounce: true },
            ),
    ).toHaveFailedTx<RelayConfirmDedust>({
        to: w.factory.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(
        w
            .factory
            .sendRelayConfirmDedust(
                w.keeper.address,
                13,
                w.curve.address,
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<RelayConfirmDedust>({
        to: w.factory.address,
        exitCode: Errors.InsufficientValue,
    });
    expect(w.curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    // the real relay then still succeeds: nothing above consumed the graduation
    expect(
        w
            .factory
            .sendRelayConfirmDedust(
                w.keeper.address,
                14,
                w.curve.address,
                { value: RELAY_CONFIRM_GAS, bounce: true },
            ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
}
