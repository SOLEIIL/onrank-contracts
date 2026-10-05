// The DESTT fix, end to end: FactoryDexTest2's RelayConfirmDedust is the only sender the curve
// accepts, so a graduation finalizes with the REAL factory contract in the loop — no test
// impersonation of the factory for the confirmation step, real DeDust libraries for the pool,
// the deposit contract and the position.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CurveDex2.gen"
import "@wrappers/FactoryDexTest2.gen"
import "@wrappers/GasStation.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/FactoryDexTest2"
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

struct RelayWorld {
    admin: Treasury
    keeper: Treasury
    buyer: Treasury
    factory: FactoryDexTest2
    curve: CurveDex2
    pool: address
}

/// Deploys the real FactoryDexTest2, launches a coin and buys it to CURVE_DEDUST_SENT: the exact
/// state DESTT froze in on mainnet (pool created, deposit credited, nothing confirmed).
fun setupStuckGraduation(): RelayWorld {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("relay-admin");
    val protocol = testing.treasury("relay-protocol");
    val vault = testing.treasury("relay-vault");
    val pot = testing.treasury("relay-pot");
    val buyback = testing.treasury("relay-buyback");
    val buyer = testing.treasury("relay-buyer");
    val keeper = testing.treasury("relay-keeper");
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
    val launched = factory.sendLaunchDex(
        admin.address,
        1,
        jettonMetadata("COIN"),
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
    // ~10 GRAM sell-out on the sandbox params (virtualTon 3.4): one 12 GRAM buy graduates
    val bought = curve.sendBuy(buyer.address, 3, 0, null, { value: ton("12"), bounce: true });
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

get fun `test dedust relay: the keeper's relay finalizes a graduation stuck in state 4`() {
    val w = setupStuckGraduation();
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

get fun `test dedust relay: the admin can relay too, and a repeat is harmless`() {
    val w = setupStuckGraduation();
    expect(
        w
            .factory
            .sendRelayConfirmDedust(
                w.admin.address,
                10,
                w.curve.address,
                { value: RELAY_CONFIRM_GAS, bounce: true },
            ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: w.curve.address });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    // retry on an already-graduated curve: the curve refuses, the factory is unchanged, no freeze
    val again = w
        .factory
        .sendRelayConfirmDedust(
            w.admin.address,
            11,
            w.curve.address,
            { value: RELAY_CONFIRM_GAS, bounce: true },
        );
    expect(again).toHaveFailedTx<ConfirmDedustDeposit>({
        to: w.curve.address,
        exitCode: Errors.CurveNotOpen,
    });
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
}

get fun `test dedust relay: a stranger cannot relay and a short value is refused`() {
    val w = setupStuckGraduation();
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
