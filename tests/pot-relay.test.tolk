import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/desk/desk-messages"
import "@contracts/pot/pot-messages"
import "@contracts/pot/pot-types"
import "@contracts/pot/relay-messages"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskItem.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/PotRelay.gen"
import "@wrappers/utils"
import "@tests/fixtures"

// RelayOrder layout as the Pot reads it: opcode at 0, owner at bit 96, min-out (Coins) at bit 363 of the root.
const RELAY_OP = 0x52454c41
const RELAY_OWNER_BIT_OFFSET = 96
const RELAY_MIN_OUT_REF = 255
const RELAY_MIN_OUT_BIT_OFFSET = 363
const SWAP_FORWARD = ton("0.05")

struct RelayWorld {
    w: World
    relay: PotRelay
    /// plays the Omniston escrow minter (a plain wallet receiving the relay's USDT + payload)
    minter: Treasury
    swap: cell
}

fun relayWhitelist(w: World, relay: address): PotWhitelist {
    var wl = defaultWhitelist(w.dex.address, w.pool.address, relay);
    wl.escrowOp = RELAY_OP;
    wl.escrowOwnerBitOffset = RELAY_OWNER_BIT_OFFSET;
    wl.escrowMinOutRef = RELAY_MIN_OUT_REF;
    wl.escrowMinOutBitOffset = RELAY_MIN_OUT_BIT_OFFSET;
    return wl;
}

fun setupRelay(): RelayWorld {
    val w = setupWorld();
    val minter = testing.treasury("omniston-minter");
    // the relay's USDT wallet depends on the relay address, so it is pinned right after the deploy (same as prod)
    val roles = RelayRoles { admin: w.admin.address, keeper: w.keeper.address }.toCell();
    val relay = PotRelay.fromStorage({ pot: w.pot.address, escrowMinter: minter.address, usdtWallet: null, roles });
    expect(relay.deploy(w.admin.address, { value: ton("0.5"), bounce: false })).toHaveSuccessfulDeploy({ to: relay.address });
    expect(relay.sendSetUsdtWallet(w.admin.address, 0, w.usdt.getWalletAddress(relay.address), { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<SetUsdtWallet>({ to: relay.address });

    expect(w.pot.sendSetPotParams(
        w.admin.address,
        0,
        defaultParams(w.usdt.getWalletAddress(w.pot.address), relayWhitelist(w, relay.address)),
        { value: ton("0.05") },
    )).toHaveSuccessfulTx<SetPotParams>({ to: w.pot.address });

    val swap = beginCell().storeUint(0xc0a5f0d9, 32).storeUint(12345, 64).endCell();
    return { w, relay, minter, swap };
}

fun orderFor(rw: RelayWorld, minOut: coins, owner: address? = null): cell {
    return RelayOrder {
        queryId: 7,
        owner: owner == null ? rw.w.pot.address : owner!,
        minOut,
        swapForwardTon: SWAP_FORWARD,
        swap: rw.swap,
    }.toCell();
}

/// Keeper Round through the relay: `spendUsdt` at exactly the slot floor.
fun relayRound(rw: RelayWorld, spendUsdt: coins, order: cell? = null): SendResultList {
    val min = floorStockFor(spendUsdt);
    val payload = order == null ? orderFor(rw, min) : order!;
    return rw.w.pot.sendRound(rw.w.keeper.address, 2, 0, spendUsdt, min, ton("0.3"), true, payload, { value: ton("0.6"), bounce: true });
}

get fun `test relay: round moves usdt pot -> relay -> escrow minter with the omniston payload`() {
    val rw = setupRelay();
    val w = rw.w;
    mintDesk(w, w.issuer.address);
    arriveUsdt(w, 100 * USDT_UNIT);

    val res = relayRound(rw, 40 * USDT_UNIT);
    expect(res).toHaveSuccessfulTx<Round>({ from: w.keeper.address, to: w.pot.address });
    // the Pot's transfer lands in the relay's USDT wallet, which notifies the relay
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: rw.relay.address });
    // the relay forwards the exact amount to the escrow minter with the swap payload and forward TON
    val transferTx = res.findTransaction<AskToTransfer>({ from: rw.relay.address, to: w.usdt.getWalletAddress(rw.relay.address) });
    expect(transferTx).toBeNotNull();
    var t = transferTx!.loadBody<AskToTransfer>();
    expect(t.jettonAmount).toEqual(40 * USDT_UNIT);
    expect(t.transferRecipient).toEqual(rw.minter.address);
    expect(t.forwardTonAmount).toEqual(SWAP_FORWARD);
    expect(t.forwardPayload.loadBool()).toBeTrue();
    expect(t.forwardPayload.loadRef().hash()).toEqual(rw.swap.hash());
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: rw.minter.address });
    expect(w.usdt.walletOf(rw.minter.address).getJettonBalance()).toEqual(40 * USDT_UNIT);
    expect(w.usdt.walletOf(rw.relay.address).getJettonBalance()).toEqual(0);

    val data = w.pot.getPotData();
    expect(data.usdtBudget).toEqual(60 * USDT_UNIT);
    expect(data.pending).toBeNotNull();
    expect(data.pending!.kind).toEqual(PENDING_ROUND);
}

