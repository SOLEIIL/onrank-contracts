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

fun minterConfig(mw: MinterWorld, wallet: address?, stepEvery: uint32 = 0): DeskMinterConfig {
    return {
        deskJettonWallet: wallet,
        protocolWallet: mw.protocol.address,
        depositAmount: DEPOSIT,
        surcharge: SURCHARGE,
        protocolShareBps: PROTOCOL_BPS,
        stepEvery,
    };
}

/// A minter that starts at `minted` (a v2 taking over from a v1 at that serial), with a price step every `stepEvery` mints.
fun setupMinterAt(cap: uint32, minted: uint32, stepEvery: uint32): MinterWorld {
    val w = setupWorld(cap, minted);
    val protocol = testing.treasury("protocol");
    val deskToken = deployJetton(w.issuer, "DESK");
    var mw: MinterWorld = {
        w,
        deskToken,
        minter: DeskMinter.fromAddress(w.admin.address),
        protocol,
    };
    val minter = DeskMinter.fromStorage({
        admin: w.admin.address,
        collection: w.collection.address,
        pot: w.pot.address,
        minted,
        cap,
        paused: false,
        unburned: 0,
        config: minterConfig(mw, null, stepEvery).toCell(),
        pendingDeploys: createEmptyMap(),
    });
    expect(
        minter.deploy(w.admin.address, { value: ton("1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: minter.address });
    mw.minter = minter;
    expect(
        minter.sendSetDeskMinterConfig(
            w.admin.address,
            0,
            minterConfig(mw, deskToken.getWalletAddress(minter.address), stepEvery),
            { value: ton("0.05") },
        ),
    ).toHaveSuccessfulTx<SetDeskMinterConfig>({ to: minter.address });
    expect(
        w
            .collection
            .sendSetCollectionMinter(w.admin.address, 0, minter.address, { value: ton("0.05") }),
    ).toHaveSuccessfulTx<SetCollectionMinter>({ to: w.collection.address });
    return mw;
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

// ---- price steps (v2: the surcharge doubles every `stepEvery` mints) --------------------------------------------------

/// A bare minter in an existing world whose storage says `minted` desks exist: enough to read the price it quotes
/// (the getter needs no jetton wallet). Each (minted, stepEvery) pair is a distinct storage, hence a distinct address.
fun priceAt(mw: MinterWorld, minted: uint32, stepEvery: uint32): (coins, int) {
    val probe = DeskMinter.fromStorage({
        admin: mw.w.admin.address,
        collection: mw.w.collection.address,
        pot: mw.w.pot.address,
        minted,
        cap: 100000,
        paused: false,
        unburned: 0,
        config: minterConfig(mw, null, stepEvery).toCell(),
        pendingDeploys: createEmptyMap(),
    });
    expect(
        probe.deploy(mw.w.admin.address, { value: ton("0.2"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: probe.address });
    return probe.getMintPrice();
}

get fun `test minter: price doubles at every step boundary and get_minter_data says how many mints are left`() {
    val mw = setupMinter();
    // 0..99 → base, 100..199 → ×2, 200.. → ×4
    var (p, left) = priceAt(mw, 0, 100);
    expect(p).toEqual(SURCHARGE);
    expect(left).toEqual(100);
    (p, left) = priceAt(mw, 99, 100);
    expect(p).toEqual(SURCHARGE);
    expect(left).toEqual(1);
    (p, left) = priceAt(mw, 100, 100);
    expect(p).toEqual(SURCHARGE * 2);
    expect(left).toEqual(100);
    (p, left) = priceAt(mw, 199, 100);
    expect(p).toEqual(SURCHARGE * 2);
    expect(left).toEqual(1);
    (p, left) = priceAt(mw, 200, 100);
    expect(p).toEqual(SURCHARGE * 4);
    expect(left).toEqual(100);
    (p, left) = priceAt(mw, 74, 100);
    expect(p).toEqual(SURCHARGE);
    expect(left).toEqual(26);

    // the same figures through get_minter_data
    val probe = DeskMinter.fromStorage({
        admin: mw.w.admin.address,
        collection: mw.w.collection.address,
        pot: mw.w.pot.address,
        minted: 150,
        cap: 100000,
        paused: false,
        unburned: 0,
        config: minterConfig(mw, null, 100).toCell(),
        pendingDeploys: createEmptyMap(),
    });
    expect(
        probe.deploy(mw.w.admin.address, { value: ton("0.2"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: probe.address });
    val md = probe.getMinterData();
    expect(md.effectiveSurcharge).toEqual(SURCHARGE * 2);
    expect(md.toNextStep).toEqual(50);
    expect(md.config.stepEvery).toEqual(100);
}

get fun `test minter: stepEvery 0 keeps the price flat forever (v1 behaviour)`() {
    val mw = setupMinter();
    var (p, left) = priceAt(mw, 0, 0);
    expect(p).toEqual(SURCHARGE);
    expect(left).toEqual(0);
    (p, left) = priceAt(mw, 4999, 0);
    expect(p).toEqual(SURCHARGE);
    expect(left).toEqual(0);
    // and the plain v1-style minter of this world quotes its base too
    val md = mw.minter.getMinterData();
    expect(md.effectiveSurcharge).toEqual(SURCHARGE);
    expect(md.toNextStep).toEqual(0);
}

get fun `test minter: the number of doublings is capped, no overflow at absurd counts`() {
    val mw = setupMinter();
    // 90000 mints with a step of 1 would be 2^90000: capped at 2^40
    val (p, _) = priceAt(mw, 90000, 1);
    expect(p).toEqual(SURCHARGE << 40);
    val (q, _) = priceAt(mw, 60000, 1);
    expect(q).toEqual(SURCHARGE << 40);
}

get fun `test minter: a takeover at serial 74 mints serial 74 at the base price, the collection accepts it`() {
    val mw = setupMinterAt(500, 74, 100);
    val w = mw.w;
    val user = testing.treasury("user");
    giveDesk(mw, user.address, DEPOSIT);
    expect(w.collection.getCollectionData().nextItemIndex).toEqual(74);
    val res = payMint(mw, user.address, DEPOSIT);
    expect(res).toHaveSuccessfulTx<DeployDesk>({ from: mw.minter.address, to: w
            .collection
            .address });
    expect(res).toHaveSuccessfulTx<DeployDeskOk>({ from: w.collection.address, to: mw
            .minter
            .address });
    expect(DeskItem.fromAddress(w.collection.getNftAddressByIndex(74)).getDeskData().owner).toEqual(
        user.address,
    );
    expect(w.collection.getCollectionData().nextItemIndex).toEqual(75);
    val md = mw.minter.getMinterData();
    expect(md.minted).toEqual(75);
    expect(md.effectiveSurcharge).toEqual(SURCHARGE);
    expect(md.toNextStep).toEqual(25);
}

get fun `test minter: crossing a step — the old price is refused with the deposit returned, the new price mints and splits on the new price`() {
    // the 100th desk was just sold: the next one (serial 100) costs twice the base
    val mw = setupMinterAt(500, 100, 100);
    val w = mw.w;
    val user = testing.treasury("user");
    giveDesk(mw, user.address, 2 * DEPOSIT);
    val supplyBefore = mw.deskToken.getTotalSupply();

    // paying the old price: nothing minted, nothing burned, the deposit comes back
    var res = payMint(mw, user.address, DEPOSIT, SURCHARGE + MINT_GAS + ton("0.02"));
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: mw.minter.address });
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: mw.minter.address, to: mw
            .deskToken
            .getWalletAddress(mw.minter.address) });
    expect(deskBalance(mw, user.address)).toEqual(2 * DEPOSIT);
    expect(mw.deskToken.getTotalSupply()).toEqual(supplyBefore);
    expect(mw.minter.getMinterData().minted).toEqual(100);
    expect(w.collection.getCollectionData().nextItemIndex).toEqual(100);

    // paying the new price: minted, and Pot / protocol are paid on the doubled surcharge
    val price = SURCHARGE * 2;
    res = payMint(mw, user.address, DEPOSIT, price + MINT_GAS + ton("0.02"), ton("3"));
    expect(res).toHaveSuccessfulTx<DeployDesk>({ from: mw.minter.address, to: w
            .collection
            .address });
    expect(res).toHaveSuccessfulTx<PotTopUp>({ from: mw.minter.address, to: w
            .pot
            .address, value: price * (10000 - PROTOCOL_BPS) / 10000 });
    expect(res).toHaveTx({ from: mw.minter.address, to: mw.protocol.address, value: price *
        PROTOCOL_BPS /
        10000 });
    expect(deskBalance(mw, user.address)).toEqual(DEPOSIT);
    expect(mw.deskToken.getTotalSupply()).toEqual(supplyBefore - DEPOSIT);
    expect(
        DeskItem.fromAddress(w.collection.getNftAddressByIndex(100)).getDeskData().owner,
    ).toEqual(user.address);
    val md = mw.minter.getMinterData();
    expect(md.minted).toEqual(101);
    expect(md.effectiveSurcharge).toEqual(price);
    expect(md.toNextStep).toEqual(99);
}

get fun `test minter: the admin can change the step later without redeploying`() {
    val mw = setupMinterAt(500, 250, 100);
    expect(mw.minter.getMinterData().effectiveSurcharge).toEqual(SURCHARGE * 4);
    // step of 50 → 250 / 50 = 5 doublings
    expect(
        mw
            .minter
            .sendSetDeskMinterConfig(
                mw.w.admin.address,
                0,
                minterConfig(mw, mw.deskToken.getWalletAddress(mw.minter.address), 50),
                { value: ton("0.05") },
            ),
    ).toHaveSuccessfulTx<SetDeskMinterConfig>({ to: mw.minter.address });
    expect(mw.minter.getMinterData().effectiveSurcharge).toEqual(SURCHARGE * 32);
    // back to flat
    expect(
        mw
            .minter
            .sendSetDeskMinterConfig(
                mw.w.admin.address,
                0,
                minterConfig(mw, mw.deskToken.getWalletAddress(mw.minter.address), 0),
                { value: ton("0.05") },
            ),
    ).toHaveSuccessfulTx<SetDeskMinterConfig>({ to: mw.minter.address });
    expect(mw.minter.getMinterData().effectiveSurcharge).toEqual(SURCHARGE);
}
