// Async ordering fuzz on the desk side: a sweep, a stock arrival and an NFT transfer of the same
// desk run step by step in a random interleaving. Whatever the order: no double credit, no stuck
// pending, owed + held == share, and the pot never owes more than it holds.
import "@acton/build"
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
import "@contracts/pot/pot-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/utils"
import "@tests/fixtures"

fun sweepMsg(desk: DeskItem): OutMessage {
    return createMessage({ bounce: true, value: ton("0.3"), dest: desk.address, body: Sweep { queryId: 1, slotsMask: 0b01 } });
}

fun stockMsg(w: World, amount: int): OutMessage {
    return createMessage({
        bounce: false,
        value: ton("0.315"),
        dest: w.stock0.address,
        body: MintNewJettons {
            queryId: 2,
            mintRecipient: w.pot.address,
            tonAmount: ton("0.3"),
            internalTransferMsg: InternalTransferStep {
                queryId: 2,
                jettonAmount: amount,
                transferInitiator: null,
                sendExcessesTo: w.stock0.address,
                forwardTonAmount: ton("0.05"),
                forwardPayload: beginCell().storeMaybeRef(null).endCell().beginParse(),
            }.toCell(),
        },
    });
}

fun nftTransferMsg(desk: DeskItem, from: address, to: address): OutMessage {
    return createMessage({
        bounce: true,
        value: ton("0.1"),
        dest: desk.address,
        body: AskToChangeOwnership {
            queryId: 3,
            newOwnerAddress: to,
            sendExcessesTo: from,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: beginCell().storeUint(0, 1).toSlice(),
        },
    });
}

fun stepAny(c1: TxCursor, c2: TxCursor, c3: TxCursor, n: int) {
    if (!c1.isDone()) { c1.executeN(n); } else if (!c2.isDone()) { c2.executeN(n); } else { c3.executeN(n); }
}

@test.fuzz(30)
get fun `test pot: fuzz — sweep, stock arrival and desk transfer interleaved in any order`(seed: int, s1: int, s2: int) {
    val w = setupWorld();
    val a = testing.treasury("pi-a");
    val b = testing.treasury("pi-b");
    val c = testing.treasury("pi-c");
    val deskA = mintDesk(w, a.address);
    val deskB = mintDesk(w, b.address);
    val first = fuzz.bound(s1, 2, 1000) * STOCK_UNIT;
    val second = fuzz.bound(s2, 2, 1000) * STOCK_UNIT;
    arriveStock(w, 0, first);

    val c1 = testing.createTraceIterationCursor(a.address, sweepMsg(deskA));
    val c2 = testing.createTraceIterationCursor(w.issuer.address, stockMsg(w, second));
    val c3 = testing.createTraceIterationCursor(a.address, nftTransferMsg(deskA, a.address, c.address));

    var bits = seed;
    var guard = 0;
    while (!(c1.isDone() && c2.isDone() && c3.isDone()) && guard < 200) {
        val pick = bits & 3;
        val n = 1 + ((bits >> 2) & 1);
        bits = bits >> 3;
        if (bits == 0) {
            bits = seed ^ guard;
        }
        if (pick == 0 && !c1.isDone()) {
            c1.executeN(n);
        } else if (pick == 1 && !c2.isDone()) {
            c2.executeN(n);
        } else if (pick == 2 && !c3.isDone()) {
            c3.executeN(n);
        } else {
            stepAny(c1, c2, c3, n);
        }
        guard += 1;
    }
    expect(c1.isDone() && c2.isDone() && c3.isDone()).toBeTrue();

    // no stuck pending on the desk, ownership moved exactly once
    val da = deskA.getDeskData();
    expect(da.pending.isEmpty()).toBeTrue();
    expect(da.owner).toEqual(c.address);

    // each desk's share of everything that arrived is held + still owed; total owed <= pot balance
    val total = first + second;
    val heldA = deskStockWallet(w, 0, deskA).getJettonBalance();
    val owedA = w.pot.getOwed(0, stampOf(deskA, 0));
    val owedB = w.pot.getOwed(0, stampOf(deskB, 0));
    expect((heldA + owedA) as int).toBeApproxEqAbs(total / 2, 2);
    expect(owedB as int).toBeApproxEqAbs(total / 2, 2);
    expect(owedA + owedB <= potStockWallet(w, 0).getJettonBalance()).toBeTrue();

    // the new owner sweeps the rest; the old owner cannot; nothing is credited twice
    expect(sweep(w, deskA, a.address, 0b01)).toHaveFailedTx<Sweep>({ to: deskA.address, exitCode: Errors.NotFromOwner });
    expect(sweep(w, deskA, c.address, 0b01)).toHaveSuccessfulTx<Sweep>({ to: deskA.address });
    expect(sweep(w, deskB, b.address, 0b01)).toHaveSuccessfulTx<Sweep>({ to: deskB.address });
    expect(deskStockWallet(w, 0, deskA).getJettonBalance() as int).toBeApproxEqAbs(total / 2, 2);
    expect(deskStockWallet(w, 0, deskB).getJettonBalance() as int).toBeApproxEqAbs(total / 2, 2);
    expect(w.pot.getOwed(0, stampOf(deskA, 0))).toEqual(0);
    expect(w.pot.getOwed(0, stampOf(deskB, 0))).toEqual(0);
    expect(deskA.getDeskData().pending.isEmpty()).toBeTrue();
}
