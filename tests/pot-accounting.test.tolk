import "@stdlib/strings"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/common/tep-nft"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/pot/pot-messages"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/Pot.gen"
import "@wrappers/utils"
import "@tests/fixtures"

get fun `test pot: stock arriving is split equally across live desks via counters`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val c = testing.treasury("c");
    val deskA = mintDesk(w, a.address);
    val deskB = mintDesk(w, b.address);
    val deskC = mintDesk(w, c.address);

    arriveStock(w, 0, 300 * STOCK_UNIT);

    val slot = w.pot.getSlot(0)!;
    expect(slot.counter).toEqual(100 * STOCK_UNIT * COUNTER_SCALE);
    expect(w.pot.getOwed(0, 0)).toEqual(100 * STOCK_UNIT);
    expect(w.pot.getOwed(1, 0)).toEqual(0);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(300 * STOCK_UNIT);

    // each desk sweeps its share
    val resA = sweep(w, deskA, a.address, 0b01);
    expect(resA).toHaveSuccessfulTx<SweepRequest>({ from: deskA.address, to: w.pot.address });
    expect(resA).toHaveSuccessfulTx<AskToTransfer>({ from: w.pot.address, to: potStockWallet(w, 0).address });
    expect(resA).toHaveSuccessfulTx<SweepAck>({ from: w.pot.address, to: deskA.address });
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(100 * STOCK_UNIT);
    expect(stampOf(deskA, 0)).toEqual(slot.counter);
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();

    sweep(w, deskB, b.address, 0b01);
    sweep(w, deskC, c.address, 0b01);
    expect(deskStockWallet(w, 0, deskB).getJettonBalance()).toEqual(100 * STOCK_UNIT);
    expect(deskStockWallet(w, 0, deskC).getJettonBalance()).toEqual(100 * STOCK_UNIT);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(0);

    // sweeping again pays nothing and does not touch the jetton wallet
    val again = sweep(w, deskA, a.address, 0b01);
    expect(again).toHaveSuccessfulTx<SweepAck>({ from: w.pot.address, to: deskA.address });
    expect(again).toNotHaveTx<AskToTransfer>({ from: w.pot.address });
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(100 * STOCK_UNIT);
}

get fun `test pot: a desk minted after a round does not share it`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val late = testing.treasury("late");
    val deskA = mintDesk(w, a.address);
    arriveStock(w, 0, 50 * STOCK_UNIT);

    val deskLate = mintDesk(w, late.address);
    // its stamp snapshot equals the current counter
    expect(stampOf(deskLate, 0)).toEqual(w.pot.getSlot(0)!.counter);
    expect(w.pot.getOwed(0, stampOf(deskLate, 0))).toEqual(0);

    // next arrival is split between the two
    arriveStock(w, 0, 20 * STOCK_UNIT);
    sweep(w, deskA, a.address, 0b01);
    sweep(w, deskLate, late.address, 0b01);
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(60 * STOCK_UNIT);
    expect(deskStockWallet(w, 0, deskLate).getJettonBalance()).toEqual(10 * STOCK_UNIT);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(0);
}

get fun `test pot: sweep of several slots in one message`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val deskA = mintDesk(w, a.address);
    arriveStock(w, 0, 7 * STOCK_UNIT);
    arriveStock(w, 1, 3 * STOCK_UNIT);

    val res = sweep(w, deskA, a.address, 0b11, ton("0.5"));
    expect(res).toHaveSuccessfulTx<SweepRequest>({ from: deskA.address, to: w.pot.address, body: fun(b: cell): bool { return SweepRequest.fromCell(b).slot == 0; } });
    expect(res).toHaveSuccessfulTx<SweepRequest>({ from: deskA.address, to: w.pot.address, body: fun(b: cell): bool { return SweepRequest.fromCell(b).slot == 1; } });
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(7 * STOCK_UNIT);
    expect(deskStockWallet(w, 1, deskA).getJettonBalance()).toEqual(3 * STOCK_UNIT);
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();
    // excess TON came back to the owner
    expect(res).toHaveTx<ReturnExcessesBack>({ from: deskA.address, to: a.address });
}

