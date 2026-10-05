// One user sell into the DeDust pool. The forward body is PayJetton, so the pool
// pays GRAM and keeps the jettons. The curve buy already delivered the jettons.
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"

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

fun vmExit(tx: TlbTransaction): int {
    val description = tx.description.load();
    if (description is TlbTransOrd && description.computePh is TlbTrComputeVm) {
        return description.computePh.data.load().exitCode;
    }
    return -1;
}

fun askSell(owner: address, wallet: address, recipient: address, amount: coins): SendResultList {
    val swap = DedustSwap {
        minimalAmountOut: 1,
        deadline: 1800003600,
        next: null,
        partnerConfig: null,
        referrerConfig: null,
    }.toCell();
    // The pool reads PayJetton (0xcbc33949) inside the transfer notification.
    // A bare Swap payload makes it reject the jettons and try to send them back.
    val payload = beginCell()
        .storeUint(0xcbc33949, 32)
        .storeRef(swap)
        .storeRef(dedustPayout(owner))
        .endCell();
    return net.send(
        owner,
        createMessage({
            bounce: true,
            value: ton("0.3"),
            dest: wallet,
            body: AskToTransfer {
                queryId: 40,
                jettonAmount: amount,
                transferRecipient: recipient,
                sendExcessesTo: owner,
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
}

get fun `test dedust sell: the buyer sends jettons and GRAM comes back`() {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("sell-admin");
    val protocol = testing.treasury("sell-protocol");
    val vault = testing.treasury("sell-vault");
    val pot = testing.treasury("sell-pot");
    val buyback = testing.treasury("sell-buyback");
    val buyer = testing.treasury("sell-buyer");
    val keeper = testing.treasury("sell-keeper");
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
    expect(launched).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
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
    val bought = curve.sendBuy(buyer.address, 3, 0, null, { value: ton("1700"), bounce: true });
    expect(bought).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
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
    val wallet = RewardWalletDex.fromAddress(
        RewardMasterDex.fromAddress(master).getWalletAddress(buyer.address),
    );
    val held = wallet.getRewardWalletData().balance;
    expect(held > ton("1")).toBeTrue();
    val amount = 1000000 * ton("1");
    val before = testing.getAccountBalance(buyer.address);
    val poolTonBefore = testing.getAccountBalance(pool);
    val poolJet = RewardWalletDex.fromAddress(
        RewardMasterDex.fromAddress(master).getWalletAddress(pool),
    );
    val poolJetBefore = poolJet.getRewardWalletData().balance;
    val jetBefore = wallet.getRewardWalletData().balance;
    val sold = askSell(buyer.address, wallet.address, pool, amount);
    expect(vmExit(sold.at(0).tx.load()) == 0).toBeTrue();
    expect(wallet.getRewardWalletData().balance).toEqual(jetBefore - amount);
    expect(poolJet.getRewardWalletData().balance - poolJetBefore).toEqual(amount);
    val poolTonDelta = testing.getAccountBalance(pool) - poolTonBefore;
    val gained = testing.getAccountBalance(buyer.address) - before;
    expect(poolTonDelta < -ton("1")).toBeTrue();
    expect(gained > ton("1")).toBeTrue();
}
