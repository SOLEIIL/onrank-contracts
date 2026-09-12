import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/Curve.gen"
import "@wrappers/FeeSplitter.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pool.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"
import "@tests/launcher-fixtures"

// ---------------------------------------------------------------------------
// Curve
// ---------------------------------------------------------------------------

get fun `test curve: closed until the factory opens it`() {
    val w = setupLaunch();
    val a = testing.treasury("a");
    expect(buy(w, a.address, ton("1.15"))).toHaveFailedTx<Buy>({ to: w.curve.address, exitCode: Errors.CurveNotOpen });
    expect(w.curve.sendOpenCurve(a.address, 0, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<OpenCurve>({ to: w.curve.address, exitCode: Errors.NotFromFactory });
    openCurve(w);
    expect(w.curve.getCurveData().state).toEqual(CURVE_OPEN);
    expect(w.curve.sendOpenCurve(w.r.factory.address, 0, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<OpenCurve>({ to: w.curve.address, exitCode: Errors.AlreadyWired });
}

get fun `test curve: buy mints along x·y=k, fee goes to the splitter, excess returned`() {
    val w = setupLaunch();
    openCurve(w);
    val a = testing.treasury("a");
    val quote = w.curve.getBuyQuote(ton("10.15"));
    val expectedOut = (V_TOKEN0 * ton("9.9")) / (V_TON0 + ton("9.9"));
    expect(quote.amountOut).toEqual(expectedOut);
    expect(quote.fee).toEqual(ton("0.1"));

    val a0 = testing.getAccountBalance(a.address);
    val res = buy(w, a.address, ton("10.15"));
    expect(res).toHaveSuccessfulTx<Buy>({ from: a.address, to: w.curve.address });
    expect(res).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.r.master.address });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({ from: w.r.master.address, to: coinWallet(w.r, a.address).address });
    expect(res).toHaveTx<FeeIn>({ from: w.curve.address, to: w.splitter.address, value: ton("0.13") });
    expect(res).toHaveTx<RewardIn>({ from: w.splitter.address, to: w.r.vault.address, value: ton("0.07") });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: w.curve.address, to: a.address });

    expect(coinBalance(w.r, a.address)).toEqual(expectedOut);
    expect(w.r.master.getJettonData().totalSupply).toEqual(expectedOut);
    val d = w.curve.getCurveData();
    expect(d.realTon).toEqual(ton("9.9"));
    expect(d.sold).toEqual(expectedOut);
    expect(d.virtualTon).toEqual(V_TON0 + ton("9.9"));
    expect(d.virtualToken).toEqual(V_TOKEN0 - expectedOut);
    // the curve holds at least the TON it collected
    expect(testing.getAccountBalance(w.curve.address) >= d.realTon).toBeTrue();
    // the buyer gets the unused gas back (treasuries do not debit sends, so only credits are measurable)
    expect(testing.getAccountBalance(a.address) - a0 > ton("0.01")).toBeTrue();
    val ev = findEvent<CurveTradeEvent>(res, w.curve.address, EVENT_TOPIC_CURVE_TRADE);
    expect(ev!.isBuy).toBeTrue();
    expect(ev!.coin).toEqual(expectedOut);
}

get fun `test curve: buy guards — min buy, slippage, recipient override`() {
    val w = setupLaunch();
    openCurve(w);
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    expect(buy(w, a.address, ton("0.2"))).toHaveFailedTx<Buy>({ to: w.curve.address, exitCode: Errors.BelowMinTrade });
    expect(buy(w, a.address, ton("0.1"))).toHaveFailedTx<Buy>({ to: w.curve.address, exitCode: Errors.InsufficientValue });
    expect(buy(w, a.address, ton("1.15"), 1000 * COIN)).toHaveFailedTx<Buy>({ to: w.curve.address, exitCode: Errors.SlippageExceeded });
    expect(w.curve.getCurveData().sold).toEqual(0);
    expect(w.r.master.getJettonData().totalSupply).toEqual(0);

    val quote = w.curve.getBuyQuote(ton("1.15")).amountOut;
    expect(buy(w, a.address, ton("1.15"), quote, b.address)).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
    expect(coinBalance(w.r, b.address)).toEqual(quote);
}

