// End to end: $DESK launched by the Factory (split pot/protocol), a regular coin launched next,
// its creator fees flow 70/15/10/5, the 5 % reach the BuybackVault which buys $DESK on its curve
// and burns it.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher/buyback-messages"
import "@contracts/launcher/buyback-types"
import "@contracts/launcher/factory-messages"
import "@contracts/launcher/factory-types"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/fee-splitter-types"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/pot/pot-messages"
import "@contracts/vendor/jetton/messages"
import "@wrappers/BuybackVault.gen"
import "@wrappers/Curve.gen"
import "@wrappers/Factory.gen"
import "@wrappers/FeeSplitter.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"
import "@tests/launcher-fixtures"
import "@tests/factory-fixtures"

get fun `test e2e: coin fees -> splitter -> BuybackVault -> buy $DESK on its curve -> burn`() {
    val w = setupFactory();
    val none: map<uint8, address> = createEmptyMap();
    val deskMeta = jettonMetadata("DESK");
    val deskSplits: FeeSplits = { holdersBps: 0, protocolBps: 5000, potBps: 5000, buybackBps: 0 };

    // 1. the BuybackVault is deployed against the (predictable) $DESK master, then routed in the Factory
    // (the master address only depends on the factory, seq and metadata — not on the routes)
    val deskMaster = RewardMaster.fromAddress(w.factory.getLaunchAddresses(0, deskMeta, none, deskSplits.toCell()).master);
    val bb = BuybackVault.fromStorage({
        reserve: ton("0.3"),
        maxPerBuy: ton("50"),
        pendingTimeout: 600,
        marketKind: MARKET_NONE,
        market: null,
        deskWallet: null,
        roles: BuybackRoles { admin: w.admin.address, keeper: w.keeper.address, deskMaster: deskMaster.address }.toCell(),
        stats: BuybackStats { totalTonIn: 0, totalTonSpent: 0, totalBurned: 0, burns: 0 }.toCell(),
        pending: null,
    });
    // the master does not exist yet: discovery bounces, the vault retries at the next top-up
    expect(bb.deploy(w.admin.address, { value: ton("0.5"), bounce: false })).toHaveSuccessfulDeploy({ to: bb.address });
    expect(bb.getBuybackData().deskWallet == null).toBeTrue();
    expect(w.factory.sendSetFactoryRoles(w.admin.address, 0,
        FactoryRoles { admin: w.admin.address, keeper: w.keeper.address, protocol: w.protocol.address },
        FactoryRoutes { pot: w.pot.address, buyback: bb.address },
        { value: ton("0.05"), bounce: true })).toHaveSuccessfulTx<SetFactoryRoles>({ to: w.factory.address });
    // the splitter (hence the curve) depends on the routes: compute the rest once routed
    val deskAddrs = w.factory.getLaunchAddresses(0, deskMeta, none, deskSplits.toCell());
    expect(deskAddrs.master).toEqual(deskMaster.address);
    val deskCurve = Curve.fromAddress(deskAddrs.more.load().curve);

    // 2. $DESK launch (admin, split pot/protocol, first buy 20 TON)
    expect(w.factory.sendCreateLaunch(w.admin.address, 1, deskMeta, none, ton("20"), deskSplits, { value: LAUNCH_FEE + ton("21"), bounce: true }))
        .toHaveSuccessfulTx<Buy>({ to: deskCurve.address });
    expect(deskMaster.getRewardMasterData().totalSupply > 0).toBeTrue();
    // the vault discovers its $DESK wallet now that the master exists
    val res = bb.sendTopUpTons(w.admin.address, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx<ResponseWalletAddress>({ from: deskMaster.address, to: bb.address });
    expect(bb.getBuybackData().deskWallet!).toEqual(deskMaster.getWalletAddress(bb.address));
    // ... and learns its market from the master itself (the curve, while it is open)
    val sync = bb.sendSyncBuybackMarket(w.admin.address, 0, { value: ton("0.1"), bounce: true });
    expect(sync).toHaveSuccessfulTx<MarketAnswer>({ from: deskMaster.address, to: bb.address });
    expect(bb.getBuybackData().marketKind).toEqual(MARKET_CURVE);
    expect(bb.getBuybackData().market!).toEqual(deskCurve.address);

    // 3. a regular coin, launched by a creator, traded by a buyer
    val coinMeta = jettonMetadata("PEPE");
    val coin = launched(w, 1, coinMeta, rewardsOf(w.reward0.address));
    expect(w.factory.sendCreateLaunch(w.creator.address, 2, coinMeta, rewardsOf(w.reward0.address), ton("5"), null, { value: LAUNCH_FEE + ton("6"), bounce: true }))
        .toHaveSuccessfulTx<Buy>({ to: coin.curve.address });
    val buyer = testing.treasury("e2e-buyer");
    val potBefore = testing.getAccountBalance(w.pot.address);
    val trade = coin.curve.sendBuy(buyer.address, 3, 0, null, { value: ton("10.15"), bounce: true });
    expect(trade).toHaveSuccessfulTx<Buy>({ to: coin.curve.address });
    expect(trade).toHaveSuccessfulTx<FeeIn>({ from: coin.curve.address, to: coin.splitter.address });
    expect(trade).toHaveSuccessfulTx<BuybackIn>({ from: coin.splitter.address, to: bb.address });
    expect(trade).toHaveSuccessfulTx<RewardIn>({ from: coin.splitter.address, to: coin.vault.address });
    expect(trade).toHaveSuccessfulTx<PotTopUp>({ from: coin.splitter.address, to: w.pot.address });
    val fee = ton("10") / 100;
    expect(trade).toHaveTx({ from: coin.splitter.address, to: bb.address, value: fee * 5 / 100 });
    expect(testing.getAccountBalance(w.pot.address) - potBefore > fee * 10 / 100 - ton("0.005")).toBeTrue();

    // the buyback vault accounts every BuybackIn (first buys of both launches went through splitters too)
    val bd = bb.getBuybackData();
    val coinFirstBuyFee = ton("5") / 100;
    expect(bd.stats.totalTonIn).toEqual((fee + coinFirstBuyFee) * 5 / 100);

    // 4. keeper: buy $DESK on its curve with what came in, then burn it
    val supplyBefore = deskMaster.getRewardMasterData().totalSupply;
    val spend = bd.stats.totalTonIn;
    // the vault must be funded above its reserve for the buy to be allowed: top it up like months of fees would
    expect(bb.sendBuybackIn(w.creator.address, 0, { value: ton("3"), bounce: true })).toHaveSuccessfulTx<BuybackIn>({ to: bb.address });
    val buyRes = bb.sendBuybackBuy(w.keeper.address, 9, spend + ton("3"), 1, { value: ton("0.2"), bounce: true });
    expect(buyRes).toHaveSuccessfulTx<Buy>({ from: bb.address, to: deskCurve.address });
    expect(buyRes).toHaveSuccessfulTx<ReturnExcessesBack>({ from: deskCurve.address, to: bb.address });
    // buying $DESK pays the $DESK curve fee: half to the pot, half to the protocol, nothing back to the vault
    expect(buyRes).toHaveSuccessfulTx<FeeIn>({ from: deskCurve.address, to: FeeSplitter.fromAddress(deskAddrs.more.load().splitter).address });
    val got = RewardWallet.fromAddress(deskMaster.getWalletAddress(bb.address)).getRewardWalletData().balance;
    expect(got > 0).toBeTrue();
    expect(deskMaster.getRewardMasterData().totalSupply).toEqual(supplyBefore + got);

    expect(bb.sendBuybackBurn(w.keeper.address, 10, got, { value: ton("0.2"), bounce: true }))
        .toHaveSuccessfulTx<AskToBurn>({ from: bb.address });
    expect(deskMaster.getRewardMasterData().totalSupply).toEqual(supplyBefore);
    val after = bb.getBuybackData();
    expect(after.stats.totalTonSpent).toEqual(spend + ton("3"));
    expect(after.stats.totalBurned).toEqual(got);
    expect(after.stats.burns).toEqual(1);
    expect(after.pending == null).toBeTrue();
}
