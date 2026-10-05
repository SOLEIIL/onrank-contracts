// The whole life of a FactoryDexTest2 coin, with the REAL contracts at every step (factory, CurveDex2,
// real DeDust libraries) and no impersonation: curve buy with its fee split, curve sell, graduation
// through the keeper's relay, post-graduation sell AND buy on the DeDust pool, the creator fee
// accruing, and a holder dividend the pool is excluded from. The zero-loss audit's backbone.
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CurveDex2.gen"
import "@wrappers/FactoryDexTest2.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/GasStation.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/launcher-dex/CurveDex2"
import "@contracts/launcher-dex/FactoryDexTest2"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/dividend-messages"
import "@contracts/launcher-dex/reward-types"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"
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

fun vmExit(tx: TlbTransaction): int {
    val description = tx.description.load();
    if (description is TlbTransOrd && description.computePh is TlbTrComputeVm) {
        return description.computePh.data.load().exitCode;
    }
    return -1;
}

fun askSell(owner: address, wallet: address, pool: address, amount: coins): SendResultList {
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
                transferRecipient: pool,
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

get fun `test dedust lifecycle: launch, curve trades, relayed graduation, pool trades, fees, dividends`() {
    loadDedustLibraries();
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("life-admin");
    val protocol = testing.treasury("life-protocol");
    val vault = testing.treasury("life-vault");
    val pot = testing.treasury("life-pot");
    val buyback = testing.treasury("life-buyback");
    val holder = testing.treasury("life-holder");
    val whale = testing.treasury("life-whale");
    val keeper = testing.treasury("life-keeper");
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

    // 1. launch: children deployed and wired by the real factory
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
    ).toHaveSuccessfulTx<OpenCurve>({ to: factory.getFactoryDexData().lastCurve! });
    val curve = CurveDex2.fromAddress(factory.getFactoryDexData().lastCurve!);
    val masterAddr = factory.getFactoryDexData().lastMaster!;
    val master = RewardMasterDex.fromAddress(masterAddr);
    val splitter = FeeSplitterV2.fromAddress(factory.getFactoryDexData().lastSplitter!);
    val creator = factory.getFactoryDexData().lastCreator!;
    val pool = calcDedustPool(masterAddr, creator).calculateAddress();
    expect(curve.getCurveData().state).toEqual(CURVE_OPEN);

    // 2. a curve buy pays the 1% fee into the splitter and mints to the holder
    val bought = curve.sendBuy(holder.address, 3, 0, null, { value: ton("2"), bounce: true });
    expect(bought).toHaveSuccessfulTx<Buy>({ to: curve.address });
    expect(bought).toHaveSuccessfulTx<FeeIn>({ from: curve.address, to: splitter.address });
    val holderWallet = RewardWalletDex.fromAddress(master.getWalletAddress(holder.address));
    val heldAfterBuy = holderWallet.getRewardWalletData().balance;
    expect(heldAfterBuy > 0).toBeTrue();
    expect(splitter.getSplitterData().totalIn > 0).toBeTrue();

    // 3. a curve sell burns the coins and pays GRAM back, fee split again
    val realBefore = curve.getCurveData().realTon;
    val tonBefore = testing.getAccountBalance(holder.address);
    val sold = holderWallet.sendAskToBurn(
        holder.address,
        0,
        heldAfterBuy / 2,
        holder.address,
        SellIntent { minTon: 0 }.toCell(),
        { value: ton("0.2"), bounce: true },
    );
    expect(sold).toHaveSuccessfulTx<SellNotify>({ from: masterAddr, to: curve.address });
    expect(holderWallet.getRewardWalletData().balance).toEqual(heldAfterBuy - heldAfterBuy / 2);
    expect(curve.getCurveData().realTon < realBefore).toBeTrue();
    expect(testing.getAccountBalance(holder.address) > tonBefore).toBeTrue();

    // 4. the pool is excluded from dividends before it exists
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
    ).toHaveSuccessfulTx<SetDividendExcluded>({ from: curve.address, to: masterAddr });

    // 5. the graduating buy sends the deposit: state 4, liquidity on the pool, nothing confirmed yet
    val protocolBefore = testing.getAccountBalance(protocol.address);
    val graduating = curve.sendBuy(whale.address, 5, 0, null, { value: ton("12"), bounce: true });
    expect(graduating).toHaveSuccessfulTx<DedustInit>({ from: curve.address, to: pool });
    expect(graduating).toHaveSuccessfulTx<DedustPayNative>({ from: curve.address, to: pool });
    expect(curve.getCurveData().state).toEqual(CURVE_DEDUST_SENT);
    // the graduation fee's remainder went to the protocol (1.5 - 1.1 gas = 0.4)
    val protocolGained = testing.getAccountBalance(protocol.address) - protocolBefore;
    expect(protocolGained >= ton("0.39") && protocolGained <= ton("0.4")).toBeTrue();

    // 6. the keeper's relay finalizes: state 2, the curve books nothing anymore
    expect(
        factory.sendRelayConfirmDedust(
            keeper.address,
            9,
            curve.address,
            { value: RELAY_CONFIRM_GAS, bounce: true },
        ),
    ).toHaveSuccessfulTx<DedustPositionState>({ to: curve.address });
    expect(curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    expect(curve.getCurveData().realTon).toEqual(0);

    // 7. post-graduation sell on the pool: jettons in, GRAM back to the seller
    val whaleWallet = RewardWalletDex.fromAddress(master.getWalletAddress(whale.address));
    val whaleJets = whaleWallet.getRewardWalletData().balance;
    expect(whaleJets > 0).toBeTrue();
    val lot = whaleJets / 10;
    val whaleTonBefore = testing.getAccountBalance(whale.address);
    val poolSold = askSell(whale.address, whaleWallet.address, pool, lot);
    expect(vmExit(poolSold.at(0).tx.load()) == 0).toBeTrue();
    expect(whaleWallet.getRewardWalletData().balance).toEqual(whaleJets - lot);
    expect(testing.getAccountBalance(whale.address) > whaleTonBefore).toBeTrue();

    // 8. post-graduation buy on the pool: GRAM in, jettons back to the buyer
    val holderJetsBefore = holderWallet.getRewardWalletData().balance;
    val poolBought = net.send(
        holder.address,
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
                payoutConfig: dedustPayout(holder.address),
            },
        }),
    );
    expect(poolBought).toHaveSuccessfulTx<DedustPayNative>({ to: pool });
    expect(holderWallet.getRewardWalletData().balance > holderJetsBefore).toBeTrue();

    // 9. the two swaps accrued a creator fee in GRAM on the pool (claimed by the keeper's CreatorFee pass)
    val seen = net.runGetMethod<SeenPool>(pool, "get_pool_data");
    expect(seen.creatorFeeX > 0).toBeTrue();
    expect(seen.creatorFeeY).toEqual(0);

    // 10. a dividend bump: the holder earns, the pool's 200M stack earns nothing
    val poolWallet = RewardWalletDex.fromAddress(master.getWalletAddress(pool));
    expect(
        net.send(
            vault.address,
            createMessage({
                bounce: true,
                value: ton("0.05"),
                dest: masterAddr,
                body: IndexBump {
                    queryId: 12,
                    rewardId: 0,
                    amount: 100000000,
                },
            }),
        ),
    ).toHaveSuccessfulTx<IndexBump>({ to: masterAddr });
    val indices = master.getRewardMasterData().indices;
    val holderDue = amountOf(holderWallet.getClaimable(indices), 0);
    val poolDue = amountOf(poolWallet.getClaimable(indices), 0);
    expect(holderDue > 0).toBeTrue();
    expect(poolDue).toEqual(0);
}