get fun `test curve: sell burns through the master and pays TON minus fee; refused sells re-mint`() {
    val w = setupLaunch();
    openCurve(w);
    val a = testing.treasury("a");
    buy(w, a.address, ton("10.15"));
    val held = coinBalance(w.r, a.address);
    val before = w.curve.getCurveData();

    val amount = held / 2;
    val quote = w.curve.getSellQuote(amount);
    val gross = (before.virtualTon * amount) / (before.virtualToken + amount);
    expect(quote.amountOut).toEqual(gross - gross / 100);

    val a0 = testing.getAccountBalance(a.address);
    val res = sell(w, a.address, amount, quote.amountOut);
    expect(res).toHaveSuccessfulTx<Settle>({ to: w.r.master.address });
    expect(res).toHaveSuccessfulTx<SellNotify>({ from: w.r.master.address, to: w.curve.address });
    expect(res).toHaveTx<FeeIn>({ from: w.curve.address, to: w.splitter.address, value: gross / 100 + ton("0.03") });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: w.curve.address, to: a.address });
    // credits = net payout + returned gas (treasuries do not debit their sends)
    val received = testing.getAccountBalance(a.address) - a0;
    expect(received > quote.amountOut).toBeTrue();
    expect(received < quote.amountOut + ton("0.25")).toBeTrue();
    expect(res).toHaveTx({ from: w.curve.address, to: a.address });

    expect(coinBalance(w.r, a.address)).toEqual(held - amount);
    expect(w.r.master.getJettonData().totalSupply).toEqual(held - amount);
    val after = w.curve.getCurveData();
    expect(after.realTon).toEqual(before.realTon - gross);
    expect(after.sold).toEqual(before.sold - amount);
    expect(after.virtualTon).toEqual(before.virtualTon - gross);
    expect(after.virtualToken).toEqual(before.virtualToken + amount);
    expect(testing.getAccountBalance(w.curve.address) >= after.realTon).toBeTrue();

    // minTon too high: the curve mints the coins back, nothing else moves
    val refused = sell(w, a.address, amount, ton("100"));
    expect(refused).toHaveSuccessfulTx<SellNotify>({ to: w.curve.address });
    expect(refused).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.r.master.address });
    expect(coinBalance(w.r, a.address)).toEqual(held - amount);
    expect(w.r.master.getJettonData().totalSupply).toEqual(held - amount);
    expect(w.curve.getCurveData().realTon).toEqual(after.realTon);
    expect(coinWallet(w.r, a.address).getRewardWalletData().busy).toBeFalse();
}

get fun `test curve: graduation deploys the pool once, funds it, closes the curve`() {
    val w = setupLaunch();
    openCurve(w);
    val whale = testing.treasury("whale");
    val p0 = testing.getAccountBalance(w.protocol.address);
    val res = graduate(w, whale.address);

    val d = w.curve.getCurveData();
    expect(d.pool).toBeNotNull();
    expect(d.realTon).toEqual(0);
    val pool = poolOf(w);
    expect(res).toHaveSuccessfulDeploy({ from: w.curve.address, to: pool.address });
    expect(res).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.r.master.address });
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: pool.address });
    expect(res).toHaveSuccessfulTx<ExcludedUpdate>({ from: pool.address, to: w.r.master.address });
    expect(res).toHaveSuccessfulTx<CurveGraduated>({ from: w.curve.address, to: w.r.master.address });
    val ev = findEvent<CurveGraduatedEvent>(res, w.curve.address, EVENT_TOPIC_CURVE_GRADUATED);
    expect(ev).toBeNotNull();
    expect(ev!.liquidityCoin).toEqual(POOL_SUPPLY);
    expect(ev!.protocolFee).toEqual(GRADUATION_FEE - ton("0.3"));

    val pd = pool.getPoolData();
    expect(pd.reserveCoin).toEqual(POOL_SUPPLY);
    expect(pd.reserveTon).toEqual(ev!.liquidityTon);
    expect(pd.reserveTon >= GRADUATION_TON - GRADUATION_FEE).toBeTrue();
    expect(testing.getAccountBalance(pool.address) >= pd.reserveTon).toBeTrue();
    expect(coinBalance(w.r, pool.address)).toEqual(POOL_SUPPLY);
    // protocol received the graduation fee minus gas
    expect(testing.getAccountBalance(w.protocol.address) - p0 > ton("0.69")).toBeTrue();

    val md = w.r.master.getRewardMasterData();
    expect(md.curveOpen).toBeFalse();
    expect(md.pool!).toEqual(pool.address);
    expect(md.excluded).toEqual(POOL_SUPPLY);
    expect(md.totalSupply).toEqual(d.sold + POOL_SUPPLY);
    // the curve keeps only what it had before the first buy (deploy + open gas), nothing collected
    expect(testing.getAccountBalance(w.curve.address) < ton("0.3")).toBeTrue();

    expect(buy(w, whale.address, ton("1.15"))).toHaveFailedTx<Buy>({ to: w.curve.address, exitCode: Errors.CurveNotOpen });
    expect(sell(w, whale.address, COIN, 0)).toHaveFailedTx<Settle>({ to: w.r.master.address, exitCode: Errors.CurveClosed });
}

