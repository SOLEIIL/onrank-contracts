// FactoryDex launches a coin whose graduate() starts the DeDust deposit.
// A curve with no creator still graduates to PoolV2: that path is dedust-exclude test 7.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CurveDex.gen"
import "@wrappers/FactoryDex.gen"
import "@wrappers/GasStation.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/launcher-dex/FactoryDex"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/dividend-messages"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"

struct (0xc442500f) DedustSwap {
    minimalAmountOut: coins
    deadline: uint40
    next: cell?
    partnerConfig: cell?
    referrerConfig: cell?
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

get fun `test factory dex: a sell-out buy starts the DeDust deposit`() {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("fac-admin");
    val protocol = testing.treasury("fac-protocol");
    val vault = testing.treasury("fac-vault");
    val pot = testing.treasury("fac-pot");
    val buyback = testing.treasury("fac-buyback");
    val buyer = testing.treasury("fac-buyer");
    val keeper = testing.treasury("fac-keeper");
    val station = deployGasStation(admin.address, protocol.address, keeper.address, ton("0.05"));
    val factory = FactoryDex.fromStorage({
        admin: admin.address,
        protocol: protocol.address,
        station: station.address,
        nextSeq: 1,
        codes: FactoryDexCodes {
            masterCode: build("RewardMasterDex"),
            curveCode: build("CurveDex"),
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
    ).toHaveSuccessfulDeploy({
        to: factory.address,
    });
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
    expect(station.getCreatorRefill(factory.getFactoryDexData().lastCreator!) != null).toBeTrue();
    expect(launched).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
    val curve = CurveDex.fromAddress(factory.getFactoryDexData().lastCurve!);
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
    val bought = curve.sendBuy(buyer.address, 3, 0, null, { value: ton("1700"), bounce: true });
    expect(bought).toHaveSuccessfulTx<Buy>({ to: curve.address });
    expect(bought).toHaveSuccessfulTx<DedustInit>({ from: curve.address, to: pool });
    expect(bought).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(curve.getCurveData().pool).toEqual(pool);
    expect(curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    val confirmed = net.send(
        factory.address,
        createMessage({
            bounce: true,
            value: ton("0.1"),
            dest: curve.address,
            body: ConfirmDedustDeposit { queryId: 9 },
        }),
    );
    expect(confirmed).toHaveSuccessfulTx<DedustPositionState>({ to: curve.address });
    expect(curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    val jetsBefore = RewardWalletDex
        .fromAddress(RewardMasterDex.fromAddress(master).getWalletAddress(buyer.address))
        .getRewardWalletData()
        .balance;
    val swap = net.send(
        buyer.address,
        createMessage({
            bounce: true,
            value: ton("1.15"),
            dest: pool,
            body: DedustPayNative {
                queryId: 11,
                amount: ton("1"),
                paymentPayload: DedustSwap {
                    minimalAmountOut: 1,
                    deadline: 1800003600,
                    next: null,
                    partnerConfig: null,
                    referrerConfig: null,
                }.toCell() as cell,
                payoutConfig: dedustPayout(buyer.address),
            },
        }),
    );
    expect(swap).toHaveSuccessfulTx<DedustPayNative>({ to: pool });
    val received = RewardWalletDex.fromAddress(
        RewardMasterDex.fromAddress(master).getWalletAddress(buyer.address),
    );
    expect(received.getRewardWalletData().balance > jetsBefore).toBeTrue();
}
