import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"

import "@contracts/common/consts"
import "@contracts/common/dedust"
import "@contracts/common/errors"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/pot/pot-messages"
import "@contracts/pot/pot-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/utils"
import "@tests/fixtures"

/// Plain TON lands in the Pot (royalty-like).
fun fundPot(w: World, amount: coins) {
    val res = net.send(w.issuer.address, createMessage({ bounce: false, value: amount, dest: w.pot.address, body: createEmptyCell() }));
    expect(res).toHaveTx({ from: w.issuer.address, to: w.pot.address });
}

/// Keeper Convert. `minUsdt == 0` means "exactly the admin floor" (the Pot refuses anything below it).
fun convert(w: World, spend: coins, minUsdt: coins, pool: address? = null, value: coins = ton("0.3")): SendResultList {
    val min = minUsdt == 0 ? floorUsdtFor(spend) : minUsdt;
    return w.pot.sendConvert(w.keeper.address, 1, pool == null ? w.pool.address : pool!, spend, min, { value, bounce: true });
}

/// Keeper Round. `minOut == 0` means "exactly the slot floor"; the default payload carries that same min-out.
fun round(w: World, slot: int, spendUsdt: coins, minOut: coins, advance: bool = true, payload: cell? = null, value: coins = ton("0.4")): SendResultList {
    val min = minOut == 0 ? floorStockFor(spendUsdt) : minOut;
    val p = payload == null ? escrowPayloadFor(w.pot.address, min) : payload!;
    return w.pot.sendRound(w.keeper.address, 2, slot as uint8, spendUsdt, min, ton("0.1"), advance, p, { value, bounce: true });
}

/// TON coming back from the DEX vault (DeDust `payout`): rejected swap or leftover gas.
fun dexPayout(w: World, value: coins, queryId: uint64 = 1): SendResultList {
    val body = DedustPayout { queryId, payload: null };
    return net.send(w.dex.address, createMessage({ bounce: true, value, dest: w.pot.address, body }));
}

// ---------------------------------------------------------------------------
// Convert (TON -> USDT)
// ---------------------------------------------------------------------------

get fun `test convert: keeper swaps pot ton above threshold, usdt arrival settles`() {
    val w = setupWorld();
    fundPot(w, ton("10"));
    val potBefore = testing.getAccountBalance(w.pot.address);
    val dexBefore = testing.getAccountBalance(w.dex.address);

    val res = convert(w, ton("5"), 100 * USDT_UNIT);
    expect(res).toHaveSuccessfulTx<Convert>({ from: w.keeper.address, to: w.pot.address });
    // the swap goes to the vault with a body the Pot built itself: our pool, our address as receiver, our limit
    val swapTx = res.findTransaction<DedustNativeSwap>({ from: w.pot.address, to: w.dex.address });
    expect(swapTx).toBeNotNull();
    val swap = swapTx!.loadBody<DedustNativeSwap>();
    expect(swap.amount).toEqual(ton("5"));
    expect(swap.pool).toEqual(w.pool.address);
    expect(swap.limit).toEqual(100 * USDT_UNIT);
    expect(swap.kind).toBeFalse();
    val sp = swap.params.load();
    expect(sp.recipient).toEqual(w.pot.address);
    expect(sp.deadline > WORLD_T0).toBeTrue();
    // spend + the keeper's gas went out (5 + 0.3 - 0.02); the pot's own funds only paid the forward fee
    expect(testing.getAccountBalance(w.dex.address) - dexBefore > ton("5.27")).toBeTrue();
    expect(potBefore - testing.getAccountBalance(w.pot.address) < ton("5.01")).toBeTrue();

    var data = w.pot.getPotData();
    expect(data.totalTonSpent).toEqual(ton("5"));
    expect(data.pending).toBeNotNull();
    expect(data.pending!.kind).toEqual(PENDING_CONVERT);
    expect(data.pending!.spend).toEqual(ton("5"));

    val settle = arriveUsdt(w, 120 * USDT_UNIT);
    val ev = findEvent<ConvertSettledEvent>(settle, w.pot.address, EVENT_TOPIC_CONVERT_SETTLED);
    expect(ev).toBeNotNull();
    expect(ev!.spendTon).toEqual(ton("5"));
    expect(ev!.receivedUsdt).toEqual(120 * USDT_UNIT);
    expect(countEvents(settle, w.pot.address, EVENT_TOPIC_SLIPPAGE_BREACH)).toEqual(0);

    data = w.pot.getPotData();
    expect(data.usdtBudget).toEqual(120 * USDT_UNIT);
    expect(data.pending).toBeNull();
}

