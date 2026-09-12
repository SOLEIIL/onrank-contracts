// Launcher v2 lifecycle fuzz (docs/10 §7.2.8): three holders buy, sell, transfer and claim in a random
// order across the curve, the graduation and the pool, with bursts of simultaneous pool buys. After
// every step the §7.1 invariants hold: supply == held coins, pool reserve == master poolReserve,
// master balance never funds anything, no wallet stays busy, k never decreases, rewards conservative.
import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@acton/types/big_array"

import "@tests/fixtures"
import "@tests/v2-fixtures"
import "@wrappers/CurveV2.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/PoolV2.gen"
import "@wrappers/RewardMasterV2.gen"
import "@wrappers/RewardWalletV2.gen"
import "@wrappers/utils"
import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/launcher-v2/reward-types"
import "@contracts/vendor/jetton/messages"

struct Lifecycle {
    holders: BigArray<address>
    masterBalance0: coins
    bumped: int
    paid: int
    lastK: int
}

fun heldBy(w: V2World, owner: address): int {
    return testing.isDeployed(w.master.getWalletAddress(owner)) ? balanceOf(w, owner) : 0;
}

fun claimableOrZero(w: V2World, owner: address): int {
    return testing.isDeployed(w.master.getWalletAddress(owner)) ? claimable(w, owner, 0) : 0;
}

fun checkInvariants(w: V2World, mutate s: Lifecycle) {
    val m = masterData(w);
    var held = 0;
    var owed = 0;
    var i = 0;
    while (i < s.holders.size()) {
        val h = s.holders.get(i);
        held += heldBy(w, h);
        owed += claimableOrZero(w, h);
        if (testing.isDeployed(w.master.getWalletAddress(h))) {
            expect(isBusy(w, h)).toBeFalse();
        }
        i += 1;
    }
    expect(m.totalSupply).toEqual(held);
    expect(w.master.getJettonData().totalSupply).toEqual(held + m.poolReserve);
    // the master never pays from its own pocket (storage rent aside)
    expect(
        testing.getAccountBalance(w.master.address) >= s.masterBalance0 - ton("0.002"),
    ).toBeTrue();
    // nor does the splitter (it only forwards), nor any wallet below its storage reserve
    expect(testing.getAccountBalance(w.splitter.address) >= ton("0.1") - ton("0.002")).toBeTrue();
    i = 0;
    while (i < s.holders.size()) {
        val wa = w.master.getWalletAddress(s.holders.get(i));
        if (testing.isDeployed(wa)) {
            expect(testing.getAccountBalance(wa) >= MIN_STORAGE_RESERVE - ton("0.002")).toBeTrue();
        }
        i += 1;
    }
    // rewards: never promise more than what arrived
    expect(owed + s.paid <= s.bumped).toBeTrue();
    if (m.pool != null) {
        val p = PoolV2.fromAddress(m.pool!).getPoolData();
        expect(p.reserveCoin).toEqual(m.poolReserve);
        expect(testing.getAccountBalance(m.pool!) >= p.reserveTon).toBeTrue();
        val k = p.reserveTon * p.reserveCoin;
        expect(k >= s.lastK).toBeTrue();
        s.lastK = k;
    } else {
        val c = w.curve.getCurveData();
        expect(testing.getAccountBalance(w.curve.address) >= c.realTon).toBeTrue();
    }
}

/// Buy on whichever market is open (curve or pool); the amount is small enough to never bounce for value.
fun marketBuy(w: V2World, who: address, value: coins) {
    if (w.curve.getCurveData().state == CURVE_GRADUATED) {
        poolBuy(w, who, value);
    } else {
        buy(w, who, value);
    }
}

get fun `test v2 lifecycle: three holders, two markets, bursts — invariants hold at every step`() {
    val w = setupV2();
    val a = testing.treasury("v2-lc-a");
    val b = testing.treasury("v2-lc-b");
    val c = testing.treasury("v2-lc-c");
    var holders = BigArray<address>.createEmpty();
    holders.push(a.address);
    holders.push(b.address);
    holders.push(c.address);
    var s: Lifecycle = {
        holders,
        masterBalance0: testing.getAccountBalance(w.master.address),
        bumped: 0,
        paid: 0,
        lastK: 0,
    };

    buyOk(w, a.address, ton("10"));
    buyOk(w, b.address, ton("5"));
    checkInvariants(w, mutate s);
    bump(w, 0, 300 * REWARD_UNIT);
    s.bumped += 300 * REWARD_UNIT;
    checkInvariants(w, mutate s);
    transfer(w, a.address, c.address, 20 * COIN);
    checkInvariants(w, mutate s);
    val before = claimableOrZero(w, a.address);
    claim(w, a.address);
    s.paid += before - claimableOrZero(w, a.address);
    checkInvariants(w, mutate s);
    sell(w, b.address, 10 * COIN, 0);
    checkInvariants(w, mutate s);
    // graduate with a whale, then trade on the pool
    val whale = testing.treasury("v2-lc-whale");
    holders.push(whale.address);
    s.holders = holders;
    graduate(w, whale.address);
    checkInvariants(w, mutate s);
    bump(w, 0, 200 * REWARD_UNIT);
    s.bumped += 200 * REWARD_UNIT;
    marketBuy(w, c.address, ton("3"));
    sell(w, whale.address, 50 * COIN, 0);
    checkInvariants(w, mutate s);
    val beforeC = claimableOrZero(w, c.address);
    claim(w, c.address);
    s.paid += beforeC - claimableOrZero(w, c.address);
    checkInvariants(w, mutate s);
}