get fun `test pot: rounding dust never exceeds the pot balance`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val c = testing.treasury("c");
    val deskA = mintDesk(w, a.address);
    val deskB = mintDesk(w, b.address);
    val deskC = mintDesk(w, c.address);

    arriveStock(w, 0, 100); // 100 units / 3 desks -> 33 each, 1 unit of dust stays
    sweep(w, deskA, a.address, 0b01);
    sweep(w, deskB, b.address, 0b01);
    sweep(w, deskC, c.address, 0b01);
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(33);
    expect(deskStockWallet(w, 0, deskB).getJettonBalance()).toEqual(33);
    expect(deskStockWallet(w, 0, deskC).getJettonBalance()).toEqual(33);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(1);
}

get fun `test pot: sweep is refused for strangers and unknown desks`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val stranger = testing.treasury("stranger");
    val deskA = mintDesk(w, a.address);
    arriveStock(w, 0, 10 * STOCK_UNIT);

    // not the owner
    expect(sweep(w, deskA, stranger.address, 0b01))
        .toHaveFailedTx<Sweep>({ to: deskA.address, exitCode: Errors.NotFromOwner });

    // a forged SweepRequest straight to the pot is rejected (sender is not a desk address)
    val forged = w.pot.sendSweepRequest(stranger.address, 0, 0, 0, 0, { value: ton("0.2"), bounce: true });
    expect(forged).toHaveFailedTx<SweepRequest>({ to: w.pot.address, exitCode: Errors.NotFromDesk });

    // wrong serial claimed by a real desk address cannot happen (serial is in storage), but a
    // desk from another collection would compute to a different address: emulate with a treasury
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(10 * STOCK_UNIT);
}

get fun `test pot: sweep for unknown slot bounces and clears the pending flag`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val deskA = mintDesk(w, a.address);
    val res = sweep(w, deskA, a.address, 1 << 5);
    expect(res).toHaveFailedTx<SweepRequest>({ from: deskA.address, to: w.pot.address, exitCode: Errors.SlotUnknown });
    expect(res).toHaveBouncedTx({ to: deskA.address });
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();
}

get fun `test pot: a slot with an in-flight sweep refuses a second sweep`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val deskA = mintDesk(w, a.address);
    arriveStock(w, 0, 10 * STOCK_UNIT);

    // run the Sweep tx only (stop before the Pot processes the request)
    val msg = createMessage({ bounce: true, value: ton("0.3"), dest: deskA.address, body: Sweep { queryId: 0, slotsMask: 0b01 } });
    val cursor = testing.createTraceIterationCursor(a.address, msg);
    val first = cursor.executeN(1);
    expect(first).toHaveSuccessfulTx<Sweep>({ to: deskA.address });
    expect(deskA.getDeskData().pending.exists(0)).toBeTrue();

    val second = sweep(w, deskA, a.address, 0b01);
    expect(second).toHaveFailedTx<Sweep>({ to: deskA.address, exitCode: Errors.SlotBusy });

    cursor.executeAllRemaining();
    cursor.close();
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(10 * STOCK_UNIT);
}

get fun `test pot: withdraw is refused while stock is owed and allowed after a sweep`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val deskA = mintDesk(w, a.address);
    arriveStock(w, 0, 10 * STOCK_UNIT);

    val deskWallet = deskStockWallet(w, 0, deskA);
    val owed = deskA.sendWithdraw(a.address, 0, 0, deskWallet.address, 1, a.address, { value: ton("0.3"), bounce: true });
    expect(owed).toHaveFailedTx<WithdrawViaPot>({ from: deskA.address, to: w.pot.address, exitCode: Errors.RoundOwed });
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();

    val swept = sweep(w, deskA, a.address, 0b01);
    expect(deskWallet.getJettonBalance()).toEqual(10 * STOCK_UNIT);
    val sweptEv = findEvent<DeskSweptEvent>(swept, w.pot.address, EVENT_TOPIC_DESK_SWEPT);
    expect(sweptEv != null).toBeTrue();
    expect(sweptEv!.serial).toEqual(deskA.getDeskData().serial);
    expect(sweptEv!.slot).toEqual(0);
    expect(sweptEv!.owed).toEqual(10 * STOCK_UNIT);
    expect(sweptEv!.newStamp).toEqual(w.pot.getSlot(0)!.counter);

    val ok = deskA.sendWithdraw(a.address, 0, 0, deskWallet.address, 4 * STOCK_UNIT, a.address, { value: ton("0.3"), bounce: true });
    expect(ok).toHaveSuccessfulTx<WithdrawViaPot>({ from: deskA.address, to: w.pot.address });
    val wdEv = findEvent<DeskWithdrawnEvent>(ok, w.pot.address, EVENT_TOPIC_DESK_WITHDRAWN);
    expect(wdEv != null).toBeTrue();
    expect(wdEv!.slot).toEqual(0);
    expect(wdEv!.amount).toEqual(4 * STOCK_UNIT);
    expect(wdEv!.to == a.address).toBeTrue();
    expect(ok).toHaveSuccessfulTx<WithdrawOk>({ from: w.pot.address, to: deskA.address });
    expect(ok).toHaveSuccessfulTx<AskToTransfer>({ from: deskA.address, to: deskWallet.address });
    expect(deskWallet.getJettonBalance()).toEqual(6 * STOCK_UNIT);
    expect(w.stock0.walletOf(a.address).getJettonBalance()).toEqual(4 * STOCK_UNIT);
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();
}