// ---------------------------------------------------------------------------
// Pool
// ---------------------------------------------------------------------------

get fun `test pool: TON->coin swap, fees split between locked LP and splitter, excluded updated`() {
    val w = setupLaunch();
    openCurve(w);
    val whale = testing.treasury("whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val before = pool.getPoolData();
    val a = testing.treasury("a");

    val quote = pool.getBuyQuote(ton("1"));
    val net = ton("0.98");
    expect(quote.amountOut).toEqual((before.reserveCoin * net) / (before.reserveTon + net));
    expect(quote.fee).toEqual(ton("0.02"));

    expect(poolBuy(w, a.address, ton("1.2"), quote.amountOut + 1)).toHaveFailedTx<SwapTonForCoin>({ to: pool.address, exitCode: Errors.SlippageExceeded });

    val a0 = testing.getAccountBalance(a.address);
    val res = poolBuy(w, a.address, ton("1.2"), quote.amountOut);
    expect(res).toHaveSuccessfulTx<SwapTonForCoin>({ from: a.address, to: pool.address });
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: pool.address, to: before.coinWallet });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({ from: before.coinWallet, to: coinWallet(w.r, a.address).address });
    expect(res).toHaveTx<FeeIn>({ from: pool.address, to: w.splitter.address, value: ton("0.04") });
    expect(res).toHaveSuccessfulTx<ExcludedUpdate>({ from: pool.address, to: w.r.master.address });
    expect(coinBalance(w.r, a.address)).toEqual(quote.amountOut);

    val after = pool.getPoolData();
    expect(after.reserveCoin).toEqual(before.reserveCoin - quote.amountOut);
    expect(after.reserveTon).toEqual(before.reserveTon + ton("0.99"));
    expect(after.volumeTon).toEqual(ton("1"));
    expect(testing.getAccountBalance(pool.address) >= after.reserveTon).toBeTrue();
    expect(coinBalance(w.r, pool.address)).toEqual(after.reserveCoin);
    expect(w.r.master.getRewardMasterData().excluded).toEqual(after.reserveCoin);
    expect(testing.getAccountBalance(a.address) - a0 > 0).toBeTrue();
}

get fun `test pool: coin->TON swap pays net TON; bad payload or slippage refunds the coins`() {
    val w = setupLaunch();
    openCurve(w);
    val whale = testing.treasury("whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val a = testing.treasury("a");
    poolBuy(w, a.address, ton("5.2"));
    val held = coinBalance(w.r, a.address);
    val before = pool.getPoolData();

    val amount = held / 2;
    val quote = pool.getSellQuote(amount);
    val gross = (before.reserveTon * amount) / (before.reserveCoin + amount);
    expect(quote.amountOut).toEqual(gross - gross / 100 - gross / 100);

    // slippage: refunded
    val refused = poolSell(w, a.address, amount, quote.amountOut + 1);
    expect(refused).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: pool.address });
    expect(refused).toHaveSuccessfulTx<AskToTransfer>({ from: pool.address, to: before.coinWallet });
    expect(coinBalance(w.r, a.address)).toEqual(held);
    expect(pool.getPoolData().reserveCoin).toEqual(before.reserveCoin);

    // plain transfer without swap payload: refunded too
    val plain = coinWallet(w.r, a.address).sendTransfer(a.address, ton("0.3"), amount, pool.address, a.address, null, ton("0.12"), null);
    expect(plain).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: pool.address });
    expect(coinBalance(w.r, a.address)).toEqual(held);

    val a0 = testing.getAccountBalance(a.address);
    val res = poolSell(w, a.address, amount, quote.amountOut);
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: pool.address });
    expect(res).toHaveTx<FeeIn>({ from: pool.address, to: w.splitter.address, value: gross / 100 + ton("0.03") });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: pool.address, to: a.address });
    expect(res).toHaveSuccessfulTx<ExcludedUpdate>({ from: pool.address, to: w.r.master.address });
    val received = testing.getAccountBalance(a.address) - a0;
    expect(received > quote.amountOut).toBeTrue();
    expect(received < quote.amountOut + ton("0.3")).toBeTrue();

    val after = pool.getPoolData();
    expect(after.reserveCoin).toEqual(before.reserveCoin + amount);
    expect(after.reserveTon).toEqual(before.reserveTon - quote.amountOut - gross / 100);
    expect(coinBalance(w.r, a.address)).toEqual(held - amount);
    expect(coinBalance(w.r, pool.address)).toEqual(after.reserveCoin);
    expect(w.r.master.getRewardMasterData().excluded).toEqual(after.reserveCoin);
    expect(testing.getAccountBalance(pool.address) >= after.reserveTon).toBeTrue();
    val ev = findEvent<PoolSwapEvent>(res, pool.address, EVENT_TOPIC_POOL_SWAP);
    expect(ev!.isBuy).toBeFalse();
    expect(ev!.coin).toEqual(amount);
}

