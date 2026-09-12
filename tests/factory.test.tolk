// Factory: one CreateLaunch deploys master + vault + splitter + curve, wires them, opens the
// curve and performs the creator's first buy. Addresses are deterministic and predictable.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher/factory-messages"
import "@contracts/launcher/factory-types"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/fee-splitter-types"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/Curve.gen"
import "@wrappers/Factory.gen"
import "@wrappers/FeeSplitter.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/launcher-fixtures"

import "@tests/factory-fixtures"

get fun `test factory: one message deploys and wires the four contracts, first buy lands with the creator`() {
    val w = setupFactory();
    val metadata = jettonMetadata("COIN");
    val rewards = rewardsOf(w.reward0.address);
    val l = launched(w, 0, metadata, rewards);
    val firstBuy = ton("5");

    val res = w.factory.sendCreateLaunch(w.creator.address, 7, metadata, rewards, firstBuy, null, { value: LAUNCH_FEE + firstBuy + ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.master.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.vault.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.splitter.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.curve.address });
    expect(res).toHaveSuccessfulTx<WireMaster>({ from: w.factory.address, to: l.master.address });
    expect(res).toHaveSuccessfulTx<OpenCurve>({ from: w.factory.address, to: l.curve.address });
    expect(res).toHaveSuccessfulTx<Buy>({ from: w.factory.address, to: l.curve.address });
    expect(res).toHaveSuccessfulTx<MintReward>({ from: l.curve.address, to: l.master.address });
    expect(res).toHaveSuccessfulTx<FeeIn>({ from: l.curve.address, to: l.splitter.address });
    expect(res).toHaveTx({ from: w.factory.address, to: w.protocol.address, value: LAUNCH_FEE });
    expect(res).toHaveSuccessfulTx<ReturnExcessesBack>({ from: w.factory.address, to: w.creator.address });
    // the vault discovered its wallet for the reward jetton
    expect(res).toHaveSuccessfulTx<ResponseWalletAddress>({ from: w.reward0.address, to: l.vault.address });

    // wiring
    val md = l.master.getRewardMasterData();
    expect(md.roles.curve!).toEqual(l.curve.address);
    expect(md.roles.vault!).toEqual(l.vault.address);
    expect(md.roles.factory).toEqual(w.factory.address);
    expect(md.curveOpen).toBeTrue();
    val cd = l.curve.getCurveData();
    expect(cd.state).toEqual(CURVE_OPEN);
    expect(cd.sold > 0).toBeTrue();
    expect(md.totalSupply).toEqual(cd.sold);
    val vd = l.vault.getVaultData();
    expect(vd.rewardCount).toEqual(1);
    expect(vd.rewards.mustGet(0).vaultWallet!).toEqual(w.reward0.getWalletAddress(l.vault.address));
    val sd = l.splitter.getSplitterData();
    expect(sd.active).toBeTrue();
    expect(sd.totalIn > 0).toBeTrue();

    // the creator holds the first-buy coins
    val wallet = RewardWallet.fromAddress(l.master.getWalletAddress(w.creator.address));
    expect(wallet.getRewardWalletData().balance).toEqual(cd.sold);

    expect(w.factory.getFactoryData().seq).toEqual(1);
    // the factory kept its own balance plus only the first-buy gas excess (< 0.1 TON)
    expect(testing.getAccountBalance(w.factory.address) < ton("1.1")).toBeTrue();
}

get fun `test factory: pending launch (no reward) locks the holders share; two launches with the same metadata differ`() {
    val w = setupFactory();
    val metadata = jettonMetadata("COIN");
    val none: map<uint8, address> = createEmptyMap();
    val l0 = launched(w, 0, metadata, none);
    val l1 = launched(w, 1, metadata, none);
    expect(l0.master.address == l1.master.address).toBeFalse();
    expect(l0.curve.address == l1.curve.address).toBeFalse();

    expect(w.factory.sendCreateLaunch(w.creator.address, 1, metadata, none, ton("2"), null, { value: LAUNCH_FEE + ton("3"), bounce: true }))
        .toHaveSuccessfulTx<Buy>({ to: l0.curve.address });
    val sd = l0.splitter.getSplitterData();
    expect(sd.active).toBeFalse();
    expect(sd.locked > 0).toBeTrue();
    expect(l0.vault.getVaultData().rewardCount).toEqual(0);

    // a launch with no first buy is fine too
    expect(w.factory.sendCreateLaunch(w.creator.address, 2, metadata, none, 0, null, { value: LAUNCH_FEE + ton("1"), bounce: true }))
        .toHaveSuccessfulTx<OpenCurve>({ to: l1.curve.address });
    expect(l1.curve.getCurveData().sold).toEqual(0);
    expect(w.factory.getFactoryData().seq).toEqual(2);
}

get fun `test factory: cycle of two rewards, trading after launch works end to end`() {
    val w = setupFactory();
    val metadata = jettonMetadata("CYCLE");
    val rewards = rewardsOf(w.reward0.address, w.reward1.address);
    val l = launched(w, 0, metadata, rewards);
    expect(w.factory.sendCreateLaunch(w.creator.address, 1, metadata, rewards, ton("1"), null, { value: LAUNCH_FEE + ton("2"), bounce: true }))
        .toHaveSuccessfulTx<Buy>({ to: l.curve.address });
    val vd = l.vault.getVaultData();
    expect(vd.rewardCount).toEqual(2);
    expect(vd.rewards.mustGet(0).vaultWallet!).toEqual(w.reward0.getWalletAddress(l.vault.address));
    expect(vd.rewards.mustGet(1).vaultWallet!).toEqual(w.reward1.getWalletAddress(l.vault.address));

    // a second buyer trades on the live curve
    val buyer = testing.treasury("f-buyer");
    val before = l.curve.getCurveData().sold;
    expect(l.curve.sendBuy(buyer.address, 3, 0, null, { value: ton("3"), bounce: true })).toHaveSuccessfulTx<Buy>({ to: l.curve.address });
    expect(l.curve.getCurveData().sold > before).toBeTrue();
    // and the splitter forwarded holders' share to the vault
    expect(l.vault.getVaultData().totalTonIn > 0).toBeTrue();
}

