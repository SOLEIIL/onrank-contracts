// Four fresh pools, same reserves, four buy sizes. The v2 library has no estimate_swap_out.
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/message"

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
import "@contracts/vendor/jetton/messages"

struct (0xc442500f) DedustSwap {
    minimalAmountOut: coins
    deadline: uint40
    next: cell?
    partnerConfig: cell?
    referrerConfig: cell?
}

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

fun readPool(pool: address): SeenPool {
    return net.runGetMethod<SeenPool>(pool, "get_pool_data");
}

fun noteQuote(res: SendResultList, beforeX: coins, beforeY: coins, expectedOut: coins) {
    var seen = false;
    var txIdx = 0;
    repeat (res.size()) {
        val step = res.at(txIdx);
        var i = 0;
        repeat (step.outMessages.size()) {
            val cell = step.outMessages.get(i) as cell;
            val head = cell.beginParse();
            if (head.remainingBitsCount() >= 2 && head.preloadUint(2) == 0b11) {
                val ext = (cell as Cell<
                    TlbMessage<RemainingBitsAndRefs, TlbExternalOutMessageInfo>,
                >).load();
                var body = ext.loadBody();
                if (body.remainingBitsCount() >= 32 && body.preloadUint(32) == 0x78e79ba4) {
                    body.loadUint(32);
                    body.loadBool();
                    body.loadCoins();
                    val amountOut = body.loadCoins();
                    expect(amountOut).toEqual(expectedOut);
                    seen = true;
                }
            }
            i += 1;
        }
        txIdx += 1;
    }
    expect(seen).toBeTrue();
    expect(beforeX > 0).toBeTrue();
    expect(beforeY > 0).toBeTrue();
}

fun quoteOnce(
    admin: address,
    protocol: address,
    vault: address,
    pot: address,
    buyback: address,
    buyer: address,
    keeper: address,
    amount: coins,
    query: uint64,
    expectedOut: coins,
) {
    val station = deployGasStation(admin, protocol, keeper, ton("0.05"));
    val factory = FactoryDex.fromStorage({
        admin,
        protocol,
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
        keeper: FactoryDexKeeper { keeper }.toCell(),
    });
    expect(factory.deploy(admin, { value: ton("0.1"), bounce: false })).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    bindFactory(station, admin, factory.address);
    expect(
        factory.sendLaunchDex(
            admin,
            1,
            jettonMetadata("COIN"),
            vault,
            pot,
            buyback,
            { value: ton("1"), bounce: true },
        ),
    ).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
    val curve = CurveDex.fromAddress(factory.getFactoryDexData().lastCurve!);
    val master = factory.getFactoryDexData().lastMaster!;
    val creator = factory.getFactoryDexData().lastCreator!;
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
    expect(
        curve.sendBuy(buyer, 3, 0, null, { value: ton("1700"), bounce: true }),
    ).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: curve.address,
                body: ConfirmDedustDeposit { queryId: 9 },
            }),
        ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: curve.address });
    val before = readPool(pool);
    expect(before.reserveX).toEqual(1468505494506);
    expect(before.reserveY).toEqual(200000000000000000);
    expect(before.baseFeeBPS).toEqual(10);
    val swap = net.send(
        buyer,
        createMessage({
            bounce: true,
            value: amount + ton("0.15"),
            dest: pool,
            body: DedustPayNative {
                queryId: query,
                amount,
                paymentPayload: DedustSwap {
                    minimalAmountOut: 1,
                    deadline: 1800003600,
                    next: null,
                    partnerConfig: null,
                    referrerConfig: null,
                }.toCell() as cell,
                payoutConfig: dedustPayout(buyer),
            },
        }),
    );
    expect(swap).toHaveSuccessfulTx<DedustPayNative>({ to: pool });
    noteQuote(swap, before.reserveX, before.reserveY, expectedOut);
}