get fun `test pool: rewards after graduation exclude the pool's coins`() {
    val w = setupLaunch();
    openCurve(w);
    val whale = testing.treasury("whale");
    graduate(w, whale.address);
    val held = coinBalance(w.r, whale.address);
    val res = arriveReward(w.r, 0, 100 * REWARD_UNIT);
    val ev = findEvent<IndexBumpedEvent>(res, w.r.master.address, EVENT_TOPIC_INDEX_BUMPED);
    expect(ev!.circulating).toEqual(held);
    expect(claimable(w.r, whale.address, 0)).toEqual(100 * REWARD_UNIT);
    claim(w.r, whale.address);
    expect(rewardBalance(w.r, 0, whale.address)).toEqual(100 * REWARD_UNIT);
}

// ---------------------------------------------------------------------------
// Fuzz: curve invariants under random buys and sells
// ---------------------------------------------------------------------------

@test.fuzz(12)
get fun `test curve: fuzz — k never decreases, supply == sold, balance covers realTon`(b1: int, b2: int, s1: int, b3: int) {
    val v1 = fuzz.bound(b1, 1, 30) * ton("1") + ton("0.15");
    val v2 = fuzz.bound(b2, 1, 30) * ton("1") + ton("0.15");
    val sellPct = fuzz.bound(s1, 0, 100);
    val v3 = fuzz.bound(b3, 1, 30) * ton("1") + ton("0.15");

    val w = setupLaunch();
    openCurve(w);
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val k0 = V_TON0 * V_TOKEN0;
    var netIn: int = 0;
    var grossOut: int = 0;

    var r = buy(w, a.address, v1);
    var ev = findEvent<CurveTradeEvent>(r, w.curve.address, EVENT_TOPIC_CURVE_TRADE);
    netIn += ev!.ton;
    if (w.curve.getCurveData().state == CURVE_OPEN) {
        r = buy(w, b.address, v2);
        ev = findEvent<CurveTradeEvent>(r, w.curve.address, EVENT_TOPIC_CURVE_TRADE);
        netIn += ev!.ton;
    }
    if (w.curve.getCurveData().state == CURVE_OPEN && sellPct > 0) {
        val amount = (coinBalance(w.r, a.address) * sellPct) / 100;
        if (amount > 0) {
            r = sell(w, a.address, amount, 0);
            ev = findEvent<CurveTradeEvent>(r, w.curve.address, EVENT_TOPIC_CURVE_TRADE);
            if (ev != null) {
                grossOut += ev!.ton + ev!.fee;
            }
        }
    }
    if (w.curve.getCurveData().state == CURVE_OPEN) {
        r = buy(w, b.address, v3);
        ev = findEvent<CurveTradeEvent>(r, w.curve.address, EVENT_TOPIC_CURVE_TRADE);
        netIn += ev!.ton;
    }

    val d = w.curve.getCurveData();
    expect(d.virtualTon * d.virtualToken >= k0).toBeTrue();
    expect(d.sold <= CURVE_SUPPLY).toBeTrue();
    val supply = w.r.master.getJettonData().totalSupply;
    if (d.state == CURVE_OPEN) {
        expect(supply).toEqual(d.sold);
        expect(d.realTon).toEqual(netIn - grossOut);
        expect(testing.getAccountBalance(w.curve.address) >= d.realTon).toBeTrue();
    } else {
        expect(supply).toEqual(d.sold + POOL_SUPPLY);
        expect(d.realTon).toEqual(0);
        val pd = poolOf(w).getPoolData();
        expect(pd.reserveCoin).toEqual(POOL_SUPPLY);
        expect(pd.reserveTon).toEqual(netIn - grossOut - GRADUATION_FEE);
    }
}
