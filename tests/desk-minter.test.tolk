import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/pot/pot-messages"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/DeskMinter.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/utils"
import "@tests/fixtures"

const DESK_UNIT = 1000000000
const DEPOSIT = 1000 * DESK_UNIT
const SURCHARGE = ton("1")
const PROTOCOL_BPS = 4000
const MINT_FORWARD = SURCHARGE + MINT_GAS + ton("0.02")

struct MinterWorld {
    w: World
    deskToken: JettonMinter
    minter: DeskMinter
    protocol: Treasury
}

fun minterConfig(mw: MinterWorld, wallet: address?): DeskMinterConfig {
    return { deskJettonWallet: wallet, protocolWallet: mw.protocol.address, depositAmount: DEPOSIT, surcharge: SURCHARGE, protocolShareBps: PROTOCOL_BPS };
}

fun setupMinter(cap: uint32 = 5000): MinterWorld {
    val w = setupWorld(cap);
    val protocol = testing.treasury("protocol");
    val deskToken = deployJetton(w.issuer, "DESK");
    var mw: MinterWorld = { w, deskToken, minter: DeskMinter.fromAddress(w.admin.address), protocol };

    val minter = DeskMinter.fromStorage({
        admin: w.admin.address,
        collection: w.collection.address,
        pot: w.pot.address,
        minted: 0,
        cap,
        paused: false,
        unburned: 0,
        config: minterConfig(mw, null).toCell(),
        pendingDeploys: createEmptyMap(),
    });
    expect(minter.deploy(w.admin.address, { value: ton("1"), bounce: false })).toHaveSuccessfulDeploy({ to: minter.address });
    mw.minter = minter;

    expect(minter.sendSetDeskMinterConfig(w.admin.address, 0, minterConfig(mw, deskToken.getWalletAddress(minter.address)), { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetDeskMinterConfig>({ to: minter.address });
    expect(w.collection.sendSetCollectionMinter(w.admin.address, 0, minter.address, { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetCollectionMinter>({ to: w.collection.address });
    return mw;
}

fun giveDesk(mw: MinterWorld, to: address, amount: int) {
    expect(mw.deskToken.sendMint(mw.w.issuer.address, to, amount, ton("0.05"), ton("0.3")))
        .toHaveSuccessfulTx<TransferNotificationForRecipient>({ to });
}

/// User pays `amount` $DESK to the minter with `forwardTon` attached to the notification.
fun payMint(mw: MinterWorld, user: address, amount: int, forwardTon: coins = MINT_FORWARD, value: coins = ton("1.6")): SendResultList {
    return mw.deskToken.walletOf(user).sendTransfer(user, value, amount, mw.minter.address, user, null, forwardTon, null);
}

fun deskBalance(mw: MinterWorld, owner: address): int {
    return mw.deskToken.walletOf(owner).getJettonBalance();
}

get fun `test minter: valid deposit burns $DESK, deploys the desk and splits the surcharge`() {
    val mw = setupMinter();
    val w = mw.w;
    val user = testing.treasury("user");
    giveDesk(mw, user.address, DEPOSIT);
    val supplyBefore = mw.deskToken.getTotalSupply();
    val potBefore = testing.getAccountBalance(w.pot.address);
    val protocolBefore = testing.getAccountBalance(mw.protocol.address);

    val res = payMint(mw, user.address, DEPOSIT);
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: mw.minter.address });
    expect(res).toHaveSuccessfulTx<AskToBurn>({ from: mw.minter.address, to: mw.deskToken.getWalletAddress(mw.minter.address) });
    expect(res).toHaveSuccessfulTx<DeployDesk>({ from: mw.minter.address, to: w.collection.address });
    expect(res).toHaveSuccessfulTx<RegisterDesk>({ from: w.collection.address, to: w.pot.address });
    expect(res).toHaveSuccessfulTx<DeployDeskOk>({ from: w.collection.address, to: mw.minter.address });
    expect(res).toHaveSuccessfulTx<PotTopUp>({ from: mw.minter.address, to: w.pot.address, value: SURCHARGE * (10000 - PROTOCOL_BPS) / 10000 });
    expect(res).toHaveTx({ from: mw.minter.address, to: mw.protocol.address, value: SURCHARGE * PROTOCOL_BPS / 10000 });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: mw.minter.address, to: user.address });

    expect(mw.deskToken.getTotalSupply()).toEqual(supplyBefore - DEPOSIT);
    expect(deskBalance(mw, user.address)).toEqual(0);
    expect(deskBalance(mw, mw.minter.address)).toEqual(0);

    val desk = DeskItem.fromAddress(w.collection.getNftAddressByIndex(0));
    val data = desk.getDeskData();
    expect(data.owner).toEqual(user.address);
    expect(data.stampsReady).toBeTrue();
    expect(w.pot.getPotData().liveDesks).toEqual(1);
    expect(w.collection.getCollectionData().nextItemIndex).toEqual(1);
    expect(testing.getAccountBalance(w.pot.address) - potBefore >= SURCHARGE * 6 / 10 - ton("0.001")).toBeTrue();
    expect(testing.getAccountBalance(mw.protocol.address) - protocolBefore >= SURCHARGE * 4 / 10 - ton("0.001")).toBeTrue();

    val md = mw.minter.getMinterData();
    expect(md.minted).toEqual(1);
    expect(md.pendingDeploys.isEmpty()).toBeTrue();
}

get fun `test minter: two users mint sequential serials`() {
    val mw = setupMinter();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    giveDesk(mw, a.address, DEPOSIT);
    giveDesk(mw, b.address, DEPOSIT);
    payMint(mw, a.address, DEPOSIT);
    payMint(mw, b.address, DEPOSIT);
    expect(DeskItem.fromAddress(mw.w.collection.getNftAddressByIndex(0)).getDeskData().owner).toEqual(a.address);
    expect(DeskItem.fromAddress(mw.w.collection.getNftAddressByIndex(1)).getDeskData().owner).toEqual(b.address);
    expect(mw.w.pot.getPotData().liveDesks).toEqual(2);
    expect(mw.minter.getMinterData().minted).toEqual(2);
}

get fun `test minter: wrong amount, short forward ton, paused or cap reached return the deposit`() {
    val mw = setupMinter(1);
    val user = testing.treasury("user");
    giveDesk(mw, user.address, 5 * DEPOSIT);

    // wrong amount
    var res = payMint(mw, user.address, DEPOSIT - 1);
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: mw.minter.address });
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: mw.minter.address, to: mw.deskToken.getWalletAddress(mw.minter.address) });
    expect(deskBalance(mw, user.address)).toEqual(5 * DEPOSIT);
    expect(mw.minter.getMinterData().minted).toEqual(0);

    // not enough TON forwarded for surcharge + gas
    res = payMint(mw, user.address, DEPOSIT, SURCHARGE + ton("0.1"));
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: mw.minter.address, to: mw.deskToken.getWalletAddress(mw.minter.address) });
    expect(deskBalance(mw, user.address)).toEqual(5 * DEPOSIT);
    expect(mw.minter.getMinterData().minted).toEqual(0);

    // paused
    expect(mw.minter.sendSetDeskMinterPaused(mw.w.admin.address, 0, true, { value: ton("0.05") })).toHaveSuccessfulTx<SetDeskMinterPaused>({ to: mw.minter.address });
    res = payMint(mw, user.address, DEPOSIT);
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: mw.minter.address, to: mw.deskToken.getWalletAddress(mw.minter.address) });
    expect(deskBalance(mw, user.address)).toEqual(5 * DEPOSIT);
    expect(mw.minter.sendSetDeskMinterPaused(mw.w.admin.address, 0, false, { value: ton("0.05") })).toHaveSuccessfulTx<SetDeskMinterPaused>({ to: mw.minter.address });

    // first real mint fills the cap of 1
    res = payMint(mw, user.address, DEPOSIT);
    expect(res).toHaveSuccessfulTx<DeployDesk>({ to: mw.w.collection.address });
    expect(deskBalance(mw, user.address)).toEqual(4 * DEPOSIT);
    expect(mw.minter.getMinterData().minted).toEqual(1);

    // cap reached: deposit comes back, nothing deployed
    res = payMint(mw, user.address, DEPOSIT);
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: mw.minter.address, to: mw.deskToken.getWalletAddress(mw.minter.address) });
    expect(deskBalance(mw, user.address)).toEqual(4 * DEPOSIT);
    expect(mw.minter.getMinterData().minted).toEqual(1);
    expect(mw.w.pot.getPotData().liveDesks).toEqual(1);
    expect(mw.deskToken.getTotalSupply()).toEqual(4 * DEPOSIT);
}