get fun `test convert: slippage breach is flagged but usdt still credited`() {
    val w = setupWorld();
    fundPot(w, ton("10"));
    convert(w, ton("5"), 100 * USDT_UNIT);

    val settle = arriveUsdt(w, 80 * USDT_UNIT);
    val breach = findEvent<SlippageBreachEvent>(settle, w.pot.address, EVENT_TOPIC_SLIPPAGE_BREACH);
    expect(breach).toBeNotNull();
    expect(breach!.kind).toEqual(PENDING_CONVERT);
    expect(breach!.expectedMin).toEqual(100 * USDT_UNIT);
    expect(breach!.received).toEqual(80 * USDT_UNIT);
    expect(w.pot.getPotData().usdtBudget).toEqual(80 * USDT_UNIT);
    expect(w.pot.getPotData().pending).toBeNull();
}

get fun `test convert: access, whitelist, threshold, reserve, floor, gas and single-flight guards`() {
    val w = setupWorld();
    fundPot(w, ton("10"));

    expect(w.pot.sendConvert(w.admin.address, 1, w.pool.address, ton("5"), floorUsdtFor(ton("5")), { value: ton("0.3"), bounce: true }))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.NotFromKeeper });
    // the vault itself is not a pool; neither is any other address
    expect(convert(w, ton("5"), 0, w.dex.address))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.DestNotWhitelisted });
    expect(convert(w, ton("5"), 0, w.escrow.address))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.DestNotWhitelisted });
    expect(convert(w, ton("4.99"), 0))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.BelowThreshold });
    // balance ~12 TON, reserve 1 TON -> 11.5 exceeds what can leave
    expect(convert(w, ton("11.5"), 0))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.BudgetExceeded });
    // one unit under the admin floor (2 USDT / TON) is refused
    expect(convert(w, ton("5"), floorUsdtFor(ton("5")) - 1))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.BelowFloor });
    // the keeper must fund the DEX gas chain
    expect(convert(w, ton("5"), 0, null, ton("0.2")))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.InsufficientValue });
    expect(w.pot.getPotData().totalTonSpent).toEqual(0);
    expect(w.pot.getPotData().pending).toBeNull();

    expect(convert(w, ton("5"), 0)).toHaveSuccessfulTx<Convert>({ to: w.pot.address });
    expect(convert(w, ton("5"), 0))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.OperationInFlight });
    expect(w.pot.getPotData().totalTonSpent).toEqual(ton("5"));
}

get fun `test convert: per-swap cap and a zero floor disable conversions`() {
    val w = setupWorld();
    fundPot(w, ton("100"));
    expect(convert(w, ton("51"), 0))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.BudgetExceeded });
    expect(convert(w, ton("50"), 0)).toHaveSuccessfulTx<Convert>({ to: w.pot.address });

    // admin sets floor 0: nothing can be converted any more, whatever the keeper declares
    var params = defaultParams(w.usdt.getWalletAddress(w.pot.address), defaultWhitelist(w.dex.address, w.pool.address, w.escrow.address));
    params.floorUsdtPerTon = 0;
    expect(w.pot.sendSetPotParams(w.admin.address, 0, params, { value: ton("0.05") })).toHaveSuccessfulTx<SetPotParams>({ to: w.pot.address });
    dexPayout(w, ton("50.2"));
    expect(w.pot.getPotData().pending).toBeNull();
    expect(convert(w, ton("5"), 1000 * USDT_UNIT))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.BelowFloor });
}

