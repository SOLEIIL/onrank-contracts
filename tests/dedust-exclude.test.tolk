// Dividend exclusion for a future DeDust pool wallet. Not a graduation test.
// Uses CurveDex / RewardMasterDex / RewardWalletDex. Live v2 contracts stay untouched.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/dedust-fixtures"
import "@tests/fixtures"
import "@wrappers/RewardMasterDex.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/dividend-messages"
import "@contracts/launcher-dex/reward-types"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/vendor/jetton/messages"

const REWARD = 100000000 // 100 tokens, 6 decimals

fun exclude(w: DexWorld, owner: address) {
    val res = net.send(
        w.factory.address,
        createMessage({
            bounce: true,
            value: ton("0.15"),
            dest: w.curve.address,
            body: ExcludeFromDividends {
                queryId: 1,
                owner,
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<SetDividendExcluded>({
        from: w.curve.address,
        to: w.master.address,
    });
    expect(res).toHaveSuccessfulTx<MarkExcluded>({ to: wallet(w, owner).address });
}

/// This bump's index step uses exactly `earning` coins, and each claimable is the
/// integer share of that step. No slack: a hole in the exclusion fails the equality.
fun expectPaid(
    w: DexWorld,
    reward: int,
    indexBefore: int,
    oldRem: int,
    dueA: int,
    balA: int,
    dueB: int,
    balB: int,
) {
    val earning = balA + balB;
    val data = masterData(w);
    val rem = amountOf(data.remainders, 0);
    val delta = indexOf(data.indices, 0) - indexBefore;
    val scaled = reward * INDEX_SCALE + oldRem;
    expect(earning > 0).toBeTrue();
    expect(delta).toEqual(scaled / earning);
    expect(rem).toEqual(scaled % earning);
    expect(dueA).toEqual((balA * delta) / INDEX_SCALE);
    expect(dueB).toEqual((balB * delta) / INDEX_SCALE);
}

get fun `test exclude: two holders split a bump when nobody is excluded`() {
    val w = setupDex();
    val a = testing.treasury("ex-a");
    val b = testing.treasury("ex-b");
    buyOk(w, a.address, ton("5"));
    val half = balanceOf(w, a.address) / 2;
    expect(transfer(w, a.address, b.address, half)).toHaveSuccessfulTx<RewardTransferStep>({
        to: wallet(w, b.address).address,
    });
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    expectPaid(
        w,
        REWARD,
        indexBefore,
        oldRem,
        claimable(w, a.address, 0),
        balanceOf(w, a.address),
        claimable(w, b.address, 0),
        balanceOf(w, b.address),
    );
}

get fun `test exclude: the excluded wallet earns nothing and the holder is not diluted`() {
    val w = setupDex();
    val holder = testing.treasury("ex-holder");
    val dex = testing.treasury("ex-dex");
    buyOk(w, holder.address, ton("5"));
    exclude(w, dex.address);
    val parked = balanceOf(w, holder.address) / 2;
    expect(transfer(w, holder.address, dex.address, parked)).toHaveSuccessfulTx<ExcludedBalance>({
        to: w.master.address,
    });
    expect(masterData(w).excludedBalance).toEqual(parked);
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    expect(claimable(w, dex.address, 0)).toEqual(0);
    expectPaid(
        w,
        REWARD,
        indexBefore,
        oldRem,
        claimable(w, holder.address, 0),
        balanceOf(w, holder.address),
        0,
        0,
    );
}

get fun `test exclude: coins that arrive after a bump do not inherit it`() {
    val w = setupDex();
    val holder = testing.treasury("ex-before");
    val dex = testing.treasury("ex-before-dex");
    buyOk(w, holder.address, ton("5"));
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    val first = claimable(w, holder.address, 0);
    expectPaid(
        w,
        REWARD,
        indexBefore,
        oldRem,
        first,
        balanceOf(w, holder.address),
        0,
        0,
    );
    exclude(w, dex.address);
    val parked = balanceOf(w, holder.address) / 2;
    transfer(w, holder.address, dex.address, parked);
    expect(claimable(w, dex.address, 0)).toEqual(0);
    val indexMid = indexValue(w, 0);
    val remMid = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    expect(claimable(w, dex.address, 0)).toEqual(0);
    val second = claimable(w, holder.address, 0) - first;
    expectPaid(
        w,
        REWARD,
        indexMid,
        remMid,
        second,
        balanceOf(w, holder.address),
        0,
        0,
    );
}

get fun `test exclude: coins sent back by the pool earn, coins that stay do not`() {
    val w = setupDex();
    val holder = testing.treasury("ex-back");
    val dex = testing.treasury("ex-back-dex");
    buyOk(w, holder.address, ton("5"));
    exclude(w, dex.address);
    val parked = balanceOf(w, holder.address) / 2;
    transfer(w, holder.address, dex.address, parked);
    val back = parked / 2;
    expect(transfer(w, dex.address, holder.address, back)).toHaveSuccessfulTx<ExcludedBalance>({
        to: w.master.address,
    });
    expect(masterData(w).excludedBalance).toEqual(parked - back);
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    expect(claimable(w, dex.address, 0)).toEqual(0);
    expectPaid(
        w,
        REWARD,
        indexBefore,
        oldRem,
        claimable(w, holder.address, 0),
        balanceOf(w, holder.address),
        0,
        0,
    );
}

get fun `test exclude: two holders share the reward, the pool's 20 percent does not`() {
    val w = setupDex();
    val a = testing.treasury("ex-20-a");
    val b = testing.treasury("ex-20-b");
    val dex = testing.treasury("ex-20-dex");
    buyOk(w, a.address, ton("5"));
    val all = balanceOf(w, a.address);
    val fifth = all / 5;
    exclude(w, dex.address);
    transfer(w, a.address, dex.address, fifth);
    val rest = balanceOf(w, a.address);
    transfer(w, a.address, b.address, rest / 2);
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    bump(w, 0, REWARD);
    expect(claimable(w, dex.address, 0)).toEqual(0);
    expectPaid(
        w,
        REWARD,
        indexBefore,
        oldRem,
        claimable(w, a.address, 0),
        balanceOf(w, a.address),
        claimable(w, b.address, 0),
        balanceOf(w, b.address),
    );
}

get fun `test exclude: an in-flight transfer is not excluded until it lands`() {
    val w = setupDex();
    val holder = testing.treasury("ex-flight");
    val dex = testing.treasury("ex-flight-dex");
    buyOk(w, holder.address, ton("5"));
    exclude(w, dex.address);
    val lot = balanceOf(w, holder.address) / 4;
    val cursor = testing.createTraceIterationCursor(
        holder.address,
        createMessage({
            bounce: true,
            value: ton("0.2"),
            dest: wallet(w, holder.address).address,
            body: AskToTransfer {
                queryId: 0,
                jettonAmount: lot,
                transferRecipient: dex.address,
                sendExcessesTo: holder.address,
                customPayload: null,
                forwardTonAmount: 0,
                forwardPayload: beginCell().storeMaybeRef(null).endCell().beginParse(),
            },
        }),
    );
    cursor.executeTill<SettleAck>({ to: wallet(w, holder.address).address });
    expect(masterData(w).excludedBalance).toEqual(0);
    expect(balanceOf(w, dex.address)).toEqual(0);
    cursor.executeAllRemaining();
    expect(balanceOf(w, dex.address)).toEqual(lot);
    expect(masterData(w).excludedBalance).toEqual(lot);
}

get fun `test exclude: PoolV2 reserve stays out of the wallet supply`() {
    val w = setupDex();
    val whale = testing.treasury("ex-whale");
    graduate(w, whale.address);
    val supply = masterData(w).totalSupply;
    expect(masterData(w).poolReserve > 0).toBeTrue();
    expect(masterData(w).excludedOwner == null).toBeTrue();
    val indexBefore = indexValue(w, 0);
    val oldRem = amountOf(masterData(w).remainders, 0);
    val res = bump(w, 0, REWARD);
    val ev = findEvent<IndexBumpedEvent>(res, w.master.address, EVENT_TOPIC_INDEX_BUMPED);
    expect(ev!.circulating).toEqual(supply);
    expect(balanceOf(w, whale.address)).toEqual(supply);
    expectPaid(
        w,
        REWARD,
        indexBefore,
        oldRem,
        claimable(w, whale.address, 0),
        supply,
        0,
        0,
    );
}

get fun `test exclude: a bump is refused when the excluded balance covers the supply`() {
    val w = setupDex();
    val holder = testing.treasury("ex-all");
    val dex = testing.treasury("ex-all-dex");
    buyOk(w, holder.address, ton("5"));
    val all = balanceOf(w, holder.address);
    exclude(w, dex.address);
    transfer(w, holder.address, dex.address, all);
    expect(masterData(w).excludedBalance).toEqual(masterData(w).totalSupply);
    val refused = w
        .master
        .sendIndexBump(
            w.vault.address,
            7,
            0,
            REWARD,
            { value: ton("0.05"), bounce: true },
        );
    expect(refused).toHaveSuccessfulTx<IndexBumpRefused>({
        from: w.master.address,
        to: w.vault.address,
    });
    expect(indexValue(w, 0)).toEqual(0);
}

get fun `test exclude: a stranger cannot name the excluded owner`() {
    val w = setupDex();
    val stranger = testing.treasury("ex-stranger");
    val dex = testing.treasury("ex-stranger-dex");
    expect(
        net.send(
            stranger.address,
            createMessage({
                bounce: true,
                value: ton("0.15"),
                dest: w.curve.address,
                body: ExcludeFromDividends {
                    queryId: 2,
                    owner: dex.address,
                },
            }),
        ),
    ).toHaveFailedTx<ExcludeFromDividends>({
        to: w.curve.address,
        exitCode: Errors.NotFromFactory,
    });
    expect(
        net.send(
            stranger.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: w.master.address,
                body: SetDividendExcluded {
                    queryId: 3,
                    owner: dex.address,
                },
            }),
        ),
    ).toHaveFailedTx<SetDividendExcluded>({
        to: w.master.address,
        exitCode: Errors.NotFromCurve,
    });
    expect(masterData(w).excludedOwner == null).toBeTrue();
}
