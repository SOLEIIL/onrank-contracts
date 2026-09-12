// Launcher v2 core: master / wallet / curve / pool. Covers the three v1 defects (C-1 master gas,
// C-2 pool delivery race, C-3 pending without exit) and the invariants of docs/10 §7.1.
import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
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

/// Storage fee tolerance for "balance never decreases" checks.
const RENT = ton("0.001")

fun swapMsg(pool: address, value: coins): OutMessage {
    return createMessage({
        bounce: true,
        value,
        dest: pool,
        body: SwapTonForCoin {
            queryId: 4,
            minOut: 0,
        },
    });
}

fun named(prefix: string, i: int): string {
    return StringBuilder.create().append(prefix).appendInt(i).build();
}

// ---------------------------------------------------------------------------
// Master / wallet
// ---------------------------------------------------------------------------

get fun `test v2: buy, transfer, plain burn — supply conserved, wallets idle, master balance neutral`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    val masterBefore = testing.getAccountBalance(w.master.address);

    buyOk(w, a.address, ton("5"));
    val bought = balanceOf(w, a.address);
    expect(bought > 0).toBeTrue();
    expect(masterData(w).totalSupply).toEqual(bought);

    val tr = transfer(w, a.address, b.address, bought / 3);
    expect(tr).toHaveSuccessfulTx<Settle>({ to: w.master.address });
    expect(tr).toHaveSuccessfulTx<SettleAck>({ to: wallet(w, a.address).address });
    expect(tr).toHaveSuccessfulTx<RewardTransferStep>({
        from: wallet(
            w,
            a.address,
        ).address,
        to: wallet(w, b.address).address,
    });
    expect(balanceOf(w, a.address)).toEqual(bought - bought / 3);
    expect(balanceOf(w, b.address)).toEqual(bought / 3);
    expect(isBusy(w, a.address)).toBeFalse();

    val burn = wallet(w, b.address).sendBurn(b.address, ton("0.2"), bought / 6, null);
    expect(burn).toHaveSuccessfulTx<SettleAck>({ to: wallet(w, b.address).address });
    expect(balanceOf(w, b.address)).toEqual(bought / 3 - bought / 6);
    expect(isBusy(w, b.address)).toBeFalse();
    expect(masterData(w).totalSupply).toEqual(bought - bought / 6);
    expect(w.master.getJettonData().totalSupply).toEqual(bought - bought / 6);

    var owners = BigArray<address>.createEmpty();
    owners.push(a.address);
    owners.push(b.address);
    supplyInvariant(w, owners);
    expect(testing.getAccountBalance(w.master.address) >= masterBefore - RENT).toBeTrue();
}

get fun `test v2: sell on the curve pays TON, a refused sell remints the coins`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    buyOk(w, a.address, ton("10"));
    val bought = balanceOf(w, a.address);
    val tonBefore = testing.getAccountBalance(a.address);

    val ok = sell(w, a.address, bought / 2, 0);
    expect(ok).toHaveSuccessfulTx<SellNotify>({ from: w.master.address, to: w.curve.address });
    expect(ok).toHaveSuccessfulTx<FeeIn>({ from: w.curve.address, to: w.splitter.address });
    expect(balanceOf(w, a.address)).toEqual(bought - bought / 2);
    expect(masterData(w).totalSupply).toEqual(bought - bought / 2);
    expect(testing.getAccountBalance(a.address) > tonBefore + ton("3")).toBeTrue();
    expect(isBusy(w, a.address)).toBeFalse();

    // minTon too high: the curve refuses and the master mints the coins back
    val refused = sell(w, a.address, bought / 4, ton("1000"));
    expect(refused).toHaveSuccessfulTx<Remint>({ from: w.curve.address, to: w.master.address });
    expect(refused).toHaveSuccessfulTx<RewardTransferStep>({
        from: w.master.address,
        to: wallet(
            w,
            a.address,
        ).address,
    });
    expect(balanceOf(w, a.address)).toEqual(bought - bought / 2);
    expect(masterData(w).totalSupply).toEqual(bought - bought / 2);
    expect(isBusy(w, a.address)).toBeFalse();
}