get fun `test minter: notification from a foreign jetton wallet is rejected`() {
    val mw = setupMinter();
    val user = testing.treasury("user");
    // pay with AAPLx instead of $DESK
    expect(mw.w.stock0.sendMint(mw.w.issuer.address, user.address, DEPOSIT, ton("0.05"), ton("0.3")))
        .toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: user.address });
    val res = mw.w.stock0.walletOf(user.address).sendTransfer(user.address, ton("1.6"), DEPOSIT, mw.minter.address, user.address, null, MINT_FORWARD, null);
    expect(res).toHaveFailedTx<TransferNotificationForRecipient>({ to: mw.minter.address, exitCode: Errors.NotFromDeskWallet });
    expect(mw.minter.getMinterData().minted).toEqual(0);

    // a direct fake notification from a wallet is rejected too
    expect(mw.minter.sendTransferNotificationForRecipient(user.address, 0, DEPOSIT, user.address, PayloadInline { value: emptyForwardPayload() }, { value: MINT_FORWARD, bounce: true }))
        .toHaveFailedTx<TransferNotificationForRecipient>({ to: mw.minter.address, exitCode: Errors.NotFromDeskWallet });
}

get fun `test minter: bounced deploy stays pending and anyone can retry it`() {
    val mw = setupMinter();
    val w = mw.w;
    val user = testing.treasury("user");
    val stranger = testing.treasury("stranger");
    giveDesk(mw, user.address, DEPOSIT);

    // collection temporarily points at another minter: DeployDesk bounces
    expect(w.collection.sendSetCollectionMinter(w.admin.address, 0, w.minterOp.address, { value: ton("0.05") })).toHaveSuccessfulTx<SetCollectionMinter>({ to: w.collection.address });
    val res = payMint(mw, user.address, DEPOSIT);
    expect(res).toHaveFailedTx<DeployDesk>({ from: mw.minter.address, to: w.collection.address, exitCode: Errors.NotFromMinter });
    // deposit is burned, pot got its share, but no desk exists yet
    expect(deskBalance(mw, user.address)).toEqual(0);
    expect(w.pot.getPotData().liveDesks).toEqual(0);
    var md = mw.minter.getMinterData();
    expect(md.minted).toEqual(1);
    expect(md.pendingDeploys.get(0).isFound).toBeTrue();

    expect(mw.minter.sendRetryDeploy(stranger.address, 0, 7, { value: ton("0.3"), bounce: true }))
        .toHaveFailedTx<RetryDeploy>({ to: mw.minter.address, exitCode: Errors.NoPendingDeploy });
    expect(mw.minter.sendRetryDeploy(stranger.address, 0, 0, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<RetryDeploy>({ to: mw.minter.address, exitCode: Errors.InsufficientValue });

    expect(w.collection.sendSetCollectionMinter(w.admin.address, 0, mw.minter.address, { value: ton("0.05") })).toHaveSuccessfulTx<SetCollectionMinter>({ to: w.collection.address });
    val retry = mw.minter.sendRetryDeploy(stranger.address, 0, 0, { value: ton("0.3"), bounce: true });
    expect(retry).toHaveSuccessfulTx<DeployDesk>({ from: mw.minter.address, to: w.collection.address });
    expect(retry).toHaveSuccessfulTx<DeployDeskOk>({ from: w.collection.address, to: mw.minter.address });
    val desk = DeskItem.fromAddress(w.collection.getNftAddressByIndex(0));
    expect(desk.getDeskData().owner).toEqual(user.address);
    expect(desk.getDeskData().stampsReady).toBeTrue();
    expect(w.pot.getPotData().liveDesks).toEqual(1);
    md = mw.minter.getMinterData();
    expect(md.pendingDeploys.isEmpty()).toBeTrue();

    // retrying a settled serial is refused
    expect(mw.minter.sendRetryDeploy(stranger.address, 0, 0, { value: ton("0.3"), bounce: true }))
        .toHaveFailedTx<RetryDeploy>({ to: mw.minter.address, exitCode: Errors.NoPendingDeploy });
}

get fun `test minter: admin operations are admin-only`() {
    val mw = setupMinter();
    val w = mw.w;
    val stranger = testing.treasury("stranger");
    expect(mw.minter.sendSetDeskMinterPaused(stranger.address, 0, true, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetDeskMinterPaused>({ to: mw.minter.address, exitCode: Errors.NotFromAdmin });
    expect(mw.minter.sendSetDeskMinterConfig(stranger.address, 0, minterConfig(mw, null), { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetDeskMinterConfig>({ to: mw.minter.address, exitCode: Errors.NotFromAdmin });
    expect(mw.minter.sendChangeDeskMinterAdmin(stranger.address, 0, stranger.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<ChangeDeskMinterAdmin>({ to: mw.minter.address, exitCode: Errors.NotFromAdmin });
    expect(mw.minter.sendDeployDeskOk(stranger.address, 0, 0, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<DeployDeskOk>({ to: mw.minter.address, exitCode: Errors.NotFromCollection });

    expect(mw.minter.sendChangeDeskMinterAdmin(w.admin.address, 0, stranger.address, { value: ton("0.05") }))
        .toHaveSuccessfulTx<ChangeDeskMinterAdmin>({ to: mw.minter.address });
    expect(mw.minter.getMinterData().admin).toEqual(stranger.address);
    expect(mw.minter.sendSetDeskMinterPaused(w.admin.address, 0, true, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetDeskMinterPaused>({ to: mw.minter.address, exitCode: Errors.NotFromAdmin });
    expect(mw.minter.sendSetDeskMinterPaused(stranger.address, 0, true, { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetDeskMinterPaused>({ to: mw.minter.address });
    expect(mw.minter.getMinterData().paused).toBeTrue();
}