get fun `test convert: bounced swap restores accounting and clears pending`() {
    val w = setupWorld();
    fundPot(w, ton("10"));
    // point the whitelist at a vault that does not exist -> the swap bounces
    val ghost = w.collection.getNftAddressByIndex(424242);
    var wl = defaultWhitelist(w.dex.address, w.pool.address, w.escrow.address);
    wl.dexVault = ghost;
    expect(w.pot.sendSetPotParams(w.admin.address, 0, defaultParams(w.usdt.getWalletAddress(w.pot.address), wl), { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetPotParams>({ to: w.pot.address });

    val before = testing.getAccountBalance(w.pot.address);
    val res = convert(w, ton("5"), 0);
    expect(res).toHaveSuccessfulTx<Convert>({ to: w.pot.address });
    expect(res).toHaveTx({ from: ghost, to: w.pot.address });

    val data = w.pot.getPotData();
    expect(data.pending).toBeNull();
    expect(data.totalTonSpent).toEqual(0);
    // TON came back (minus forwarding fees)
    expect(before - testing.getAccountBalance(w.pot.address) < ton("0.1")).toBeTrue();
}

get fun `test convert: dex payout of the full amount undoes the conversion, leftover gas is just kept`() {
    val w = setupWorld();
    fundPot(w, ton("10"));
    convert(w, ton("5"), 0);
    expect(w.pot.getPotData().pending).toBeNotNull();

    // only the vault may speak payout
    expect(net.send(w.escrow.address, createMessage({ bounce: true, value: ton("5.2"), dest: w.pot.address, body: DedustPayout { queryId: 1, payload: null } })))
        .toHaveFailedTx<DedustPayout>({ to: w.pot.address, exitCode: Errors.DestNotWhitelisted });

    // leftover gas after a successful swap: nothing changes
    expect(dexPayout(w, ton("0.1"))).toHaveSuccessfulTx<DedustPayout>({ from: w.dex.address, to: w.pot.address });
    expect(w.pot.getPotData().pending).toBeNotNull();
    expect(w.pot.getPotData().totalTonSpent).toEqual(ton("5"));

    // rejected swap (limit not met): the whole amount comes back, accounting is restored
    val before = testing.getAccountBalance(w.pot.address);
    val res = dexPayout(w, ton("5.1"));
    expect(res).toHaveSuccessfulTx<DedustPayout>({ from: w.dex.address, to: w.pot.address });
    val ev = findEvent<PendingCancelledEvent>(res, w.pot.address, EVENT_TOPIC_PENDING_CANCELLED);
    expect(ev!.kind).toEqual(PENDING_CONVERT);
    expect(ev!.spend).toEqual(ton("5"));
    expect(w.pot.getPotData().pending).toBeNull();
    expect(w.pot.getPotData().totalTonSpent).toEqual(0);
    expect(testing.getAccountBalance(w.pot.address) - before > ton("5.09")).toBeTrue();

    // a new convert can start right away
    expect(convert(w, ton("5"), 0)).toHaveSuccessfulTx<Convert>({ to: w.pot.address });
}

// ---------------------------------------------------------------------------
// Round (USDT -> escrow -> stock)
// ---------------------------------------------------------------------------

get fun `test round: pot transfers usdt to escrow, stock arrival settles and advances rotation`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    mintDesk(w, testing.treasury("b").address);
    arriveUsdt(w, 1000 * USDT_UNIT);

    val res = round(w, 0, 400 * USDT_UNIT, 5 * STOCK_UNIT);
    expect(res).toHaveSuccessfulTx<Round>({ from: w.keeper.address, to: w.pot.address });
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: w.pot.address, to: w.usdt.getWalletAddress(w.pot.address) });
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.escrow.address });
    expect(w.usdt.walletOf(w.escrow.address).getJettonBalance()).toEqual(400 * USDT_UNIT);
    expect(w.usdt.walletOf(w.pot.address).getJettonBalance()).toEqual(600 * USDT_UNIT);

    var data = w.pot.getPotData();
    expect(data.usdtBudget).toEqual(600 * USDT_UNIT);
    expect(data.pending!.kind).toEqual(PENDING_ROUND);
    expect(data.pending!.slot).toEqual(0);
    expect(data.pending!.spend).toEqual(400 * USDT_UNIT);
    expect(data.rotationNext).toEqual(0);

    val fill = arriveStock(w, 0, 10 * STOCK_UNIT);
    val ev = findEvent<RoundSettledEvent>(fill, w.pot.address, EVENT_TOPIC_ROUND_SETTLED);
    expect(ev).toBeNotNull();
    expect(ev!.roundNo).toEqual(1);
    expect(ev!.slot).toEqual(0);
    expect(ev!.spendUsdt).toEqual(400 * USDT_UNIT);
    expect(ev!.received).toEqual(10 * STOCK_UNIT);
    expect(ev!.liveDesks).toEqual(2);
    expect(countEvents(fill, w.pot.address, EVENT_TOPIC_SLIPPAGE_BREACH)).toEqual(0);

    data = w.pot.getPotData();
    expect(data.pending).toBeNull();
    expect(data.roundNo).toEqual(1);
    expect(data.rotationNext).toEqual(1);
    expect(w.pot.getSlot(0)!.counter).toEqual(10 * STOCK_UNIT * COUNTER_SCALE / 2);
}