get fun `test v2: a Settle refused by the master bounces and the wallet restores its balance`() {
    val w = setupV2();
    // a master whose curve is closed with no pool: a sell has nowhere to go
    val fakeCurve = testing.treasury("v2-fake-curve");
    val master = RewardMasterV2.fromStorage({
        totalSupply: 0,
        poolReserve: 0,
        curveOpen: false,
        pool: null,
        roles: RewardMasterRoles {
            factory: w.factory.address,
            seq: 9,
            curve: fakeCurve.address,
            vault: w.vault.address,
        }.toCell(),
        indices: createEmptyMap(),
        remainders: createEmptyMap(),
        metadata: jettonMetadata("CLOSED"),
    });
    expect(
        master.deploy(w.factory.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: master.address });
    val a = testing.treasury("v2-a");
    expect(
        master.sendMintReward(
            fakeCurve.address,
            1,
            a.address,
            100 * COIN,
            0,
            null,
            { value: ton("0.1"), bounce: true },
        ),
    ).toHaveSuccessfulTx<MintReward>({ to: master.address });
    val wa = RewardWalletV2.fromAddress(master.getWalletAddress(a.address));
    expect(wa.getRewardWalletData().balance).toEqual(100 * COIN);

    val res = wa.sendBurn(a.address, ton("0.2"), 40 * COIN, ton("1"));
    expect(res).toHaveFailedTx<Settle>({ to: master.address, exitCode: Errors.CurveClosed });
    expect(wa.getRewardWalletData().balance).toEqual(100 * COIN);
    expect(wa.getRewardWalletData().pending == null).toBeTrue();
    expect(master.getRewardMasterData().totalSupply).toEqual(100 * COIN);
}

get fun `test v2: the master works on its bare storage reserve (rule 6)`() {
    val w = setupV2(ton("0.06"));
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    buyOk(w, a.address, ton("8"));
    buyOk(w, b.address, ton("4"));
    bump(w, 0, 1000 * REWARD_UNIT);
    val before = testing.getAccountBalance(w.master.address);

    var i = 0;
    while (i < 3) {
        expect(sell(w, a.address, 10 * COIN, 0)).toHaveSuccessfulTx<SettleAck>({
            to: wallet(
                w,
                a.address,
            ).address,
        });
        i += 1;
    }
    expect(claim(w, a.address)).toHaveSuccessfulTx<PayRewardReq>({
        from: wallet(
            w,
            a.address,
        ).address,
        to: w.vault.address,
    });
    expect(claim(w, b.address)).toHaveSuccessfulTx<PayRewardReq>({
        from: wallet(
            w,
            b.address,
        ).address,
        to: w.vault.address,
    });
    expect(
        transfer(w, a.address, b.address, 5 * COIN),
    ).toHaveSuccessfulTx<RewardTransferStep>({ to: wallet(w, b.address).address });
    expect(isBusy(w, a.address)).toBeFalse();
    expect(isBusy(w, b.address)).toBeFalse();
    expect(testing.getAccountBalance(w.master.address) >= before - RENT).toBeTrue();
}

get fun `test v2: claim asks the vault for exactly what is owed; a bounced request restores accrued`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    buyOk(w, a.address, ton("6"));
    buyOk(w, b.address, ton("6"));
    val ba = balanceOf(w, a.address);
    val bb = balanceOf(w, b.address);
    bump(w, 0, 1000 * REWARD_UNIT);
    val owedA = (ba * indexValue(w, 0)) / INDEX_SCALE;
    expect(claimable(w, a.address, 0)).toEqual(owedA);

    val res = claim(w, a.address);
    expect(res).toHaveSuccessfulTx<SettleAck>({ to: wallet(w, a.address).address });
    expect(res).toHaveTx<PayRewardReq>({
        from: wallet(w, a.address).address,
        to: w.vault.address,
        value: ton("0.07"),
    });
    expect(claimable(w, a.address, 0)).toEqual(0);
    expect(isBusy(w, a.address)).toBeFalse();
    // b's share is untouched and the two shares add up to the bump (dust aside)
    val owedB = claimable(w, b.address, 0);
    expect(owedB).toEqual((bb * indexValue(w, 0)) / INDEX_SCALE);
    expect(owedA + owedB <= 1000 * REWARD_UNIT).toBeTrue();
    expect(owedA + owedB > 1000 * REWARD_UNIT - 10).toBeTrue();
}