get fun `test relay: stock delivered without forward ton is flushed by anyone and settles the round`() {
    val rw = setupRelay();
    val w = rw.w;
    val desk = mintDesk(w, w.issuer.address);
    arriveUsdt(w, 100 * USDT_UNIT);
    relayRound(rw, 40 * USDT_UNIT);

    // resolver delivery: stock to the relay's wallet with forward_ton_amount = 0 -> no notification anywhere
    val delivered = 5 * STOCK_UNIT;
    val fill = w.stock0.sendMint(w.issuer.address, rw.relay.address, delivered, 0, ton("0.1"));
    expect(fill).toHaveSuccessfulTx<InternalTransferStep>({ to: w.stock0.getWalletAddress(rw.relay.address) });
    expect(w.pot.getPotData().pending).toBeNotNull();

    // a stranger flushes it to the Pot
    val stranger = testing.treasury("stranger");
    val before = testing.getAccountBalance(stranger.address);
    val flush = rw.relay.sendFlush(stranger.address, 9, w.stock0.getWalletAddress(rw.relay.address), delivered, { value: ton("0.15"), bounce: true });
    expect(flush).toHaveSuccessfulTx<Flush>({ from: stranger.address, to: rw.relay.address });
    expect(flush).toHaveSuccessfulTx<TransferNotificationForRecipient>({ from: w.stock0.getWalletAddress(w.pot.address), to: w.pot.address });
    val ev = findEvent<RoundSettledEvent>(flush, w.pot.address, EVENT_TOPIC_ROUND_SETTLED);
    expect(ev).toBeNotNull();
    expect(ev!.roundNo).toEqual(1);
    expect(ev!.slot).toEqual(0);
    expect(ev!.spendUsdt).toEqual(40 * USDT_UNIT);
    expect(ev!.received).toEqual(delivered);
    expect(ev!.liveDesks).toEqual(1);
    // excess gas came back to the stranger: the flush cost well under 0.1 TON
    expect(before - testing.getAccountBalance(stranger.address) < ton("0.1")).toBeTrue();

    val data = w.pot.getPotData();
    expect(data.pending).toBeNull();
    expect(data.roundNo).toEqual(1);
    expect(data.rotationNext).toEqual(1);
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(delivered);
    expect(w.stock0.walletOf(rw.relay.address).getJettonBalance()).toEqual(0);
    // the desk can now sweep the whole delivery (single live desk)
    val sweep = desk.sendSweep(w.issuer.address, 1, 1, { value: ton("0.3"), bounce: true });
    expect(sweep).toHaveSuccessfulTx<SweepRequest>({ from: desk.address, to: w.pot.address });
    expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(delivered);
}