get fun `test round: advance=false keeps the rotation on the same slot (fractionated rounds)`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);

    round(w, 0, 100 * USDT_UNIT, 0, false);
    arriveStock(w, 0, 1 * STOCK_UNIT);
    expect(w.pot.getPotData().rotationNext).toEqual(0);
    expect(w.pot.getPotData().roundNo).toEqual(1);

    round(w, 0, 100 * USDT_UNIT, 0, true);
    arriveStock(w, 0, 1 * STOCK_UNIT);
    expect(w.pot.getPotData().rotationNext).toEqual(1);
    expect(w.pot.getPotData().roundNo).toEqual(2);
    expect(w.pot.getPotData().usdtBudget).toEqual(800 * USDT_UNIT);
}

get fun `test round: short fill emits slippage breach yet settles`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);
    round(w, 0, 100 * USDT_UNIT, 5 * STOCK_UNIT);

    val fill = arriveStock(w, 0, 4 * STOCK_UNIT);
    val breach = findEvent<SlippageBreachEvent>(fill, w.pot.address, EVENT_TOPIC_SLIPPAGE_BREACH);
    expect(breach).toBeNotNull();
    expect(breach!.kind).toEqual(PENDING_ROUND);
    expect(breach!.slot).toEqual(0);
    expect(w.pot.getPotData().pending).toBeNull();
    expect(w.pot.getPotData().rotationNext).toEqual(1);
}

get fun `test round: stock for another slot during a pending round is a donation, round stays pending`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);
    round(w, 0, 100 * USDT_UNIT, 0);

    val other = arriveStock(w, 1, 3 * STOCK_UNIT);
    val ev = findEvent<RoundSettledEvent>(other, w.pot.address, EVENT_TOPIC_ROUND_SETTLED);
    expect(ev!.spendUsdt).toEqual(0);
    expect(ev!.slot).toEqual(1);
    expect(w.pot.getPotData().pending).toBeNotNull();
    expect(w.pot.getPotData().rotationNext).toEqual(0);
    expect(w.pot.getSlot(1)!.counter).toEqual(3 * STOCK_UNIT * COUNTER_SCALE);
}

get fun `test round: escrow refund restores the usdt budget`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);
    round(w, 0, 400 * USDT_UNIT, 0);
    expect(w.pot.getPotData().usdtBudget).toEqual(600 * USDT_UNIT);

    // resolver never filled: escrow sends the USDT back
    val refund = w.usdt.walletOf(w.escrow.address).sendTransfer(w.escrow.address, ton("0.2"), 400 * USDT_UNIT, w.pot.address, w.escrow.address, null, ton("0.05"), null);
    expect(refund).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.pot.address });
    val ev = findEvent<RoundRefundedEvent>(refund, w.pot.address, EVENT_TOPIC_ROUND_REFUNDED);
    expect(ev).toBeNotNull();
    expect(ev!.slot).toEqual(0);
    expect(ev!.spendUsdt).toEqual(400 * USDT_UNIT);
    expect(ev!.refunded).toEqual(400 * USDT_UNIT);

    val data = w.pot.getPotData();
    expect(data.usdtBudget).toEqual(1000 * USDT_UNIT);
    expect(data.pending).toBeNull();
    expect(data.rotationNext).toEqual(0);
    expect(data.roundNo).toEqual(0);
}