// The bounce of a PayRewardReq (reward claimable again) is covered with RewardVaultV2, which refuses
// unknown reward ids — see v2-vault.test.tolk.

get fun `test v2: CancelSettle — refused before the timeout, SYNC gives the lot back, BURN does not`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    val stuckSync = RewardWalletV2.fromStorage({
        balance: 60 * COIN,
        owner: a.address,
        master: w.master.address,
        stamps: createEmptyMap(),
        accrued: createEmptyMap(),
        pending: PendingOp {
            action: ACTION_SYNC,
            queryId: 11,
            amount: 40 * COIN,
            startedAt: WORLD_T0,
            transfer: null,
        }.toCell(),
    });
    expect(
        stuckSync.deploy(a.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: stuckSync.address });
    val stuckBurn = RewardWalletV2.fromStorage({
        balance: 60 * COIN,
        owner: b.address,
        master: w.master.address,
        stamps: createEmptyMap(),
        accrued: createEmptyMap(),
        pending: PendingOp {
            action: ACTION_BURN,
            queryId: 12,
            amount: 40 * COIN,
            startedAt: WORLD_T0,
            transfer: null,
        }.toCell(),
    });
    expect(
        stuckBurn.deploy(b.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: stuckBurn.address });

    // busy: any new operation is refused
    expect(
        stuckSync.sendClaimRewards(a.address, 1, { value: ton("0.1"), bounce: true }),
    ).toHaveFailedTx<ClaimRewards>({ to: stuckSync.address, exitCode: Errors.SettleInFlight });
    // too early / wrong query / wrong sender
    expect(
        stuckSync.sendCancelSettle(a.address, 11, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<CancelSettle>({ to: stuckSync.address, exitCode: Errors.PendingNotExpired });
    testing.setNow(WORLD_T0 + PENDING_TIMEOUT);
    expect(
        stuckSync.sendCancelSettle(a.address, 99, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<CancelSettle>({ to: stuckSync.address, exitCode: ERR_PENDING_MISMATCH });
    expect(
        stuckSync.sendCancelSettle(b.address, 11, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<CancelSettle>({ to: stuckSync.address, exitCode: Errors.NotFromOwner });

    expect(
        stuckSync.sendCancelSettle(a.address, 11, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<CancelSettle>({ to: stuckSync.address });
    expect(stuckSync.getRewardWalletData().balance).toEqual(100 * COIN);
    expect(stuckSync.getRewardWalletData().pending == null).toBeTrue();

    expect(
        stuckBurn.sendCancelSettle(b.address, 12, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<CancelSettle>({ to: stuckBurn.address });
    expect(stuckBurn.getRewardWalletData().balance).toEqual(60 * COIN);
    expect(stuckBurn.getRewardWalletData().pending == null).toBeTrue();

    // a late ack for the cancelled query is refused (and bounces back to its sender)
    expect(
        stuckSync.sendSettleAck(
            w.factory.address,
            11,
            false,
            null,
            createEmptyMap(),
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveFailedTx<SettleAck>({ to: stuckSync.address, exitCode: Errors.NotFromMaster });
}

get fun `test v2: same holder — sell, transfer and claim fired together: one wins, the others are refused cleanly`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    buyOk(w, a.address, ton("6"));
    val bought = balanceOf(w, a.address);
    bump(w, 0, 100 * REWARD_UNIT);
    val wa = wallet(w, a.address);

    val c1 = testing.createTraceIterationCursor(
        a.address,
        createMessage({
            bounce: true,
            value: ton("0.2"),
            dest: wa.address,
            body: AskToBurn {
                queryId: 1,
                jettonAmount: bought / 4,
                sendExcessesTo: a.address,
                customPayload: SellIntent { minTon: 0 }.toCell(),
            },
        }),
    );
    val c2 = testing.createTraceIterationCursor(
        a.address,
        createMessage({
            bounce: true,
            value: ton("0.2"),
            dest: wa.address,
            body: AskToTransfer {
                queryId: 2,
                jettonAmount: bought / 4,
                transferRecipient: b.address,
                sendExcessesTo: a.address,
                customPayload: null,
                forwardTonAmount: 0,
                forwardPayload: emptyForwardPayload(),
            },
        }),
    );
    val c3 = testing.createTraceIterationCursor(
        a.address,
        createMessage({
            bounce: true,
            value: ton("0.3"),
            dest: wa.address,
            body: ClaimRewards { queryId: 3 },
        }),
    );
    val r1 = c1.executeN(1);
    val r2 = c2.executeN(1);
    val r3 = c3.executeN(1);
    expect(r1).toHaveSuccessfulTx<AskToBurn>({ to: wa.address });
    expect(r2).toHaveFailedTx<AskToTransfer>({ to: wa.address, exitCode: Errors.SettleInFlight });
    expect(r3).toHaveFailedTx<ClaimRewards>({ to: wa.address, exitCode: Errors.SettleInFlight });
    c1.executeAllRemaining();
    c2.executeAllRemaining();
    c3.executeAllRemaining();

    expect(balanceOf(w, a.address)).toEqual(bought - bought / 4);
    expect(isBusy(w, a.address)).toBeFalse();
    expect(masterData(w).totalSupply).toEqual(bought - bought / 4);
    // the sold lot earned until the sell: the whole bump is still owed to a
    expect(claimable(w, a.address, 0)).toEqual((bought * indexValue(w, 0)) / INDEX_SCALE);
}

// ---------------------------------------------------------------------------
// Curve / pool
// ---------------------------------------------------------------------------

get fun `test v2: last lot charges the fee on the capped amount, graduation credits the pool atomically`() {
    val w = setupV2();
    val whale = testing.treasury("v2-whale");
    val last = graduate(w, whale.address);
    expect(last).toHaveSuccessfulTx<CurveGraduated>({
        from: w.curve.address,
        to: w.master.address,
    });
    val pool = poolOf(w);
    expect(last).toHaveSuccessfulTx<TopUpTons>({ from: w.curve.address, to: pool.address });

    val m = masterData(w);
    expect(m.pool!).toEqual(pool.address);
    expect(m.poolReserve).toEqual(POOL_SUPPLY);
    expect(m.curveOpen).toBeFalse();
    expect(pool.getPoolData().reserveCoin).toEqual(POOL_SUPPLY);
    expect(w.curve.getCurveData().sold).toEqual(CURVE_SUPPLY);
    expect(balanceOf(w, whale.address)).toEqual(CURVE_SUPPLY);
    expect(m.totalSupply).toEqual(CURVE_SUPPLY);
    expect(w.master.getJettonData().totalSupply).toEqual(CURVE_SUPPLY + POOL_SUPPLY);
    // the pool holds its liquidity plus a storage margin
    val liquidity = pool.getPoolData().reserveTon;
    expect(testing.getAccountBalance(pool.address) >= liquidity).toBeTrue();
    // the fee taken on the graduating buy is the fee of what was actually charged
    val ev = findEvent<CurveTradeEvent>(last, w.curve.address, EVENT_TOPIC_CURVE_TRADE);
    expect(ev!.fee <= (ev!.ton * FEE_BPS) / (10000 - FEE_BPS) + 1).toBeTrue();

    // sells now route to the pool: the coins join the pool reserve
    val poolBefore = pool.getPoolData();
    val s = sell(w, whale.address, 10 * COIN, 0);
    expect(s).toHaveSuccessfulTx<SellNotify>({ from: w.master.address, to: pool.address });
    expect(s).toHaveSuccessfulTx<PoolCredit>({ from: pool.address, to: w.master.address });
    expect(pool.getPoolData().reserveCoin).toEqual(poolBefore.reserveCoin + 10 * COIN);
    expect(masterData(w).poolReserve).toEqual(poolBefore.reserveCoin + 10 * COIN);
    expect(pool.getPoolData().reserveTon < poolBefore.reserveTon).toBeTrue();
    var owners = BigArray<address>.createEmpty();
    owners.push(whale.address);
    supplyInvariant(w, owners);
}

get fun `test v2: 20 pool buys from distinct buyers in the same block — every buyer is delivered, no 476`() {
    val w = setupV2();
    val whale = testing.treasury("v2-whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val reserveBefore = pool.getPoolData();

    var cursors = BigArray<TxCursor>.createEmpty();
    var buyers = BigArray<address>.createEmpty();
    var i = 0;
    while (i < 20) {
        val buyer = testing.treasury(named("v2-buyer-", i));
        buyers.push(buyer.address);
        cursors.push(
            testing.createTraceIterationCursor(buyer.address, swapMsg(pool.address, ton("1"))),
        );
        i += 1;
    }
    // every swap hits the pool before any delivery is processed
    i = 0;
    while (i < 20) {
        expect(cursors.get(i).executeN(1)).toHaveSuccessfulTx<SwapTonForCoin>({ to: pool.address });
        i += 1;
    }
    val mid = pool.getPoolData();
    expect(mid.reserveCoin < reserveBefore.reserveCoin).toBeTrue();
    // the master already moved the coins out of the pool reserve? not yet: PoolOut messages are queued
    expect(masterData(w).poolReserve).toEqual(reserveBefore.reserveCoin);
    i = 0;
    while (i < 20) {
        val res = cursors.get(i).executeAllRemaining();
        expect(res).toHaveSuccessfulTx<PoolOut>({ from: pool.address, to: w.master.address });
        expect(res).toHaveSuccessfulTx<PoolDeliver>({
            from: w.master.address,
            to: w.master.getWalletAddress(buyers.get(i)),
        });
        expect(balanceOf(w, buyers.get(i)) > 0).toBeTrue();
        expect(isBusy(w, buyers.get(i))).toBeFalse();
        i += 1;
    }
    expect(masterData(w).poolReserve).toEqual(pool.getPoolData().reserveCoin);
    buyers.push(whale.address);
    supplyInvariant(w, buyers);
    // k never decreased
    expect(
        pool.getPoolData().reserveTon * pool.getPoolData().reserveCoin >=
        reserveBefore.reserveTon * reserveBefore.reserveCoin,
    ).toBeTrue();
}

get fun `test v2: pool sell refused on slippage remints; accepted sell pays and credits the master`() {
    val w = setupV2();
    val whale = testing.treasury("v2-whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val before = pool.getPoolData();
    val held = balanceOf(w, whale.address);

    val refused = sell(w, whale.address, 50 * COIN, ton("1000"));
    expect(refused).toHaveSuccessfulTx<SellNotify>({ from: w.master.address, to: pool.address });
    expect(refused).toHaveSuccessfulTx<Remint>({ from: pool.address, to: w.master.address });
    expect(balanceOf(w, whale.address)).toEqual(held);
    expect(pool.getPoolData().reserveCoin).toEqual(before.reserveCoin);
    expect(masterData(w).poolReserve).toEqual(before.reserveCoin);
    expect(isBusy(w, whale.address)).toBeFalse();

    val tonBefore = testing.getAccountBalance(whale.address);
    val quote = pool.getSellQuote(50 * COIN);
    val ok = sell(w, whale.address, 50 * COIN, quote.amountOut);
    expect(ok).toHaveSuccessfulTx<PoolCredit>({ from: pool.address, to: w.master.address });
    expect(ok).toHaveSuccessfulTx<FeeIn>({ from: pool.address, to: w.splitter.address });
    expect(balanceOf(w, whale.address)).toEqual(held - 50 * COIN);
    expect(
        testing.getAccountBalance(whale.address) >= tonBefore + quote.amountOut - ton("0.25"),
    ).toBeTrue();
    expect(pool.getPoolData().reserveCoin).toEqual(before.reserveCoin + 50 * COIN);
    expect(masterData(w).poolReserve).toEqual(before.reserveCoin + 50 * COIN);
    expect(
        pool.getPoolData().reserveTon * pool.getPoolData().reserveCoin >=
        before.reserveTon * before.reserveCoin,
    ).toBeTrue();
}

get fun `test v2: 50 curve buys from 50 buyers in the same block — all minted, supply exact`() {
    val w = setupV2();
    var cursors = BigArray<TxCursor>.createEmpty();
    var buyers = BigArray<address>.createEmpty();
    var i = 0;
    while (i < 50) {
        val b = testing.treasury(named("v2-fifty-", i));
        buyers.push(b.address);
        cursors.push(
            testing.createTraceIterationCursor(
                b.address,
                createMessage({
                    bounce: true,
                    value: ton("0.5"),
                    dest: w.curve.address,
                    body: Buy {
                        queryId: 3,
                        minOut: 0,
                        recipient: null,
                    },
                }),
            ),
        );
        i += 1;
    }
    i = 0;
    while (i < 50) {
        expect(cursors.get(i).executeN(1)).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
        i += 1;
    }
    // every mint lands, in any order
    i = 0;
    while (i < 50) {
        cursors.get(i).executeAllRemaining();
        expect(balanceOf(w, buyers.get(i)) > 0).toBeTrue();
        i += 1;
    }
    supplyInvariant(w, buyers);
    expect(w.curve.getCurveData().realTon <= testing.getAccountBalance(w.curve.address)).toBeTrue();
}

get fun `test v2: master at its 0.05 TON floor with 5 rewards — sells and claims keep working`() {
    val w = setupV2(ton("0.05"));
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    buyOk(w, a.address, ton("8"));
    buyOk(w, b.address, ton("4"));
    var id = 0;
    while (id < MAX_REWARDS) {
        bump(w, id, (50 + id) * REWARD_UNIT);
        id += 1;
    }
    val before = testing.getAccountBalance(w.master.address);
    var i = 0;
    while (i < 3) {
        expect(sell(w, a.address, 5 * COIN, 0)).toHaveSuccessfulTx<SettleAck>({
            to: wallet(
                w,
                a.address,
            ).address,
        });
        i += 1;
    }
    expect(claim(w, a.address, ton("0.45"))).toHaveSuccessfulTx<PayRewardReq>({
        from: wallet(
            w,
            a.address,
        ).address,
        to: w.vault.address,
    });
    expect(claim(w, b.address, ton("0.45"))).toHaveSuccessfulTx<PayRewardReq>({
        from: wallet(
            w,
            b.address,
        ).address,
        to: w.vault.address,
    });
    id = 0;
    while (id < MAX_REWARDS) {
        expect(claimable(w, a.address, id)).toEqual(0);
        expect(claimable(w, b.address, id)).toEqual(0);
        id += 1;
    }
    expect(isBusy(w, a.address) || isBusy(w, b.address)).toBeFalse();
    expect(testing.getAccountBalance(w.master.address) >= before - RENT).toBeTrue();
}

get fun `test v2: index bumps carry their remainder — Σ index deltas × circulating + remainder == amount × SCALE`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    buyOk(w, a.address, ton("7"));
    buyOk(w, b.address, ton("3"));
    val amounts = [333, 1000001, 7, 99999999, 123456789];
    var i = 0;
    while (i < 5) {
        val amount = amounts.get(i);
        val m0 = masterData(w);
        val rem0 = amountOf(w.master.getRewardMasterData().remainders, 0);
        bump(w, 0, amount);
        val m1 = masterData(w);
        val rem1 = amountOf(w.master.getRewardMasterData().remainders, 0);
        val delta = indexOf(m1.indices, 0) - indexOf(m0.indices, 0);
        expect(delta * m0.totalSupply + rem1 - rem0).toEqual(amount * INDEX_SCALE);
        expect(rem1 < m0.totalSupply).toBeTrue();
        i += 1;
    }
    // nothing over-promised: what the two holders can claim together never exceeds what arrived
    var bumped = 0;
    i = 0;
    while (i < 5) {
        bumped += amounts.get(i);
        i += 1;
    }
    expect(claimable(w, a.address, 0) + claimable(w, b.address, 0) <= bumped).toBeTrue();
    expect(claimable(w, a.address, 0) + claimable(w, b.address, 0) >= bumped - 5).toBeTrue();
}

get fun `test v2: pool inFlight ring — the 65th buy evicts the first; its late bounce returns the coins without a refund`() {
    val w = setupV2();
    val ghostMaster = w.master.getWalletAddress(w.factory.address);
    val pool = PoolV2.fromStorage({
        reserveTon: ton("100"),
        reserveCoin: 200 * COIN,
        lpFeeBps: 100,
        protocolFeeBps: 100,
        volumeTon: 0,
        nonce: 0,
        roles: PoolRoles {
            master: ghostMaster,
            splitter: w.splitter.address,
            walletCode: build("RewardWalletV2"),
        }.toCell(),
        inFlight: [],
    });
    expect(
        pool.deploy(w.factory.address, { value: ton("100.2"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    // 65 buys hit the pool before any delivery bounce comes back
    var cursors = BigArray<TxCursor>.createEmpty();
    var i = 0;
    while (i < 65) {
        val b = testing.treasury(named("v2-ring-", i));
        cursors.push(
            testing.createTraceIterationCursor(b.address, swapMsg(pool.address, ton("1"))),
        );
        cursors.get(i).executeN(1);
        i += 1;
    }
    val mid = pool.getPoolData();
    expect(mid.nonce).toEqual(65);
    // bounces arrive: the first entry was evicted (coins back to the pool, TON kept), the 64 others are refunded
    var refunded = 0;
    var kept = 0;
    i = 0;
    while (i < 65) {
        val res = cursors.get(i).executeAllRemaining();
        val ev = findEvent<PoolRefundEvent>(res, pool.address, EVENT_TOPIC_POOL_REFUND);
        expect(ev).toBeNotNull();
        if (ev!.refunded) {
            refunded += 1;
        } else {
            kept += 1;
            expect(ev!.nonce).toEqual(1);
        }
        i += 1;
    }
    expect(refunded).toEqual(64);
    expect(kept).toEqual(1);
    val after = pool.getPoolData();
    expect(after.reserveCoin).toEqual(200 * COIN);
    // the evicted buyer's TON (net + lpFee of a 0.85 TON swap) stayed as liquidity
    expect(after.reserveTon > ton("100") && after.reserveTon < ton("101")).toBeTrue();
}

get fun `test v2: coins sent to the pool by a jetton transfer (v1 sell path, stale client) come straight back`() {
    val w = setupV2();
    val whale = testing.treasury("v2-whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val held = balanceOf(w, whale.address);
    val before = pool.getPoolData();

    // exactly what a v1 client sends to sell on the pool: transfer to the pool with a SwapCoinForTon payload and 0.15 forward
    val payload = beginCell().storeUint(0x504F0002, 32).storeCoins(0).endCell();
    val res = wallet(w, whale.address).sendTransfer(
        whale.address,
        ton("0.3"),
        50 * COIN,
        pool.address,
        whale.address,
        null,
        ton("0.15"),
        payload,
    );
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: pool.address });
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: pool.address });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({ to: wallet(w, whale.address).address });
    expect(balanceOf(w, whale.address)).toEqual(held);
    expect(balanceOf(w, pool.address)).toEqual(0);
    expect(isBusy(w, pool.address)).toBeFalse();
    expect(pool.getPoolData().reserveCoin).toEqual(before.reserveCoin);
    expect(masterData(w).poolReserve).toEqual(before.reserveCoin);
    var owners = BigArray<address>.createEmpty();
    owners.push(whale.address);
    owners.push(pool.address);
    supplyInvariant(w, owners);

    // a transfer without notification is a raw transfer to a contract address: the coins stay in the pool's wallet
    val raw = wallet(w, whale.address).sendTransfer(
        whale.address,
        ton("0.2"),
        5 * COIN,
        pool.address,
        whale.address,
        null,
        0,
        null,
    );
    expect(raw).toHaveSuccessfulTx<RewardTransferStep>({ to: wallet(w, pool.address).address });
    expect(balanceOf(w, pool.address)).toEqual(5 * COIN);
    expect(pool.getPoolData().reserveCoin).toEqual(before.reserveCoin);
}

get fun `test v2: a delivery that cannot reach the master refunds the buyer and restores the reserves`() {
    val w = setupV2();
    val ghostMaster = w.master.getWalletAddress(w.factory.address);
    val pool = PoolV2.fromStorage({
        reserveTon: ton("100"),
        reserveCoin: 200 * COIN,
        lpFeeBps: 100,
        protocolFeeBps: 100,
        volumeTon: 0,
        nonce: 0,
        roles: PoolRoles {
            master: ghostMaster,
            splitter: w.splitter.address,
            walletCode: build("RewardWalletV2"),
        }.toCell(),
        inFlight: createEmptyMap(),
    });
    expect(
        pool.deploy(w.factory.address, { value: ton("100.2"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: pool.address });
    val buyer = testing.treasury("v2-buyer");
    val tonBefore = testing.getAccountBalance(buyer.address);

    val res = pool.sendSwapTonForCoin(buyer.address, 4, 0, { value: ton("2"), bounce: true });
    expect(res).toHaveSuccessfulTx<SwapTonForCoin>({ to: pool.address });
    // the PoolOut bounces (no contract at the master address) and the pool refunds
    expect(countEvents(res, pool.address, EVENT_TOPIC_POOL_REFUND)).toEqual(1);
    val ev = findEvent<PoolRefundEvent>(res, pool.address, EVENT_TOPIC_POOL_REFUND);
    expect(ev!.refunded).toBeTrue();
    val data = pool.getPoolData();
    expect(data.reserveCoin).toEqual(200 * COIN);
    expect(data.reserveTon).toEqual(ton("100"));
    // the buyer lost only gas and the protocol fee already sent to the splitter
    expect(testing.getAccountBalance(buyer.address) >= tonBefore - ton("0.2")).toBeTrue();
    expect(testing.getAccountBalance(pool.address) >= ton("100")).toBeTrue();

    // a PoolOutFailed from someone else than the master is refused
    expect(
        pool.sendPoolOutFailed(buyer.address, 1, 10 * COIN, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<PoolOutFailed>({ to: pool.address, exitCode: Errors.NotFromMaster });
}

get fun `test v2: graduation under load — buys and sells in flight all settle, the pool is ready at once`() {
    val w = setupV2();
    val whale = testing.treasury("v2-whale");
    // bring the curve close to graduation
    var i = 0;
    while (i < 4) {
        buyOk(w, whale.address, ton("20"));
        i += 1;
    }
    expect(w.curve.getCurveData().state).toEqual(CURVE_OPEN);
    val held = balanceOf(w, whale.address);

    var cursors = BigArray<TxCursor>.createEmpty();
    var buyers = BigArray<address>.createEmpty();
    i = 0;
    while (i < 6) {
        val buyer = testing.treasury(named("v2-late-", i));
        buyers.push(buyer.address);
        cursors.push(
            testing.createTraceIterationCursor(
                buyer.address,
                createMessage({
                    bounce: true,
                    value: ton("10"),
                    dest: w.curve.address,
                    body: Buy {
                        queryId: 3,
                        minOut: 0,
                        recipient: null,
                    },
                }),
            ),
        );
        i += 1;
    }
    val sellCursor = testing.createTraceIterationCursor(
        whale.address,
        createMessage({
            bounce: true,
            value: ton("0.2"),
            dest: wallet(w, whale.address).address,
            body: AskToBurn {
                queryId: 1,
                jettonAmount: 10 * COIN,
                sendExcessesTo: whale.address,
                customPayload: SellIntent { minTon: 0 }.toCell(),
            },
        }),
    );
    // the master burns and emits the SellNotify while the curve is still open...
    sellCursor.executeTill<Settle>({ to: w.master.address });
    // ...then the buys graduate the curve (some of them bounce: curve closed)
    i = 0;
    while (i < 6) {
        cursors.get(i).executeAllRemaining();
        i += 1;
    }
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    // the sell now lands on a graduated curve: refused, coins reminted
    val late = sellCursor.executeAllRemaining();
    expect(late).toHaveSuccessfulTx<Remint>({ from: w.curve.address, to: w.master.address });
    expect(balanceOf(w, whale.address)).toEqual(held);
    expect(isBusy(w, whale.address)).toBeFalse();

    val pool = poolOf(w);
    expect(pool.getPoolData().reserveCoin).toEqual(masterData(w).poolReserve);
    // the pool is usable right away
    val late2 = poolBuy(w, whale.address, ton("2"));
    expect(late2).toHaveSuccessfulTx<PoolDeliver>({
        from: w.master.address,
        to: wallet(
            w,
            whale.address,
        ).address,
    });
    buyers.push(whale.address);
    supplyInvariant(w, buyers);
}