get fun `test relay: guards — usdt flush is keeper-only, cheap flush refused, foreign usdt is not swapped, roles`() {
    val rw = setupRelay();
    val w = rw.w;
    mintDesk(w, w.issuer.address);
    val relayUsdt = w.usdt.getWalletAddress(rw.relay.address);

    // USDT sent to the relay by someone other than the Pot (with a valid-looking order) is ignored, not swapped
    val order = orderFor(rw, 1);
    val foreign = w.usdt.sendMint(w.issuer.address, rw.relay.address, 7 * USDT_UNIT, ton("0.2"), ton("0.4"), order);
    expect(foreign).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: rw.relay.address });
    expect(w.usdt.walletOf(rw.relay.address).getJettonBalance()).toEqual(7 * USDT_UNIT);
    expect(w.usdt.walletOf(rw.minter.address).getJettonBalance()).toEqual(0);

    // a stranger cannot flush the USDT wallet (it could refund a position in flight); too little value is refused
    val stranger = testing.treasury("stranger");
    expect(rw.relay.sendFlush(stranger.address, 1, relayUsdt, 7 * USDT_UNIT, { value: ton("0.15"), bounce: true }))
        .toHaveFailedTx<Flush>({ to: rw.relay.address, exitCode: Errors.NotFromKeeper });
    expect(rw.relay.sendFlush(w.keeper.address, 1, relayUsdt, 7 * USDT_UNIT, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<Flush>({ to: rw.relay.address, exitCode: Errors.InsufficientValue });
    // the keeper can: the USDT reaches the Pot's wallet and is booked as pot inflow (no pending op)
    val flush = rw.relay.sendFlush(w.keeper.address, 1, relayUsdt, 7 * USDT_UNIT, { value: ton("0.15"), bounce: true });
    expect(flush).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.pot.address });
    expect(w.pot.getPotData().usdtBudget).toEqual(7 * USDT_UNIT);
    expect(w.usdt.walletOf(rw.relay.address).getJettonBalance()).toEqual(0);

    // flushing a wallet the relay does not own is refused by that wallet (here: not even deployed) and bounces harmlessly
    val potStock = w.stock0.getWalletAddress(w.pot.address);
    val bad = rw.relay.sendFlush(stranger.address, 2, potStock, 1, { value: ton("0.15"), bounce: true });
    expect(bad).toHaveSuccessfulTx<Flush>({ to: rw.relay.address });
    expect(bad).toHaveTx({ from: potStock, to: rw.relay.address });
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(0);

    // roles
    expect(rw.relay.sendSetRelayRoles(stranger.address, 3, stranger.address, stranger.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetRelayRoles>({ to: rw.relay.address, exitCode: Errors.NotFromAdmin });
    expect(rw.relay.sendSetRelayRoles(w.admin.address, 3, w.admin.address, stranger.address, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<SetRelayRoles>({ to: rw.relay.address });
    val rd = rw.relay.getRelayData();
    expect(rd.keeper).toEqual(stranger.address);
    expect(rd.pot).toEqual(w.pot.address);
    expect(rd.usdtWallet).toEqual(relayUsdt);
}

get fun `test relay: the pot rejects an order whose owner or min-out does not match`() {
    val rw = setupRelay();
    val w = rw.w;
    mintDesk(w, w.issuer.address);
    arriveUsdt(w, 100 * USDT_UNIT);
    val min = floorStockFor(40 * USDT_UNIT);
    expect(relayRound(rw, 40 * USDT_UNIT, orderFor(rw, min, w.keeper.address)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.PayloadOwnerMismatch });
    expect(relayRound(rw, 40 * USDT_UNIT, orderFor(rw, min - 1)))
        .toHaveFailedTx<Round>({ to: w.pot.address, exitCode: Errors.PayloadMinOutMismatch });
    expect(w.pot.getPotData().pending).toBeNull();
    expect(w.pot.getPotData().usdtBudget).toEqual(100 * USDT_UNIT);
}

// --- Findings of the stocks audit (2026-09-11): behaviours pinned as tests until the relay is redeployed -----------

/// STOCKS-1 (documented gap): the Pot checks the RelayOrder (owner = Pot, minOut), the relay checks the order's owner,
/// but nobody on-chain reads the *inner* Omniston payload. An order whose swap names a foreign position owner and a
/// 1-unit minimum passes both contracts unchanged: only the keeper's own checks (adapters.ts) stand between a
/// compromised keeper key and a round delivered elsewhere. Bounded by maxRoundUsdt per round, visible as a pending
/// round that never settles. Fix = PotRelay v2 reading owner/min-out inside `swap` + SetPotParams (docs/09 P.12).
get fun `test relay: KNOWN GAP — a foreign owner inside the omniston payload is forwarded unchanged`() {
    val rw = setupRelay();
    val w = rw.w;
    mintDesk(w, w.issuer.address);
    arriveUsdt(w, 100 * USDT_UNIT);
    val attacker = testing.treasury("attacker");
    // an Omniston-shaped payload: op, position owner @ bit 289 = attacker, min-out 1 in ref0 @ bit 363
    var body = beginCell().storeUint(0xc0a5f0d9, 32).storeUint(0, 200).storeUint(0, 289 - 32 - 200).storeAddress(attacker.address);
    val minOutCell = beginCell().storeUint(0, 200).storeUint(0, 163).storeCoins(1).endCell();
    val evilSwap = body.storeRef(minOutCell).endCell();
    val min = floorStockFor(40 * USDT_UNIT);
    val order = RelayOrder { queryId: 7, owner: w.pot.address, minOut: min, swapForwardTon: SWAP_FORWARD, swap: evilSwap }.toCell();

    val res = relayRound(rw, 40 * USDT_UNIT, order);
    expect(res).toHaveSuccessfulTx<Round>({ from: w.keeper.address, to: w.pot.address });
    val transferTx = res.findTransaction<AskToTransfer>({ from: rw.relay.address, to: w.usdt.getWalletAddress(rw.relay.address) });
    expect(transferTx).toBeNotNull();
    var t = transferTx!.loadBody<AskToTransfer>();
    // the relay forwarded the evil payload as is: the escrow would open the position for the attacker
    expect(t.forwardPayload.loadBool()).toBeTrue();
    expect(t.forwardPayload.loadRef().hash()).toEqual(evilSwap.hash());
    expect(w.usdt.walletOf(rw.minter.address).getJettonBalance()).toEqual(40 * USDT_UNIT);
    expect(w.pot.getPotData().pending).toBeNotNull();
}

/// STOCKS-2 (documented, LOW): USDT reaching the Pot while a round is pending is read as the escrow refund and clears
/// the pending — a stranger can do it for 1 unit of USDT. No funds move wrongly (the stock still settles the counters
/// when it lands), but roundNo / rotation are not advanced by that round and a second round may start meanwhile.
get fun `test relay: KNOWN — a stranger's usdt during a pending round is read as the refund and clears the pending`() {
    val rw = setupRelay();
    val w = rw.w;
    mintDesk(w, w.issuer.address);
    arriveUsdt(w, 100 * USDT_UNIT);
    relayRound(rw, 40 * USDT_UNIT);
    expect(w.pot.getPotData().pending).toBeNotNull();

    val stray = arriveUsdt(w, 1);
    val ev = findEvent<RoundRefundedEvent>(stray, w.pot.address, EVENT_TOPIC_ROUND_REFUNDED);
    expect(ev).toBeNotNull();
    expect(ev!.refunded).toEqual(1);
    val data = w.pot.getPotData();
    expect(data.pending).toBeNull();
    expect(data.usdtBudget).toEqual(60 * USDT_UNIT + 1);

    // the real delivery still credits the desks, but as a round without a pending: roundNo and rotation do not move
    val delivered = 5 * STOCK_UNIT;
    w.stock0.sendMint(w.issuer.address, rw.relay.address, delivered, 0, ton("0.1"));
    val flush = rw.relay.sendFlush(w.keeper.address, 9, w.stock0.getWalletAddress(rw.relay.address), delivered, { value: ton("0.15"), bounce: true });
    val settled = findEvent<RoundSettledEvent>(flush, w.pot.address, EVENT_TOPIC_ROUND_SETTLED);
    expect(settled).toBeNotNull();
    expect(settled!.spendUsdt).toEqual(0);
    expect(settled!.received).toEqual(delivered);
    expect(w.pot.getPotData().roundNo).toEqual(0);
    expect(w.pot.getPotData().rotationNext).toEqual(0);
}

/// Resolver silent past the timeout: the keeper cancels, the budget is written off, and when the stock finally lands
/// in the relay a late Flush still credits every live desk (RoundSettled without a pending: spendUsdt 0), with 3 desks.
get fun `test relay: pending expired then late delivery — flush credits the 3 desks anyway`() {
    val rw = setupRelay();
    val w = rw.w;
    val d1 = mintDesk(w, testing.treasury("r1").address);
    mintDesk(w, testing.treasury("r2").address);
    mintDesk(w, testing.treasury("r3").address);
    arriveUsdt(w, 100 * USDT_UNIT);
    relayRound(rw, 40 * USDT_UNIT);
    testing.setNow(WORLD_T0 + 600);
    expect(w.pot.sendCancelPending(w.keeper.address, 3, { value: ton("0.05"), bounce: true })).toHaveSuccessfulTx<CancelPending>({ to: w.pot.address });
    expect(w.pot.getPotData().pending).toBeNull();
    expect(w.pot.getPotData().usdtBudget).toEqual(60 * USDT_UNIT); // the 40 USDT are with the escrow: written off until refunded

    val delivered = 9 * STOCK_UNIT;
    w.stock0.sendMint(w.issuer.address, rw.relay.address, delivered, 0, ton("0.1"));
    val flush = rw.relay.sendFlush(testing.treasury("anyone").address, 9, w.stock0.getWalletAddress(rw.relay.address), delivered, { value: ton("0.15"), bounce: true });
    val settled = findEvent<RoundSettledEvent>(flush, w.pot.address, EVENT_TOPIC_ROUND_SETTLED);
    expect(settled).toBeNotNull();
    expect(settled!.liveDesks).toEqual(3);
    expect(settled!.spendUsdt).toEqual(0);
    // each desk can sweep exactly a third
    expect(w.pot.getOwed(0, 0)).toEqual(delivered / 3);
    val sweep = d1.sendSweep(testing.treasury("r1").address, 5, 1, { value: SWEEP_REQUEST_VALUE + ton("0.05"), bounce: true });
    expect(sweep).toHaveSuccessfulTx<SweepRequest>({ from: d1.address, to: w.pot.address });
    expect(deskStockWallet(w, 0, d1).getJettonBalance()).toEqual(delivered / 3);
}