get fun `test round: guards — keeper only, live desks, rotation, budget, payload, value, single flight`() {
    val w = setupWorld();
    arriveUsdt(w, 1000 * USDT_UNIT);

    expect(round(w, 0, 100 * USDT_UNIT, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.NoLiveDesks });
    mintDesk(w, testing.treasury("a").address);

    val min100 = floorStockFor(100 * USDT_UNIT);
    expect(w.pot.sendRound(w.admin.address, 2, 0, 100 * USDT_UNIT, min100, ton("0.1"), true, escrowPayloadFor(w.pot.address, min100), { value: ton("0.4"), bounce: true }))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.NotFromKeeper });
    expect(round(w, 1, 100 * USDT_UNIT, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.NotRotationNext });
    expect(round(w, 0, 1001 * USDT_UNIT, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.BudgetExceeded });
    expect(round(w, 0, 0, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.BudgetExceeded });
    // keeper minimum under the slot floor
    expect(round(w, 0, 100 * USDT_UNIT, min100 - 1, true, escrowPayloadFor(w.pot.address, min100 - 1)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.BelowFloor });
    expect(round(w, 0, 100 * USDT_UNIT, 0, true, escrowPayloadFor(w.keeper.address, min100)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.PayloadOwnerMismatch });
    // payload promises the resolver may deliver less than the keeper declared
    expect(round(w, 0, 100 * USDT_UNIT, 0, true, escrowPayloadFor(w.pot.address, min100 - 1)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.PayloadMinOutMismatch });
    // a payload min-out above the declared minimum is fine (declared is the floor the Pot enforces)
    val wrongOp = beginCell().storeUint(0x11111111, 32).storeUint(0, 256).storeUint(0, ESCROW_OWNER_BIT_OFFSET - 32 - 256).storeAddress(w.pot.address).storeRef(escrowParamsWithMinOut(min100)).endCell();
    expect(round(w, 0, 100 * USDT_UNIT, 0, true, wrongOp))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.DestNotWhitelisted });
    expect(round(w, 0, 100 * USDT_UNIT, 0, true, null, ton("0.15")))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.InsufficientValue });

    // nothing left the pot
    expect(w.pot.getPotData().usdtBudget).toEqual(1000 * USDT_UNIT);
    expect(w.pot.getPotData().pending).toBeNull();
    expect(w.usdt.walletOf(w.pot.address).getJettonBalance()).toEqual(1000 * USDT_UNIT);

    expect(round(w, 0, 100 * USDT_UNIT, 0, true, escrowPayloadFor(w.pot.address, min100 + 1))).toHaveSuccessfulTx<Round>({ to: w.pot.address });
    expect(round(w, 0, 100 * USDT_UNIT, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.OperationInFlight });
    expect(convert(w, ton("5"), 0))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.OperationInFlight });
}

