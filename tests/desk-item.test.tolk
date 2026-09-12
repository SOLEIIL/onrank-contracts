import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/common/tep-nft"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/utils"
import "@tests/fixtures"

fun emptyPayload(): PayloadInline {
    return { value: beginCell().storeUint(0, 1).toSlice() };
}

get fun `test desk: tep-62 transfer notifies the new owner and returns excesses`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val desk = mintDesk(w, a.address);
    val bBefore = testing.getAccountBalance(b.address);

    val res = desk.sendAskToChangeOwnership(a.address, 11, b.address, a.address, null, ton("0.05"), emptyPayload(), { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<AskToChangeOwnership>({ from: a.address, to: desk.address });
    expect(res).toHaveTx<NotificationForNewOwner>({ from: desk.address, to: b.address, value: ton("0.05") });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: desk.address, to: a.address });
    expect(testing.getAccountBalance(b.address) - bBefore > ton("0.04")).toBeTrue();

    val nft = desk.getNftData();
    expect(nft.isInitialized).toBeTrue();
    expect(nft.ownerAddress!).toEqual(b.address);
    expect(nft.itemIndex).toEqual(0);
    expect(nft.collectionAddress).toEqual(w.collection.address);
    expect(desk.getDeskData().owner).toEqual(b.address);
    // stamps survive the transfer: the new owner inherits exactly the old position
    expect(desk.getDeskData().stampsReady).toBeTrue();

    // the desk keeps its storage reserve
    expect(testing.getAccountBalance(desk.address) >= MIN_STORAGE_RESERVE).toBeTrue();
}