get fun `test pot: withdraw is owner-only and needs value`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val stranger = testing.treasury("stranger");
    val deskA = mintDesk(w, a.address);
    val deskWallet = deskStockWallet(w, 0, deskA);
    expect(deskA.sendWithdraw(stranger.address, 0, 0, deskWallet.address, 1, stranger.address, { value: ton("0.3"), bounce: true }))
        .toHaveFailedTx<Withdraw>({ to: deskA.address, exitCode: Errors.NotFromOwner });
    expect(deskA.sendWithdraw(a.address, 0, 0, deskWallet.address, 1, a.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<Withdraw>({ to: deskA.address, exitCode: Errors.InsufficientValue });
}

get fun `test pot: desk transfer moves the vault with the nft`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val deskA = mintDesk(w, a.address);
    arriveStock(w, 0, 10 * STOCK_UNIT);

    val res = deskA.sendAskToChangeOwnership(a.address, 0, b.address, a.address, null, 0, PayloadInline { value: beginCell().storeUint(0, 1).toSlice() }, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx<AskToChangeOwnership>({ to: deskA.address });
    expect(deskA.getNftData().ownerAddress!).toEqual(b.address);

    // old owner can no longer sweep, new owner receives the stock into the desk vault
    expect(sweep(w, deskA, a.address, 0b01)).toHaveFailedTx<Sweep>({ to: deskA.address, exitCode: Errors.NotFromOwner });
    sweep(w, deskA, b.address, 0b01);
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(10 * STOCK_UNIT);
}

get fun `test pot: stamps init can only come from the pot and only once`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val stranger = testing.treasury("stranger");
    val deskA = mintDesk(w, a.address);
    var fake: map<uint8, uint128> = createEmptyMap();
    fake.set(0, 0);
    expect(deskA.sendStampsInit(stranger.address, 0, fake, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<StampsInit>({ to: deskA.address, exitCode: Errors.NotFromPot });
    // a second init from the pot address itself is refused too
    expect(deskA.sendStampsInit(w.pot.address, 0, fake, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<StampsInit>({ to: deskA.address, exitCode: Errors.AlreadyInitialized });
}

get fun `test pot: stock arriving with no live desk stays unallocated`() {
    val w = setupWorld();
    arriveStock(w, 0, 10 * STOCK_UNIT);
    expect(w.pot.getSlot(0)!.counter).toEqual(0);
    val a = testing.treasury("a");
    val deskA = mintDesk(w, a.address);
    sweep(w, deskA, a.address, 0b01);
    expect(deskStockWallet(w, 0, deskA).getJettonBalance()).toEqual(0);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(10 * STOCK_UNIT);
}

get fun `test pot: notification from an unknown jetton wallet is rejected`() {
    val w = setupWorld();
    val rogue = deployJetton(w.issuer, "ROGUE");
    val res = rogue.sendMint(w.issuer.address, w.pot.address, 5, ton("0.05"), ton("0.3"));
    expect(res).toHaveFailedTx<TransferNotificationForRecipient>({ to: w.pot.address, exitCode: Errors.UnknownJettonWallet });
    expect(w.pot.getSlot(0)!.counter).toEqual(0);
    expect(w.pot.getSlot(1)!.counter).toEqual(0);
}

get fun `test pot: plain ton and top-ups are accounted, unknown opcodes bounce`() {
    val w = setupWorld();
    val donor = testing.treasury("donor");
    val before = w.pot.getPotData();
    val balanceBefore = testing.getAccountBalance(w.pot.address);
    expect(w.pot.sendAny(donor.address, createEmptyCell(), { value: ton("3"), bounce: true })).toHaveTx({ to: w.pot.address, success: true });
    expect(w.pot.sendPotTopUp(donor.address, 0, 1, { value: ton("2"), bounce: true })).toHaveSuccessfulTx<PotTopUp>({ to: w.pot.address });
    val after = w.pot.getPotData();
    expect(after.totalTonIn - before.totalTonIn).toEqual(ton("5"));
    expect(testing.getAccountBalance(w.pot.address) - balanceBefore > ton("4.9")).toBeTrue();
    expect(w.pot.sendAny(donor.address, beginCell().storeUint(0x11223344, 32).storeUint(0, 64).endCell(), { value: ton("1"), bounce: true }))
        .toHaveTx({ to: w.pot.address, success: false, exitCode: 0xFFFF });
    expect(w.pot.getPotData().totalTonIn).toEqual(after.totalTonIn);
}

// ---------------------------------------------------------------------------
// Property: for any sequence of arrivals and mints, the sum of what desks can sweep never
// exceeds the pot wallet balance, counters are monotone, and every sweep pays exactly get_owed.
// ---------------------------------------------------------------------------

@test.fuzz(24)
get fun `test pot: fuzz — sweepable total never exceeds pot balance`(seedDesks: int, amount1: int, amount2: int, amount3: int) {
    val nDesks = fuzz.bound(seedDesks, 1, 7);
    val a1 = fuzz.bound(amount1, 1, 1000 * STOCK_UNIT);
    val a2 = fuzz.bound(amount2, 0, 1000 * STOCK_UNIT);
    val a3 = fuzz.bound(amount3, 1, 1000 * STOCK_UNIT);

    val w = setupWorld();
    expect(w.pot.getPotData().liveDesks).toEqual(0);
    var owners: map<uint8, address> = createEmptyMap();
    var i = 0;
    while (i < nDesks) {
        var b = StringBuilder.create();
        b.append("owner-");
        b.appendInt(i);
        val t = testing.treasury(b.build());
        mintDesk(w, t.address);
        owners.set(i as uint8, t.address);
        i += 1;
    }

    arriveStock(w, 0, a1);
    val c1 = w.pot.getSlot(0)!.counter;
    // one late desk after the first arrival
    val lateOwner = testing.treasury("late-owner");
    val lateDesk = mintDesk(w, lateOwner.address);
    if (a2 > 0) {
        arriveStock(w, 0, a2);
    }
    val c2 = w.pot.getSlot(0)!.counter;
    expect(c2 >= c1).toBeTrue();
    arriveStock(w, 0, a3);
    val c3 = w.pot.getSlot(0)!.counter;
    expect(c3 >= c2).toBeTrue();

    val potBalance = potStockWallet(w, 0).getJettonBalance();
    expect(potBalance).toEqual(a1 + a2 + a3);

    // total sweepable
    var total = nDesks * w.pot.getOwed(0, 0) + w.pot.getOwed(0, stampOf(lateDesk, 0));
    expect(total <= potBalance).toBeTrue();

    // sweep everyone and check each payout equals get_owed at the time
    i = 0;
    var paid = 0;
    while (i < nDesks) {
        val owner = owners.mustGet(i as uint8);
        val desk = DeskItem.fromAddress(w.collection.getNftAddressByIndex(i));
        val owed = w.pot.getOwed(0, stampOf(desk, 0));
        sweep(w, desk, owner, 0b01);
        expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(owed);
        paid += owed;
        i += 1;
    }
    val lateOwed = w.pot.getOwed(0, stampOf(lateDesk, 0));
    sweep(w, lateDesk, lateOwner.address, 0b01);
    expect(deskStockWallet(w, 0, lateDesk).getJettonBalance()).toEqual(lateOwed);
    paid += lateOwed;

    expect(paid).toEqual(total);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(potBalance - paid);
    // dust is bounded by one unit per desk per arrival
    expect(potBalance - paid <= 3 * (nDesks + 1)).toBeTrue();
}
