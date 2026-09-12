// Integration: $DESK is a coin launched through the launcher (RewardMaster/RewardWallet).
// The Minter must accept the deposit from a RewardWallet, burn it through the settle round trip
// and deploy the desk; the sell path (SellIntent) must not be usable to pay a mint.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/pot/pot-messages"
import "@contracts/vendor/jetton/messages"
import "@wrappers/Curve.gen"
import "@wrappers/DeskCollection.gen"
import "@wrappers/DeskItem.gen"
import "@wrappers/DeskMinter.gen"
import "@wrappers/Pot.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"
import "@tests/launcher-fixtures"

const RJ_DEPOSIT = 10 * COIN
const RJ_SURCHARGE = ton("1")
const RJ_FORWARD = RJ_SURCHARGE + MINT_GAS + ton("0.02")

struct RjWorld {
    l: LaunchWorld
    w: World
    minter: DeskMinter
    protocol: Treasury
}

fun setupRj(): RjWorld {
    val l = setupLaunch();
    openCurve(l);
    val w = setupWorld(100);
    val protocol = testing.treasury("rj-protocol");
    val minter = DeskMinter.fromStorage({
        admin: w.admin.address,
        collection: w.collection.address,
        pot: w.pot.address,
        minted: 0,
        cap: 100,
        paused: false,
        unburned: 0,
        config: DeskMinterConfig { deskJettonWallet: null, protocolWallet: protocol.address, depositAmount: RJ_DEPOSIT, surcharge: RJ_SURCHARGE, protocolShareBps: 4000 }.toCell(),
        pendingDeploys: createEmptyMap(),
    });
    expect(minter.deploy(w.admin.address, { value: ton("1"), bounce: false })).toHaveSuccessfulDeploy({ to: minter.address });
    val cfg: DeskMinterConfig = { deskJettonWallet: l.r.master.getWalletAddress(minter.address), protocolWallet: protocol.address, depositAmount: RJ_DEPOSIT, surcharge: RJ_SURCHARGE, protocolShareBps: 4000 };
    expect(minter.sendSetDeskMinterConfig(w.admin.address, 0, cfg, { value: ton("0.05") })).toHaveSuccessfulTx<SetDeskMinterConfig>({ to: minter.address });
    expect(w.collection.sendSetCollectionMinter(w.admin.address, 0, minter.address, { value: ton("0.05") })).toHaveSuccessfulTx<SetCollectionMinter>({ to: w.collection.address });
    return { l, w, minter, protocol };
}

fun payMintRj(r: RjWorld, user: address, amount: int, forwardTon: coins = RJ_FORWARD): SendResultList {
    return coinWallet(r.l.r, user).sendTransfer(user, forwardTon + ton("0.2"), amount, r.minter.address, user, null, forwardTon, null);
}

get fun `test mint with $DESK reward jetton: deposit from a RewardWallet is burned through settle and the desk is deployed`() {
    val r = setupRj();
    val user = testing.treasury("rj-user");
    expect(buy(r.l, user.address, ton("5"))).toHaveSuccessfulTx<Buy>({ to: r.l.curve.address });
    val held = coinBalance(r.l.r, user.address);
    expect(held > RJ_DEPOSIT).toBeTrue();
    val supplyBefore = r.l.r.master.getRewardMasterData().totalSupply;
    val minterWallet = r.l.r.master.getWalletAddress(r.minter.address);

    val res = payMintRj(r, user.address, RJ_DEPOSIT);
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ from: minterWallet, to: r.minter.address });
    expect(res).toHaveSuccessfulTx<AskToBurn>({ from: r.minter.address, to: minterWallet });
    expect(res).toHaveSuccessfulTx<Settle>({ from: minterWallet, to: r.l.r.master.address });
    expect(res).toHaveSuccessfulTx<SettleAck>({ from: r.l.r.master.address, to: minterWallet });
    expect(res).toHaveSuccessfulTx<DeployDesk>({ from: r.minter.address, to: r.w.collection.address });
    expect(res).toHaveSuccessfulTx<DeployDeskOk>({ from: r.w.collection.address, to: r.minter.address });
    expect(res).toHaveSuccessfulTx<PotTopUp>({ from: r.minter.address, to: r.w.pot.address });

    expect(r.l.r.master.getRewardMasterData().totalSupply).toEqual(supplyBefore - RJ_DEPOSIT);
    expect(coinBalance(r.l.r, user.address)).toEqual(held - RJ_DEPOSIT);
    expect(coinBalance(r.l.r, r.minter.address)).toEqual(0);
    // the curve did not see a sell: a plain burn is not a SellIntent
    expect(findEvent<CurveTradeEvent>(res, r.l.curve.address, EVENT_TOPIC_CURVE_TRADE) == null).toBeTrue();
    val desk = DeskItem.fromAddress(r.w.collection.getNftAddressByIndex(0));
    expect(desk.getDeskData().owner).toEqual(user.address);
    val md = r.minter.getMinterData();
    expect(md.pendingDeploys.isEmpty()).toBeTrue();
    expect(md.unburned).toEqual(0);
    // nothing left to burn: RetryBurn is refused
    expect(r.minter.sendRetryBurn(user.address, 0, { value: BURN_VALUE, bounce: true }))
        .toHaveFailedTx<RetryBurn>({ to: r.minter.address, exitCode: Errors.NothingPending });
}

get fun `test mint with $DESK reward jetton: wrong amount is returned through the RewardWallet, rewards keep flowing to the payer`() {
    val r = setupRj();
    val user = testing.treasury("rj-user");
    expect(buy(r.l, user.address, ton("5"))).toHaveSuccessfulTx<Buy>({ to: r.l.curve.address });
    val held = coinBalance(r.l.r, user.address);

    val res = payMintRj(r, user.address, RJ_DEPOSIT - 1);
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: r.minter.address });
    // returned: minter's wallet -> settle -> user's wallet
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: r.minter.address });
    expect(r.w.collection.getCollectionData().nextItemIndex).toEqual(0);
    expect(coinBalance(r.l.r, user.address)).toEqual(held);
    expect(coinBalance(r.l.r, r.minter.address)).toEqual(0);
    expect(r.minter.getMinterData().minted).toEqual(0);

    // the user still earns on the full balance afterwards
    arriveReward(r.l.r, 0, 100 * REWARD_UNIT);
    expect(claimable(r.l.r, user.address, 0)).toBeApproxEqAbs(100 * REWARD_UNIT, 1);
}