get fun `test factory: $DESK launch — admin-only split {pot 50, protocol 50}, fees never reach holders or buyback`() {
    val w = setupFactory();
    val metadata = jettonMetadata("DESK");
    val none: map<uint8, address> = createEmptyMap();
    val deskSplits: FeeSplits = { holdersBps: 0, protocolBps: 5000, potBps: 5000, buybackBps: 0 };

    // a regular creator cannot pick the split
    expect(w.factory.sendCreateLaunch(w.creator.address, 1, metadata, none, 0, deskSplits, { value: LAUNCH_FEE + ton("1"), bounce: true }))
        .toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
    // and the admin cannot pick a broken one
    expect(w.factory.sendCreateLaunch(w.admin.address, 1, metadata, none, 0, { holdersBps: 0, protocolBps: 5000, potBps: 4000, buybackBps: 0 }, { value: LAUNCH_FEE + ton("1"), bounce: true }))
        .toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.InvalidSplits });

    val a = w.factory.getLaunchAddresses(0, metadata, none, deskSplits.toCell());
    val more = a.more.load();
    val splitter = FeeSplitter.fromAddress(more.splitter);
    val curve = Curve.fromAddress(more.curve);
    val potBefore = testing.getAccountBalance(w.pot.address);
    val protocolBefore = testing.getAccountBalance(w.protocol.address);
    val buybackBefore = testing.getAccountBalance(w.buyback.address);

    val res = w.factory.sendCreateLaunch(w.admin.address, 1, metadata, none, ton("10"), deskSplits, { value: LAUNCH_FEE + ton("11"), bounce: true });
    expect(res).toHaveSuccessfulDeploy({ to: splitter.address });
    expect(res).toHaveSuccessfulTx<Buy>({ to: curve.address });
    expect(res).toHaveSuccessfulTx<FeeIn>({ from: curve.address, to: splitter.address });
    val sd = splitter.getSplitterData();
    expect(sd.reward.splits.potBps).toEqual(5000);
    expect(sd.reward.splits.holdersBps).toEqual(0);
    // pending reward, yet nothing is locked: the holders share is zero
    expect(sd.locked).toEqual(0);
    val fee = sd.totalIn;
    expect(fee).toEqual(ton("10") / 100);
    expect(res).toHaveTx({ from: splitter.address, to: w.pot.address, value: fee / 2 });
    expect(res).toHaveTx({ from: splitter.address, to: w.protocol.address, value: fee - fee / 2 });
    expect(testing.getAccountBalance(w.pot.address) - potBefore > fee / 2 - ton("0.01")).toBeTrue();
    // protocol got the launch fee + half of the trade fee
    expect(testing.getAccountBalance(w.protocol.address) - protocolBefore > LAUNCH_FEE + fee / 2 - ton("0.01")).toBeTrue();
    expect(testing.getAccountBalance(w.buyback.address)).toEqual(buybackBefore);
}

get fun `test factory: guards — fee unpaid, paused, admin-only ops, too many rewards`() {
    val w = setupFactory();
    val metadata = jettonMetadata("COIN");
    val none: map<uint8, address> = createEmptyMap();

    expect(w.factory.sendCreateLaunch(w.creator.address, 1, metadata, none, ton("1"), null, { value: LAUNCH_FEE + ton("1"), bounce: true }))
        .toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.LaunchFeeUnpaid });

    expect(w.factory.sendSetFactoryPaused(w.creator.address, 0, true, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetFactoryPaused>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
    expect(w.factory.sendSetFactoryPaused(w.admin.address, 0, true, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<SetFactoryPaused>({ to: w.factory.address });
    expect(w.factory.sendCreateLaunch(w.creator.address, 1, metadata, none, 0, null, { value: LAUNCH_FEE + ton("1"), bounce: true }))
        .toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.FactoryPaused });
    expect(w.factory.sendSetFactoryPaused(w.admin.address, 0, false, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<SetFactoryPaused>({ to: w.factory.address });

    // six rewards exceed MAX_REWARDS
    var six: map<uint8, address> = createEmptyMap();
    var i = 0;
    while (i < 6) {
        six.set(i as uint8, i % 2 == 0 ? w.reward0.address : w.reward1.address);
        i += 1;
    }
    expect(w.factory.sendCreateLaunch(w.creator.address, 1, metadata, six, 0, null, { value: LAUNCH_FEE + ton("1"), bounce: true }))
        .toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.TooManyRewards });
    expect(w.factory.getFactoryData().seq).toEqual(0);

    // bad splits are refused
    var bad = factoryConfig(w.dex.address);
    bad.splits = { holdersBps: 7000, protocolBps: 1500, potBps: 1000, buybackBps: 400 };
    expect(w.factory.sendSetFactoryConfig(w.admin.address, 0, bad, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidSplits });
    expect(w.factory.sendSetFactoryConfig(w.creator.address, 0, factoryConfig(w.dex.address), { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
}
