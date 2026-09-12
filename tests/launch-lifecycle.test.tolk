// Whole-launch fuzz: random buys / sells / reward arrivals / claims across curve and pool.
// Invariants checked after every step:
//   - master.totalSupply == Σ holder balances (+ pool reserve once graduated)
//   - pool: k never decreases, reserveCoin == the pool's wallet balance, TON balance covers reserveTon
//   - rewards: Σ paid ≤ Σ arrived, and claimable + paid ≤ arrived (the vault never over-promises)
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/Curve.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/Pool.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"
import "@tests/launcher-fixtures"

struct Holder {
    t: Treasury
    touched: bool
    paid: int
}

fun balanceOf(w: LaunchWorld, h: Holder): int {
    return h.touched ? coinBalance(w.r, h.t.address) : 0;
}

fun poolK(w: LaunchWorld): int {
    val pd = poolOf(w).getPoolData();
    return pd.reserveTon * pd.reserveCoin;
}

fun checkInvariants(w: LaunchWorld, a: Holder, b: Holder, arrived: int, lastK: int): int {
    val supply = w.r.master.getRewardMasterData().totalSupply;
    val graduated = w.curve.getCurveData().state == CURVE_GRADUATED;
    var held = balanceOf(w, a) + balanceOf(w, b);
    var k = lastK;
    if (graduated) {
        val pool = poolOf(w);
        val pd = pool.getPoolData();
        held += pd.reserveCoin;
        expect(pd.reserveCoin).toEqual(coinBalance(w.r, pool.address));
        expect(testing.getAccountBalance(pool.address) >= pd.reserveTon).toBeTrue();
        k = pd.reserveTon * pd.reserveCoin;
        expect(k >= lastK).toBeTrue();
    }
    expect(supply).toEqual(held);

    val paid = a.paid + b.paid;
    expect(paid <= arrived).toBeTrue();
    var promised = 0;
    if (a.touched) {
        promised += claimable(w.r, a.t.address, 0);
    }
    if (b.touched) {
        promised += claimable(w.r, b.t.address, 0);
    }
    expect(promised + paid <= arrived).toBeTrue();
    return k;
}

/// Buys `ton` worth of coin wherever the market is.
fun marketBuy(w: LaunchWorld, h: Holder, tonIn: coins) {
    if (w.curve.getCurveData().state == CURVE_OPEN) {
        expect(buy(w, h.t.address, tonIn + ton("0.15"))).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
    } else {
        expect(poolBuy(w, h.t.address, tonIn + ton("0.2"))).toHaveSuccessfulTx<SwapTonForCoin>({ to: poolOf(w).address });
    }
}

/// Sells `pct` % of the holder's coins wherever the market is.
fun marketSell(w: LaunchWorld, h: Holder, pct: int) {
    val amount = (balanceOf(w, h) * pct) / 100;
    if (amount == 0) {
        return;
    }
    if (w.curve.getCurveData().state == CURVE_OPEN) {
        expect(sell(w, h.t.address, amount, 0)).toHaveSuccessfulTx<SellNotify>({ to: w.curve.address });
    } else {
        expect(poolSell(w, h.t.address, amount, 0)).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: poolOf(w).address });
    }
}

@test.fuzz(25)
get fun `test launch: fuzz — supply, pool reserves and reward promises stay consistent through a random lifecycle`(o1: int, o2: int, o3: int, o4: int, o5: int, o6: int, o7: int, o8: int) {
    val w = setupLaunch();
    openCurve(w);
    var a: Holder = { t: testing.treasury("lf-a"), touched: false, paid: 0 };
    var b: Holder = { t: testing.treasury("lf-b"), touched: false, paid: 0 };
    var arrived = 0;
    var k = 0;

    // the first step is always a buy so that rewards have someone to go to
    marketBuy(w, a, ton("5"));
    a.touched = true;
    k = checkInvariants(w, a, b, arrived, k);

    var ops = [o1, o2, o3, o4, o5, o6, o7, o8];
    var i = 0;
    while (i < 8) {
        val raw = ops.get(i);
        val kind = fuzz.bound(raw, 0, 6);
        val amt = fuzz.bound(raw / 7, 1, 30);
        if (kind == 0) {
            marketBuy(w, a, amt * ton("1"));
            a.touched = true;
        } else if (kind == 1) {
            marketBuy(w, b, amt * ton("1"));
            b.touched = true;
        } else if (kind == 2) {
            marketSell(w, a, fuzz.bound(raw / 11, 1, 100));
        } else if (kind == 3) {
            marketSell(w, b, fuzz.bound(raw / 11, 1, 100));
        } else if (kind == 4) {
            // reward only when someone can earn it
            if (balanceOf(w, a) + balanceOf(w, b) > 0) {
                val amount = amt * REWARD_UNIT;
                arriveReward(w.r, 0, amount);
                arrived += amount;
            }
        } else if (kind == 5) {
            if (a.touched) {
                val before = rewardBalance(w.r, 0, a.t.address);
                claim(w.r, a.t.address);
                a.paid += rewardBalance(w.r, 0, a.t.address) - before;
            }
        } else {
            if (b.touched) {
                val before = rewardBalance(w.r, 0, b.t.address);
                claim(w.r, b.t.address);
                b.paid += rewardBalance(w.r, 0, b.t.address) - before;
            }
        }
        k = checkInvariants(w, a, b, arrived, k);
        i += 1;
    }

    // once graduated, the curve is closed for good
    if (w.curve.getCurveData().state == CURVE_GRADUATED) {
        expect(buy(w, a.t.address, ton("1.15"))).toHaveFailedTx<Buy>({ to: w.curve.address, exitCode: Errors.CurveNotOpen });
        expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    }
}