get fun `test desk: transfer guards — owner only, payload shape, workchain, value`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val desk = mintDesk(w, a.address);

    expect(desk.sendAskToChangeOwnership(b.address, 0, b.address, b.address, null, 0, emptyPayload(), { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<AskToChangeOwnership>({ to: desk.address, exitCode: Errors.NotFromOwner });
    // raw bodies: empty forward payload (no Either bit) and Either-right bit without a ref are malformed
    var head = beginCell().storeUint(0x5fcc3d14, 32).storeUint(0, 64).storeAddress(b.address).storeAddress(a.address).storeMaybeRef(null).storeCoins(0);
    expect(desk.sendAny(a.address, head.endCell(), { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<AskToChangeOwnership>({ to: desk.address, exitCode: Errors.IncorrectForwardPayload });
    expect(desk.sendAny(a.address, head.storeUint(1, 1).endCell(), { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<AskToChangeOwnership>({ to: desk.address, exitCode: Errors.IncorrectForwardPayload });
    // forward amount larger than what was attached
    expect(desk.sendAskToChangeOwnership(a.address, 0, b.address, a.address, null, ton("0.5"), emptyPayload(), { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<AskToChangeOwnership>({ to: desk.address, exitCode: Errors.InsufficientValue });
    val masterchain = address("-1:0000000000000000000000000000000000000000000000000000000000000001");
    expect(desk.sendAskToChangeOwnership(a.address, 0, masterchain, a.address, null, 0, emptyPayload(), { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<AskToChangeOwnership>({ to: desk.address, exitCode: Errors.InvalidWorkchain });

    expect(desk.getDeskData().owner).toEqual(a.address);

    // transfer without notification nor response address still works
    expect(desk.sendAskToChangeOwnership(a.address, 0, b.address, null, null, 0, emptyPayload(), { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<AskToChangeOwnership>({ to: desk.address });
    expect(desk.getDeskData().owner).toEqual(b.address);
}

get fun `test desk: static data reply follows tep-62`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val desk = mintDesk(w, a.address);
    val stranger = testing.treasury("stranger");
    val res = desk.sendRequestStaticData(stranger.address, 42, { value: ton("0.05"), bounce: true });
    expect(res).toHaveSuccessfulTx<RequestStaticData>({ from: stranger.address, to: desk.address });
    expect(res).toHaveTx<ResponseStaticData>({ from: desk.address, to: stranger.address });
}

get fun `test desk: a second init from the collection cannot overwrite the owner`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val desk = mintDesk(w, a.address);

    // the collection re-sends DeskItemInit (retry path) with a different owner
    val res = net.send(w.collection.address, createMessage({
        bounce: true,
        value: ton("0.05"),
        dest: desk.address,
        body: DeskItemInit { owner: b.address, pot: w.pot.address },
    }));
    expect(res).toHaveFailedTx({ from: w.collection.address, to: desk.address, exitCode: 0xFFFF });
    expect(desk.getDeskData().owner).toEqual(a.address);

    // and through the collection itself: redeploy of an existing serial bounces at the desk
    val redeploy = w.collection.sendDeployDesk(w.minterOp.address, 0, 0, b.address, { value: ton("0.2"), bounce: true });
    expect(redeploy).toHaveSuccessfulTx<DeployDesk>({ to: w.collection.address });
    expect(redeploy).toHaveFailedTx({ from: w.collection.address, to: desk.address, exitCode: 0xFFFF });
    expect(desk.getDeskData().owner).toEqual(a.address);
    expect(w.pot.getPotData().liveDesks).toEqual(1);
}

get fun `test desk: init is refused from anyone but the collection`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val serial = w.collection.getCollectionData().nextItemIndex;
    val desk = DeskItem.fromStorage({ serial: serial as uint32, collection: w.collection.address });
    val res = net.send(a.address, createMessage({
        bounce: true,
        value: ton("0.1"),
        dest: { stateInit: desk.stateInit! },
        body: DeskItemInit { owner: a.address, pot: w.pot.address },
    }));
    expect(res).toHaveFailedTx({ from: a.address, to: desk.address, exitCode: Errors.NotFromCollection });
    // the account may exist (state init landed) but stays uninitialized: no owner, no stamps
    expect(desk.getNftData().isInitialized).toBeFalse();
    expect(w.pot.getPotData().liveDesks).toEqual(0);

    // the legit mint for that serial still goes through afterwards
    val b = testing.treasury("b");
    val legit = w.collection.sendDeployDesk(w.minterOp.address, 0, serial as uint32, b.address, { value: ton("0.2"), bounce: true });
    expect(legit).toHaveSuccessfulTx<RegisterDesk>({ from: w.collection.address, to: w.pot.address });
    expect(legit).toHaveSuccessfulTx<StampsInit>({ from: w.pot.address, to: desk.address });
    expect(desk.getNftData().isInitialized).toBeTrue();
    expect(desk.getDeskData().owner).toEqual(b.address);
    expect(desk.getDeskData().stampsReady).toBeTrue();
    expect(w.pot.getPotData().liveDesks).toEqual(1);
}

get fun `test desk: withdrawing a different slot leaves owed stock claimable`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val out = testing.treasury("out");
    val desk = mintDesk(w, a.address);
    arriveStock(w, 0, 10 * STOCK_UNIT);
    arriveStock(w, 1, 4 * STOCK_UNIT);
    sweep(w, desk, a.address, 0b11);
    expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(10 * STOCK_UNIT);
    expect(deskStockWallet(w, 1, desk).getJettonBalance()).toEqual(4 * STOCK_UNIT);

    // new stock for slot 0 is owed; owner withdraws slot-1 stock (nothing owed there)
    arriveStock(w, 0, 6 * STOCK_UNIT);
    val res = desk.sendWithdraw(a.address, 0, 1, deskStockWallet(w, 1, desk).address, 4 * STOCK_UNIT, out.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<WithdrawViaPot>({ from: desk.address, to: w.pot.address });
    expect(res).toHaveSuccessfulTx<WithdrawOk>({ from: w.pot.address, to: desk.address });
    expect(stockOf(w, 1).walletOf(out.address).getJettonBalance()).toEqual(4 * STOCK_UNIT);

    // slot 0 still owed; withdraw on slot 0 refused; sweep collects the 6 units
    expect(desk.sendWithdraw(a.address, 0, 0, deskStockWallet(w, 0, desk).address, 1, out.address, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<WithdrawViaPot>({ from: desk.address, to: w.pot.address, exitCode: Errors.RoundOwed });
    expect(desk.getDeskData().pending.isEmpty()).toBeTrue();
    sweep(w, desk, a.address, 0b01);
    expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(16 * STOCK_UNIT);
}

get fun `test desk: withdraw to a wrong jetton wallet bounces and unlocks the slot`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val out = testing.treasury("out");
    val desk = mintDesk(w, a.address);
    arriveStock(w, 0, 10 * STOCK_UNIT);
    sweep(w, desk, a.address, 0b01);

    // the owner names the pot's wallet instead of the desk's: the jetton wallet refuses (not owner)
    val res = desk.sendWithdraw(a.address, 0, 0, potStockWallet(w, 0).address, 1 * STOCK_UNIT, out.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<WithdrawOk>({ from: w.pot.address, to: desk.address });
    expect(res).toHaveFailedTx<AskToTransfer>({ from: desk.address, to: potStockWallet(w, 0).address, exitCode: 73 });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: desk.address, to: a.address });
    expect(desk.getDeskData().pending.isEmpty()).toBeTrue();
    expect(potStockWallet(w, 0).getJettonBalance()).toEqual(0);
    expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(10 * STOCK_UNIT);
}

get fun `test desk: unknown opcodes bounce, plain ton and stray notifications are kept`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val desk = mintDesk(w, a.address);
    val before = testing.getAccountBalance(desk.address);

    expect(net.send(a.address, createMessage({ bounce: true, value: ton("0.1"), dest: desk.address, body: beginCell().storeUint(0x12345678, 32).endCell() })))
        .toHaveFailedTx({ to: desk.address, exitCode: 0xFFFF });
    expect(net.send(a.address, createMessage({ bounce: false, value: ton("0.1"), dest: desk.address, body: createEmptyCell() })))
        .toHaveSuccessfulTx({ to: desk.address });
    expect(testing.getAccountBalance(desk.address) - before > ton("0.09")).toBeTrue();

    // stock donated straight to the desk vault: accepted, withdrawable by the owner later
    expect(stockOf(w, 0).sendMint(w.issuer.address, desk.address, 3 * STOCK_UNIT, ton("0.05"), ton("0.3")))
        .toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: desk.address });
    expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(3 * STOCK_UNIT);
}