@test.fuzz(20)
get fun `test v2 lifecycle: fuzz — random buys, sells, transfers, bumps, claims and simultaneous pool buys`(
    o1: int,
    o2: int,
    o3: int,
    o4: int,
    o5: int,
    o6: int,
    o7: int,
    o8: int,
    o9: int,
    o10: int,
) {
    val w = setupV2();
    val a = testing.treasury("v2-lf-a");
    val b = testing.treasury("v2-lf-b");
    val c = testing.treasury("v2-lf-c");
    var holders = BigArray<address>.createEmpty();
    holders.push(a.address);
    holders.push(b.address);
    holders.push(c.address);
    var s: Lifecycle = {
        holders,
        masterBalance0: testing.getAccountBalance(w.master.address),
        bumped: 0,
        paid: 0,
        lastK: 0,
    };
    var actors = [a.address, b.address, c.address];

    // someone must hold coins before rewards arrive
    buyOk(w, a.address, ton("4"));
    checkInvariants(w, mutate s);

    var ops = [
        o1,
        o2,
        o3,
        o4,
        o5,
        o6,
        o7,
        o8,
        o9,
        o10,
    ];
    var i = 0;
    while (i < 10) {
        val raw = ops.get(i);
        val kind = fuzz.bound(raw, 0, 6);
        val who = actors.get(fuzz.bound(raw / 7, 0, 2));
        val other = actors.get(fuzz.bound(raw / 13, 0, 2));
        val amt = fuzz.bound(raw / 17, 1, 25);
        if (kind == 0) {
            marketBuy(w, who, amt * ton("1"));
        } else if (kind == 1) {
            val held = heldBy(w, who);
            if (held > 0) {
                sell(w, who, (held * fuzz.bound(raw / 19, 1, 100)) / 100, 0);
            }
        } else if (kind == 2) {
            val held = heldBy(w, who);
            if (held > 0 && who != other) {
                transfer(w, who, other, (held * fuzz.bound(raw / 23, 1, 100)) / 100);
            }
        } else if (kind == 3) {
            if (masterData(w).totalSupply > 0) {
                bump(w, 0, amt * REWARD_UNIT);
                s.bumped += amt * REWARD_UNIT;
            }
        } else if (kind == 4) {
            if (heldBy(w, who) > 0 || claimableOrZero(w, who) > 0) {
                val before = claimableOrZero(w, who);
                claim(w, who);
                s.paid += before - claimableOrZero(w, who);
            }
        } else if (kind == 5) {
            // burst: the three of them buy on the pool in the same block (curve: plain buys)
            if (w.curve.getCurveData().state == CURVE_GRADUATED) {
                val pool = poolOf(w).address;
                val c1 = testing.createTraceIterationCursor(
                    a.address,
                    createMessage({
                        bounce: true,
                        value: ton("1"),
                        dest: pool,
                        body: SwapTonForCoin {
                            queryId: 4,
                            minOut: 0,
                        },
                    }),
                );
                val c2 = testing.createTraceIterationCursor(
                    b.address,
                    createMessage({
                        bounce: true,
                        value: ton("2"),
                        dest: pool,
                        body: SwapTonForCoin {
                            queryId: 4,
                            minOut: 0,
                        },
                    }),
                );
                val c3 = testing.createTraceIterationCursor(
                    c.address,
                    createMessage({
                        bounce: true,
                        value: ton("0.5"),
                        dest: pool,
                        body: SwapTonForCoin {
                            queryId: 4,
                            minOut: 0,
                        },
                    }),
                );
                c1.executeN(1);
                c2.executeN(1);
                c3.executeN(1);
                c1.executeAllRemaining();
                c2.executeAllRemaining();
                c3.executeAllRemaining();
            } else {
                buy(w, a.address, ton("1"));
                buy(w, b.address, ton("1"));
                buy(w, c.address, ton("1"));
            }
        } else {
            // sell with a minTon nobody can meet: refused, reminted
            val held = heldBy(w, who);
            if (held > 0) {
                sell(w, who, held / 2, ton("100000"));
            }
        }
        checkInvariants(w, mutate s);
        i += 1;
    }
    if (w.curve.getCurveData().state == CURVE_GRADUATED) {
        expect(buy(w, a.address, ton("1.15"))).toHaveFailedTx<Buy>({
            to: w.curve.address,
            exitCode: Errors.CurveNotOpen,
        });
    }
}