get fun `test round: slot floor is admin-managed and a zero floor disables the slot's rounds`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);

    expect(w.pot.sendSetSlotFloor(w.keeper.address, 0, 0, 1, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSlotFloor>({ to: w.pot.address, exitCode: Errors.NotFromAdmin });
    expect(w.pot.sendSetSlotFloor(w.admin.address, 0, 9, 1, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSlotFloor>({ to: w.pot.address, exitCode: Errors.SlotUnknown });

    // raise the floor tenfold: yesterday's minimum is refused, the new one passes
    expect(w.pot.sendSetSlotFloor(w.admin.address, 0, 0, FLOOR_STOCK_PER_USDT * 10, { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetSlotFloor>({ to: w.pot.address });
    expect(w.pot.getSlot(0)!.floorPerUsdt).toEqual(FLOOR_STOCK_PER_USDT * 10);
    val old = floorStockFor(100 * USDT_UNIT);
    expect(round(w, 0, 100 * USDT_UNIT, old, true, escrowPayloadFor(w.pot.address, old)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.BelowFloor });
    expect(round(w, 0, 100 * USDT_UNIT, old * 10, true, escrowPayloadFor(w.pot.address, old * 10)))
        .toHaveSuccessfulTx<Round>({ to: w.pot.address });
    arriveStock(w, 0, 1 * STOCK_UNIT);

    // floor 0 = slot 1 cannot be bought, whatever the keeper promises
    expect(w.pot.sendSetSlotFloor(w.admin.address, 0, 1, 0, { value: ton("0.05") })).toHaveSuccessfulTx<SetSlotFloor>({ to: w.pot.address });
    expect(round(w, 1, 100 * USDT_UNIT, 1000 * STOCK_UNIT, true, escrowPayloadFor(w.pot.address, 1000 * STOCK_UNIT)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.BelowFloor });
}

get fun `test round: max round size is enforced`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 10000 * USDT_UNIT);
    expect(round(w, 0, 5001 * USDT_UNIT, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.BudgetExceeded });
    expect(round(w, 0, 5000 * USDT_UNIT, 0)).toHaveSuccessfulTx<Round>({ to: w.pot.address });
}

// ---------------------------------------------------------------------------
// CancelPending / SkipSlot
// ---------------------------------------------------------------------------

get fun `test cancel: only after timeout, late usdt still credited afterwards`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);
    round(w, 0, 400 * USDT_UNIT, 0);

    expect(w.pot.sendCancelPending(w.admin.address, 3, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<CancelPending>({ to: w.pot.address, exitCode: Errors.NotFromKeeper });
    expect(w.pot.sendCancelPending(w.keeper.address, 3, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<CancelPending>({ to: w.pot.address, exitCode: Errors.PendingNotExpired });

    testing.setNow(WORLD_T0 + 599);
    expect(w.pot.sendCancelPending(w.keeper.address, 3, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<CancelPending>({ to: w.pot.address, exitCode: Errors.PendingNotExpired });

    testing.setNow(WORLD_T0 + 600);
    val res = w.pot.sendCancelPending(w.keeper.address, 3, { value: ton("0.05"), bounce: true });
    expect(res).toHaveSuccessfulTx<CancelPending>({ to: w.pot.address });
    val ev = findEvent<PendingCancelledEvent>(res, w.pot.address, EVENT_TOPIC_PENDING_CANCELLED);
    expect(ev!.kind).toEqual(PENDING_ROUND);
    expect(ev!.spend).toEqual(400 * USDT_UNIT);
    expect(w.pot.getPotData().pending).toBeNull();
    expect(w.pot.getPotData().usdtBudget).toEqual(600 * USDT_UNIT);

    expect(w.pot.sendCancelPending(w.keeper.address, 3, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<CancelPending>({ to: w.pot.address, exitCode: Errors.NothingPending });

    // the escrow refund shows up late: budget is credited, no round bookkeeping touched
    val late = w.usdt.walletOf(w.escrow.address).sendTransfer(w.escrow.address, ton("0.2"), 400 * USDT_UNIT, w.pot.address, w.escrow.address, null, ton("0.05"), null);
    expect(late).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.pot.address });
    expect(countEvents(late, w.pot.address, EVENT_TOPIC_ROUND_REFUNDED)).toEqual(0);
    expect(countEvents(late, w.pot.address, EVENT_TOPIC_POT_IN)).toEqual(1);
    expect(w.pot.getPotData().usdtBudget).toEqual(1000 * USDT_UNIT);
    expect(w.pot.getPotData().roundNo).toEqual(0);
}

get fun `test cancel: stale convert is cleared, late usdt after it is plain income`() {
    val w = setupWorld();
    fundPot(w, ton("10"));
    convert(w, ton("5"), 100 * USDT_UNIT);
    testing.setNow(WORLD_T0 + 600);
    expect(w.pot.sendCancelPending(w.keeper.address, 3, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<CancelPending>({ to: w.pot.address });
    expect(w.pot.getPotData().totalTonSpent).toEqual(ton("5"));

    val late = arriveUsdt(w, 100 * USDT_UNIT);
    expect(countEvents(late, w.pot.address, EVENT_TOPIC_CONVERT_SETTLED)).toEqual(0);
    expect(w.pot.getPotData().usdtBudget).toEqual(100 * USDT_UNIT);
}

get fun `test skip: rotation advances cyclically over enabled slots, blocked while pending`() {
    val w = setupWorld();
    expect(w.pot.sendSkipSlot(w.admin.address, 4, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SkipSlot>({ to: w.pot.address, exitCode: Errors.NotFromKeeper });

    var res = w.pot.sendSkipSlot(w.keeper.address, 4, { value: ton("0.05"), bounce: true });
    expect(res).toHaveSuccessfulTx<SkipSlot>({ to: w.pot.address });
    val ev = findEvent<SlotSkippedEvent>(res, w.pot.address, EVENT_TOPIC_SLOT_SKIPPED);
    expect(ev!.slot).toEqual(0);
    expect(ev!.next).toEqual(1);
    expect(w.pot.getPotData().rotationNext).toEqual(1);

    res = w.pot.sendSkipSlot(w.keeper.address, 4, { value: ton("0.05"), bounce: true });
    expect(w.pot.getPotData().rotationNext).toEqual(0);

    // disabling the current slot moves the rotation; skip then jumps over it
    expect(w.pot.sendSetSlotEnabled(w.admin.address, 0, 0, false, { value: ton("0.05") })).toHaveSuccessfulTx<SetSlotEnabled>({ to: w.pot.address });
    expect(w.pot.getPotData().rotationNext).toEqual(1);
    w.pot.sendSkipSlot(w.keeper.address, 4, { value: ton("0.05"), bounce: true });
    expect(w.pot.getPotData().rotationNext).toEqual(1);
    expect(w.pot.sendSetSlotEnabled(w.admin.address, 0, 0, true, { value: ton("0.05") })).toHaveSuccessfulTx<SetSlotEnabled>({ to: w.pot.address });
    w.pot.sendSkipSlot(w.keeper.address, 4, { value: ton("0.05"), bounce: true });
    expect(w.pot.getPotData().rotationNext).toEqual(0);

    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);
    round(w, 0, 100 * USDT_UNIT, 0);
    expect(w.pot.sendSkipSlot(w.keeper.address, 4, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SkipSlot>({ to: w.pot.address, exitCode: Errors.OperationInFlight });
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

get fun `test admin: slot management and role checks`() {
    val w = setupWorld();
    val stock2 = deployJetton(w.issuer, "TSLAx");

    expect(w.pot.sendAddSlot(w.keeper.address, 0, 2, stock2.address, stock2.getWalletAddress(w.pot.address), FLOOR_STOCK_PER_USDT, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<AddSlot>({ to: w.pot.address, exitCode: Errors.NotFromAdmin });
    expect(w.pot.sendAddSlot(w.admin.address, 0, 0, stock2.address, stock2.getWalletAddress(w.pot.address), FLOOR_STOCK_PER_USDT, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<AddSlot>({ to: w.pot.address, exitCode: Errors.SlotExists });
    expect(w.pot.sendAddSlot(w.admin.address, 0, 64, stock2.address, stock2.getWalletAddress(w.pot.address), FLOOR_STOCK_PER_USDT, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<AddSlot>({ to: w.pot.address, exitCode: Errors.InvalidParams });
    expect(w.pot.sendAddSlot(w.admin.address, 0, 2, stock2.address, stock2.getWalletAddress(w.pot.address), FLOOR_STOCK_PER_USDT, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<AddSlot>({ to: w.pot.address });
    expect(w.pot.getPotData().slotCount).toEqual(3);
    expect(w.pot.getSlot(2)!.master).toEqual(stock2.address);

    expect(w.pot.sendSetSlotEnabled(w.keeper.address, 0, 2, false, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSlotEnabled>({ to: w.pot.address, exitCode: Errors.NotFromAdmin });
    expect(w.pot.sendSetSlotEnabled(w.admin.address, 0, 9, false, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSlotEnabled>({ to: w.pot.address, exitCode: Errors.SlotUnknown });

    // a new slot's stamps start at the current counter for freshly minted desks
    val desk = mintDesk(w, testing.treasury("a").address);
    expect(stampOf(desk, 2)).toEqual(0);
    arriveStock(w, 0, 1 * STOCK_UNIT);
    val desk2 = mintDesk(w, testing.treasury("b").address);
    expect(stampOf(desk2, 0)).toEqual(1 * STOCK_UNIT * COUNTER_SCALE);

    val roles = PotRoles { admin: w.keeper.address, keeper: w.keeper.address, collection: w.collection.address, deskItemCode: build("DeskItem") };
    expect(w.pot.sendSetPotRoles(w.keeper.address, 0, roles, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetPotRoles>({ to: w.pot.address, exitCode: Errors.NotFromAdmin });
    expect(w.pot.sendSetPotParams(w.keeper.address, 0, defaultParams(null, defaultWhitelist(w.dex.address, w.pool.address, w.escrow.address)), { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetPotParams>({ to: w.pot.address, exitCode: Errors.NotFromAdmin });
    expect(w.pot.sendSetPotRoles(w.admin.address, 0, roles, { value: ton("0.05") })).toHaveSuccessfulTx<SetPotRoles>({ to: w.pot.address });
    expect(w.pot.sendSetPotRoles(w.admin.address, 0, roles, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetPotRoles>({ to: w.pot.address, exitCode: Errors.NotFromAdmin });
}

get fun `test round: requires the usdt wallet to be configured`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    expect(w.pot.sendSetPotParams(w.admin.address, 0, defaultParams(null, defaultWhitelist(w.dex.address, w.pool.address, w.escrow.address)), { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetPotParams>({ to: w.pot.address });
    fundPot(w, ton("10"));
    expect(convert(w, ton("5"), 0))
        .toHaveFailedTx<Convert>({ to: w.pot.address, exitCode: Errors.UsdtWalletUnset });
    expect(round(w, 0, 1, 0))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.UsdtWalletUnset });
}
