// BuybackVault: TON in from splitters -> keeper-bounded buy of $DESK on its market -> keeper burn.
// The "$DESK" here is the launch world's coin (its RewardMaster + Curve/Pool).
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher/buyback-messages"
import "@contracts/launcher/buyback-types"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/BuybackVault.gen"
import "@wrappers/Curve.gen"
import "@wrappers/Pool.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"
import "@tests/launcher-fixtures"

struct BuybackWorld {
    l: LaunchWorld
    vault: BuybackVault
    admin: Treasury
    keeper: Treasury
    splitter: Treasury
}

const BB_RESERVE = ton("0.5")
const BB_MAX = ton("5")

fun setupBuyback(): BuybackWorld {
    val l = setupLaunch();
    openCurve(l);
    val admin = testing.treasury("b-admin");
    val keeper = testing.treasury("b-keeper");
    val splitter = testing.treasury("b-splitter");
    val vault = BuybackVault.fromStorage({
        reserve: BB_RESERVE,
        maxPerBuy: BB_MAX,
        pendingTimeout: 600,
        marketKind: MARKET_NONE,
        market: null,
        deskWallet: null,
        roles: BuybackRoles { admin: admin.address, keeper: keeper.address, deskMaster: l.r.master.address }.toCell(),
        stats: BuybackStats { totalTonIn: 0, totalTonSpent: 0, totalBurned: 0, burns: 0 }.toCell(),
        pending: null,
    });
    val res = vault.deploy(admin.address, { value: ton("0.6"), bounce: false });
    expect(res).toHaveSuccessfulDeploy({ to: vault.address });
    expect(res).toHaveSuccessfulTx<ResponseWalletAddress>({ from: l.r.master.address, to: vault.address });
    expect(vault.getBuybackData().deskWallet!).toEqual(l.r.master.getWalletAddress(vault.address));
    return { l, vault, admin, keeper, splitter };
}

fun fund(w: BuybackWorld, amount: coins) {
    expect(w.vault.sendBuybackIn(w.splitter.address, 0, { value: amount, bounce: true })).toHaveSuccessfulTx<BuybackIn>({ to: w.vault.address });
}