fun sellOnce(
    admin: address,
    protocol: address,
    vault: address,
    pot: address,
    buyback: address,
    buyer: address,
    keeper: address,
    amount: coins,
    expectedOut: coins,
) {
    val station = deployGasStation(admin, protocol, keeper, ton("0.05"));
    val factory = FactoryDex.fromStorage({
        admin,
        protocol,
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
        keeper: FactoryDexKeeper { keeper }.toCell(),
    });
    expect(factory.deploy(admin, { value: ton("0.1"), bounce: false })).toHaveSuccessfulDeploy({
        to: factory.address,
    });
    bindFactory(station, admin, factory.address);
    expect(
        factory.sendLaunchDex(
            admin,
            1,
            jettonMetadata("COIN"),
            vault,
            pot,
            buyback,
            { value: ton("1"), bounce: true },
        ),
    ).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
    val curve = CurveDex.fromAddress(factory.getFactoryDexData().lastCurve!);
    val master = factory.getFactoryDexData().lastMaster!;
    val creator = factory.getFactoryDexData().lastCreator!;
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
    expect(
        curve.sendBuy(buyer, 3, 0, null, { value: ton("1700"), bounce: true }),
    ).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(
        net.send(
            factory.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: curve.address,
                body: ConfirmDedustDeposit { queryId: 9 },
            }),
        ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: curve.address });
    val before = readPool(pool);
    expect(before.reserveX).toEqual(1468505494506);
    expect(before.reserveY).toEqual(200000000000000000);
    val wallet = RewardWalletDex.fromAddress(
        RewardMasterDex.fromAddress(master).getWalletAddress(buyer),
    );
    val swap = DedustSwap {
        minimalAmountOut: 1,
        deadline: 1800003600,
        next: null,
        partnerConfig: null,
        referrerConfig: null,
    }.toCell();
    val payload = beginCell()
        .storeUint(0xcbc33949, 32)
        .storeRef(swap)
        .storeRef(dedustPayout(buyer))
        .endCell();
    val sold = net.send(
        buyer,
        createMessage({
            bounce: true,
            value: ton("0.3"),
            dest: wallet.address,
            body: AskToTransfer {
                queryId: 40,
                jettonAmount: amount,
                transferRecipient: pool,
                sendExcessesTo: buyer,
                customPayload: null,
                forwardTonAmount: ton("0.2"),
                forwardPayload: beginCell()
                    .storeUint(1, 1)
                    .storeRef(payload)
                    .endCell()
                    .beginParse(),
            },
        }),
    );
    expect(sold).toHaveSuccessfulTx<AskToTransfer>({ to: wallet.address });
    noteQuote(sold, before.reserveX, before.reserveY, expectedOut);
}

get fun `test dedust quote: four buy sizes on the same reserves`() {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    quoteOnce(
        testing.treasury("q1-admin").address,
        testing.treasury("q1-protocol").address,
        testing.treasury("q1-vault").address,
        testing.treasury("q1-pot").address,
        testing.treasury("q1-buyback").address,
        testing.treasury("q1-buyer").address,
        testing.treasury("q1-keeper").address,
        ton("1"),
        11,
        135964333835765,
    );
    quoteOnce(
        testing.treasury("q20-admin").address,
        testing.treasury("q20-protocol").address,
        testing.treasury("q20-vault").address,
        testing.treasury("q20-pot").address,
        testing.treasury("q20-buyback").address,
        testing.treasury("q20-buyer").address,
        testing.treasury("q20-keeper").address,
        ton("20"),
        12,
        2684610603939864,
    );
    quoteOnce(
        testing.treasury("q100-admin").address,
        testing.treasury("q100-protocol").address,
        testing.treasury("q100-vault").address,
        testing.treasury("q100-pot").address,
        testing.treasury("q100-buyback").address,
        testing.treasury("q100-buyer").address,
        testing.treasury("q100-keeper").address,
        ton("100"),
        13,
        12739064468567522,
    );
    quoteOnce(
        testing.treasury("q7-admin").address,
        testing.treasury("q7-protocol").address,
        testing.treasury("q7-vault").address,
        testing.treasury("q7-pot").address,
        testing.treasury("q7-buyback").address,
        testing.treasury("q7-buyer").address,
        testing.treasury("q7-keeper").address,
        ton("7"),
        15,
        947883984415519,
    );
    quoteOnce(
        testing.treasury("q1000-admin").address,
        testing.treasury("q1000-protocol").address,
        testing.treasury("q1000-vault").address,
        testing.treasury("q1000-pot").address,
        testing.treasury("q1000-buyback").address,
        testing.treasury("q1000-buyer").address,
        testing.treasury("q1000-keeper").address,
        ton("1000"),
        14,
        80972512261197891,
    );
    sellOnce(
        testing.treasury("s1-admin").address,
        testing.treasury("s1-protocol").address,
        testing.treasury("s1-vault").address,
        testing.treasury("s1-pot").address,
        testing.treasury("s1-buyback").address,
        testing.treasury("s1-buyer").address,
        testing.treasury("s1-keeper").address,
        ton("1000"),
        7335154,
    );
    sellOnce(
        testing.treasury("s2-admin").address,
        testing.treasury("s2-protocol").address,
        testing.treasury("s2-vault").address,
        testing.treasury("s2-pot").address,
        testing.treasury("s2-buyback").address,
        testing.treasury("s2-buyer").address,
        testing.treasury("s2-keeper").address,
        1000000 * ton("1"),
        7298698786,
    );
}
