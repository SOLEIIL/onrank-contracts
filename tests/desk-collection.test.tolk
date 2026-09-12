import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/errors"
import "@contracts/common/tep-nft"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/Pot.gen"
import "@tests/fixtures"

get fun `test collection: mint deploys desk, registers it in the pot and initializes stamps`() {
    val w = setupWorld();
    val owner = testing.treasury("owner");

    val desk = mintDesk(w, owner.address);

    val nft = desk.getNftData();
    expect(nft.isInitialized).toBeTrue();
    expect(nft.itemIndex).toEqual(0);
    expect(nft.ownerAddress!).toEqual(owner.address);
    expect(nft.collectionAddress).toEqual(w.collection.address);

    val data = desk.getDeskData();
    expect(data.pot).toEqual(w.pot.address);
    expect(data.stampsReady).toBeTrue();
    expect(stampOf(desk, 0)).toEqual(0);
    expect(stampOf(desk, 1)).toEqual(0);

    expect(w.collection.getCollectionData().nextItemIndex).toEqual(1);
    expect(w.pot.getPotData().liveDesks).toEqual(1);
}

get fun `test collection: only the minter can deploy`() {
    val w = setupWorld();
    val stranger = testing.treasury("stranger");
    val res = w.collection.sendDeployDesk(stranger.address, 0, 0, stranger.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveFailedTx<DeployDesk>({ to: w.collection.address, exitCode: Errors.NotFromMinter });
    expect(w.collection.getCollectionData().nextItemIndex).toEqual(0);
    expect(w.pot.getPotData().liveDesks).toEqual(0);
}

get fun `test collection: serial must not skip ahead`() {
    val w = setupWorld();
    val res = w.collection.sendDeployDesk(w.minterOp.address, 0, 1, w.minterOp.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveFailedTx<DeployDesk>({ to: w.collection.address, exitCode: Errors.InvalidSerial });
}

get fun `test collection: redeploying an existing serial does not register twice`() {
    val w = setupWorld();
    val owner = testing.treasury("owner");
    val desk = mintDesk(w, owner.address);

    // retry for serial 0 (e.g. after a bounced item deploy): no second RegisterDesk, no liveDesks change
    val res = w.collection.sendDeployDesk(w.minterOp.address, 7, 0, owner.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<DeployDesk>({ to: w.collection.address });
    expect(res).toNotHaveTx<RegisterDesk>({ to: w.pot.address });
    expect(res).toHaveSuccessfulTx<DeployDeskOk>({ from: w.collection.address, to: w.minterOp.address });
    expect(w.pot.getPotData().liveDesks).toEqual(1);
    expect(w.collection.getCollectionData().nextItemIndex).toEqual(1);
    // the already-initialized desk rejects the init body (not a known message) and keeps its owner
    expect(desk.getNftData().ownerAddress!).toEqual(owner.address);
}

get fun `test collection: DeskDeployed event carries serial, owner, item address and isNew`() {
    val w = setupWorld();
    val owner = testing.treasury("owner");
    val res = w.collection.sendDeployDesk(w.minterOp.address, 3, 0, owner.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveSuccessfulTx<DeployDesk>({ to: w.collection.address });
    val ev = findEvent<DeskDeployedEvent>(res, w.collection.address, EVENT_TOPIC_DESK_DEPLOYED);
    expect(ev != null).toBeTrue();
    expect(ev!.serial).toEqual(0);
    expect(ev!.owner).toEqual(owner.address);
    expect(ev!.item).toEqual(w.collection.getNftAddressByIndex(0));
    expect(ev!.isNew).toBeTrue();

    // retry of the same serial: event again, but isNew = false
    val retry = w.collection.sendDeployDesk(w.minterOp.address, 4, 0, owner.address, { value: ton("0.2"), bounce: true });
    val ev2 = findEvent<DeskDeployedEvent>(retry, w.collection.address, EVENT_TOPIC_DESK_DEPLOYED);
    expect(ev2!.isNew).toBeFalse();
    expect(countEvents(retry, w.collection.address, EVENT_TOPIC_DESK_DEPLOYED)).toEqual(1);
}

get fun `test collection: cap is enforced`() {
    val w = setupWorld(2);
    mintDesk(w, testing.treasury("a").address);
    mintDesk(w, testing.treasury("b").address);
    val res = w.collection.sendDeployDesk(w.minterOp.address, 0, 2, w.minterOp.address, { value: ton("0.2"), bounce: true });
    expect(res).toHaveFailedTx<DeployDesk>({ to: w.collection.address, exitCode: Errors.CapReached });
    expect(w.pot.getPotData().liveDesks).toEqual(2);
}

get fun `test collection: deploy needs enough value`() {
    val w = setupWorld();
    val res = w.collection.sendDeployDesk(w.minterOp.address, 0, 0, w.minterOp.address, { value: ton("0.05"), bounce: true });
    expect(res).toHaveFailedTx<DeployDesk>({ to: w.collection.address, exitCode: Errors.InsufficientValue });
}

get fun `test collection: royalty params point to the pot`() {
    val w = setupWorld();
    val rp = w.collection.royaltyParams();
    expect(rp.royaltyAddress).toEqual(w.pot.address);
    expect(rp.numerator).toEqual(500);
    expect(rp.denominator).toEqual(10000);

    val asker = testing.treasury("asker");
    val res = w.collection.sendRequestRoyaltyParams(asker.address, 42, { value: ton("0.05") });
    expect(res).toHaveTx<ResponseRoyaltyParams>({
        from: w.collection.address,
        to: asker.address,
        body: ResponseRoyaltyParams { queryId: 42, royaltyParams: rp }.toCell(),
    });
}

get fun `test collection: nft content is common prefix + serial`() {
    val w = setupWorld();
    val content = w.collection.getNftContent(17, "").load();
    expect(content.string).toEqual("https://meta.test/desk/17.json");
}

get fun `test collection: admin can rotate minter and admin`() {
    val w = setupWorld();
    val newMinter = testing.treasury("new-minter");
    val stranger = testing.treasury("stranger");

    expect(w.collection.sendSetCollectionMinter(stranger.address, 0, newMinter.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetCollectionMinter>({ to: w.collection.address, exitCode: Errors.NotFromAdmin });

    expect(w.collection.sendSetCollectionMinter(w.admin.address, 0, newMinter.address, { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetCollectionMinter>({ to: w.collection.address });
    val (minter, pot, _, _) = w.collection.getDeskConfig();
    expect(minter).toEqual(newMinter.address);
    expect(pot).toEqual(w.pot.address);

    // old minter is now rejected, new one accepted
    expect(w.collection.sendDeployDesk(w.minterOp.address, 0, 0, w.minterOp.address, { value: ton("0.2"), bounce: true }))
        .toHaveFailedTx<DeployDesk>({ to: w.collection.address, exitCode: Errors.NotFromMinter });
    expect(w.collection.sendDeployDesk(newMinter.address, 0, 0, newMinter.address, { value: ton("0.2"), bounce: true }))
        .toHaveSuccessfulTx<DeployDesk>({ to: w.collection.address });

    expect(w.collection.sendChangeCollectionAdmin(w.admin.address, 0, stranger.address, { value: ton("0.05") }))
        .toHaveSuccessfulTx<ChangeCollectionAdmin>({ to: w.collection.address });
    expect(w.collection.getCollectionData().adminAddress).toEqual(stranger.address);
}

get fun `test collection: unknown opcode bounces, plain ton is accepted`() {
    val w = setupWorld();
    val stranger = testing.treasury("stranger");
    val bad = w.collection.sendAny(stranger.address, beginCell().storeUint(0x12345678, 32).storeUint(0, 64).endCell(), { value: ton("0.05"), bounce: true });
    expect(bad).toHaveTx({ to: w.collection.address, success: false, exitCode: 0xFFFF });
    val plain = w.collection.sendAny(stranger.address, createEmptyCell(), { value: ton("0.05"), bounce: true });
    expect(plain).toHaveTx({ to: w.collection.address, success: true });
}