/// The vault learns its market from the $DESK master (F-03): `kind`/`market` are what we expect it to find.
fun setMarket(w: BuybackWorld, kind: int, market: address) {
    val res = w.vault.sendSyncBuybackMarket(w.admin.address, 0, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx<QueryMarket>({ from: w.vault.address, to: w.l.r.master.address });
    expect(res).toHaveSuccessfulTx<MarketAnswer>({ from: w.l.r.master.address, to: w.vault.address });
    expect(w.vault.getBuybackData().marketKind).toEqual(kind);
    expect(w.vault.getBuybackData().market!).toEqual(market);
}

fun deskBalance(w: BuybackWorld): int {
    return RewardWallet.fromAddress(w.l.r.master.getWalletAddress(w.vault.address)).getRewardWalletData().balance;
}

get fun `test buyback: TON in is accounted, keeper buy on the curve, keeper burn of what was bought`() {
    val w = setupBuyback();
    fund(w, ton("10"));
    expect(w.vault.getBuybackData().stats.totalTonIn).toEqual(ton("10"));
    setMarket(w, MARKET_CURVE, w.l.curve.address);

    val supplyBefore = w.l.r.master.getRewardMasterData().totalSupply;
    val soldBefore = w.l.curve.getCurveData().sold;
    val res = w.vault.sendBuybackBuy(w.keeper.address, 9, ton("3"), 1, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<BuybackBuy>({ to: w.vault.address });
    expect(res).toHaveSuccessfulTx<Buy>({ from: w.vault.address, to: w.l.curve.address });
    expect(res).toHaveSuccessfulTx<ReturnExcessesBack>({ from: w.l.curve.address, to: w.vault.address });

    var d = w.vault.getBuybackData();
    expect(d.pending == null).toBeTrue();
    expect(d.stats.totalTonSpent).toEqual(ton("3"));
    val minted = w.l.curve.getCurveData().sold - soldBefore;
    expect(minted > 0).toBeTrue();
    expect(deskBalance(w)).toEqual(minted);
    // the vault kept the rest of the income
    expect(testing.getAccountBalance(w.vault.address) > ton("6.5")).toBeTrue();

    // burn: everything bought leaves supply
    val burn = w.vault.sendBuybackBurn(w.keeper.address, 10, minted, { value: ton("0.2"), bounce: true });
    expect(burn).toHaveSuccessfulTx<AskToBurn>({ from: w.vault.address });
    expect(burn).toHaveSuccessfulTx<ReturnExcessesBack>({ to: w.vault.address });
    d = w.vault.getBuybackData();
    expect(d.pending == null).toBeTrue();
    expect(d.stats.burns).toEqual(1);
    expect(d.stats.totalBurned).toEqual(minted);
    expect(deskBalance(w)).toEqual(0);
    expect(w.l.r.master.getRewardMasterData().totalSupply).toEqual(supplyBefore);
}

get fun `test buyback: refused buy and refused burn leave the accounting untouched`() {
    val w = setupBuyback();
    fund(w, ton("10"));
    setMarket(w, MARKET_CURVE, w.l.curve.address);
    val before = testing.getAccountBalance(w.vault.address);

    // slippage: the curve bounces, the pending is dropped, the TON came back
    val res = w.vault.sendBuybackBuy(w.keeper.address, 9, ton("3"), 10000 * COIN, { value: ton("0.2"), bounce: true });
    expect(res).toHaveFailedTx<Buy>({ from: w.vault.address, to: w.l.curve.address, exitCode: Errors.SlippageExceeded });
    var d = w.vault.getBuybackData();
    expect(d.pending == null).toBeTrue();
    expect(d.stats.totalTonSpent).toEqual(0);
    expect(testing.getAccountBalance(w.vault.address) >= before).toBeTrue();

    // burning more than the wallet holds: the wallet bounces, stats are restored
    expect(w.vault.sendBuybackBuy(w.keeper.address, 10, ton("1"), 1, { value: ton("0.2"), bounce: true }))
        .toHaveSuccessfulTx<Buy>({ from: w.vault.address, to: w.l.curve.address });
    val held = deskBalance(w);
    expect(w.vault.sendBuybackBurn(w.keeper.address, 11, held + 1, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<AskToBurn>({ from: w.vault.address, exitCode: Errors.BudgetExceeded });
    d = w.vault.getBuybackData();
    expect(d.pending == null).toBeTrue();
    expect(d.stats.totalBurned).toEqual(0);
    expect(d.stats.burns).toEqual(0);
    expect(d.stats.totalTonSpent).toEqual(ton("1"));
    expect(deskBalance(w)).toEqual(held);

    // nothing pending -> cancel refused
    expect(w.vault.sendCancelBuyback(w.keeper.address, 0, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<CancelBuyback>({ to: w.vault.address, exitCode: Errors.NothingPending });
}

get fun `test buyback: guards — keeper only, bounds, market unset, no withdrawal path`() {
    val w = setupBuyback();
    fund(w, ton("4"));
    val stranger = testing.treasury("b-stranger");

    expect(w.vault.sendBuybackBuy(w.keeper.address, 1, ton("1"), 1, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<BuybackBuy>({ to: w.vault.address, exitCode: Errors.MarketUnset });
    expect(w.vault.sendSyncBuybackMarket(stranger.address, 0, { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<SyncBuybackMarket>({ to: w.vault.address, exitCode: Errors.NotFromAdmin });
    // nobody can name the market by hand: a forged answer from anyone but the master is refused
    expect(w.vault.sendMarketAnswer(stranger.address, 0, true, stranger.address, null, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<MarketAnswer>({ to: w.vault.address, exitCode: Errors.NotFromMaster });
    expect(w.vault.getBuybackData().marketKind).toEqual(MARKET_NONE);
    setMarket(w, MARKET_CURVE, w.l.curve.address);

    expect(w.vault.sendBuybackBuy(stranger.address, 1, ton("1"), 1, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<BuybackBuy>({ to: w.vault.address, exitCode: Errors.NotFromKeeper });
    expect(w.vault.sendBuybackBuy(w.keeper.address, 1, ton("6"), 1, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<BuybackBuy>({ to: w.vault.address, exitCode: Errors.BudgetExceeded });
    // income 4 TON + deploy 0.6 - reserve 0.5 : ~4.1 TON spendable at most; the keeper's own gas does not count
    expect(w.vault.sendBuybackBuy(w.keeper.address, 1, ton("4.5"), 1, { value: ton("2"), bounce: true }))
        .toHaveFailedTx<BuybackBuy>({ to: w.vault.address, exitCode: Errors.BudgetExceeded });
    expect(w.vault.sendBuybackBuy(w.keeper.address, 1, ton("1"), 0, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<BuybackBuy>({ to: w.vault.address, exitCode: Errors.InvalidParams });
    expect(w.vault.sendBuybackBuy(w.keeper.address, 1, ton("1"), 1, { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<BuybackBuy>({ to: w.vault.address, exitCode: Errors.InsufficientValue });
    expect(w.vault.sendBuybackBurn(stranger.address, 1, 1, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<BuybackBurn>({ to: w.vault.address, exitCode: Errors.NotFromKeeper });

    // a fake wallet notification is rejected
    expect(w.vault.sendTransferNotificationForRecipient(stranger.address, 0, 1000, stranger.address, PayloadInline { value: emptyForwardPayload() }, { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<TransferNotificationForRecipient>({ to: w.vault.address, exitCode: Errors.UnknownJettonWallet });

    // admin-only limits and roles
    expect(w.vault.sendSetBuybackLimits(stranger.address, 0, ton("1"), ton("1"), 60, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetBuybackLimits>({ to: w.vault.address, exitCode: Errors.NotFromAdmin });
    expect(w.vault.sendSetBuybackRoles(stranger.address, 0, stranger.address, stranger.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetBuybackRoles>({ to: w.vault.address, exitCode: Errors.NotFromAdmin });
    expect(w.vault.sendSetBuybackLimits(w.admin.address, 0, ton("1"), ton("2"), 60, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<SetBuybackLimits>({ to: w.vault.address });
    expect(w.vault.getBuybackData().maxPerBuy).toEqual(ton("2"));
    expect(w.vault.getBuybackData().stats.totalTonIn).toEqual(ton("4"));
}

get fun `test buyback: after graduation the pool is the market; buys are burned too`() {
    val w = setupBuyback();
    val whale = testing.treasury("b-whale");
    graduate(w.l, whale.address);
    val pool = poolOf(w.l);
    fund(w, ton("10"));
    setMarket(w, MARKET_POOL, pool.address);

    val supplyBefore = w.l.r.master.getRewardMasterData().totalSupply;
    val res = w.vault.sendBuybackBuy(w.keeper.address, 9, ton("4"), 1, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<SwapTonForCoin>({ from: w.vault.address, to: pool.address });
    expect(res).toHaveSuccessfulTx<ReturnExcessesBack>({ from: pool.address, to: w.vault.address });
    var d = w.vault.getBuybackData();
    expect(d.pending == null).toBeTrue();
    expect(d.stats.totalTonSpent).toEqual(ton("4"));
    val got = deskBalance(w);
    expect(got > 0).toBeTrue();

    expect(w.vault.sendBuybackBurn(w.keeper.address, 10, got, { value: ton("0.2"), bounce: true }))
        .toHaveSuccessfulTx<AskToBurn>({ from: w.vault.address });
    d = w.vault.getBuybackData();
    expect(d.pending == null).toBeTrue();
    expect(d.stats.totalBurned).toEqual(got);
    expect(deskBalance(w)).toEqual(0);
    // the pool's coins left the pool and were burned: supply shrank
    expect(w.l.r.master.getRewardMasterData().totalSupply).toEqual(supplyBefore - got);
}
