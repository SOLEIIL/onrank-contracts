import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/errors"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/fee-splitter-types"
import "@contracts/pot/pot-messages"
import "@wrappers/FeeSplitter.gen"
import "@tests/fixtures"

struct SplitWorld {
    admin: Treasury
    curve: Treasury
    vault: Treasury
    protocol: Treasury
    pot: Treasury
    buyback: Treasury
    splitter: FeeSplitter
}

const SPLIT_T0: uint32 = 1800000000

fun setupSplitter(active: bool, minSplit: coins = ton("0.1")): SplitWorld {
    testing.setNow(SPLIT_T0);
    val admin = testing.treasury("s-admin");
    val curve = testing.treasury("s-curve");
    val vault = testing.treasury("s-vault");
    val protocol = testing.treasury("s-protocol");
    val pot = testing.treasury("s-pot");
    val buyback = testing.treasury("s-buyback");
    val splitter = FeeSplitter.fromStorage({
        admin: admin.address,
        active,
        locked: 0,
        accrued: 0,
        totalIn: 0,
        minSplit,
        routes: FeeRoutes { protocol: protocol.address, pot: pot.address, buyback: buyback.address }.toCell(),
        reward: RewardRoute {
            vault: active ? vault.address : null,
            splits: { holdersBps: 7000, protocolBps: 1500, potBps: 1000, buybackBps: 500 },
        }.toCell(),
    });
    expect(splitter.deploy(admin.address, { value: ton("0.1"), bounce: false })).toHaveSuccessfulDeploy({ to: splitter.address });
    return { admin, curve, vault, protocol, pot, buyback, splitter };
}

fun feeIn(w: SplitWorld, amount: coins, gas: coins = ton("0.05")): SendResultList {
    return w.splitter.sendFeeIn(w.curve.address, 7, amount, { value: amount + gas, bounce: true });
}

get fun `test splitter: 70/15/10/5 split, dust to protocol`() {
    val w = setupSplitter(true);
    val v0 = testing.getAccountBalance(w.vault.address);
    val p0 = testing.getAccountBalance(w.protocol.address);
    val pot0 = testing.getAccountBalance(w.pot.address);
    val b0 = testing.getAccountBalance(w.buyback.address);

    // 1.000000003 TON: 7000/1500/1000/500 bps leave 1 nano of dust
    val amount = ton("1") + 3;
    val res = feeIn(w, amount);
    expect(res).toHaveSuccessfulTx<FeeIn>({ from: w.curve.address, to: w.splitter.address });
    expect(res).toHaveTx<RewardIn>({ from: w.splitter.address, to: w.vault.address, value: (amount * 7000) / 10000 });
    expect(res).toHaveTx<PotTopUp>({ from: w.splitter.address, to: w.pot.address, value: (amount * 1000) / 10000 });
    expect(res).toHaveTx<BuybackIn>({ from: w.splitter.address, to: w.buyback.address, value: (amount * 500) / 10000 });

    val holders = (amount * 7000) / 10000;
    val pot = (amount * 1000) / 10000;
    val buyback = (amount * 500) / 10000;
    val protocol = amount - holders - pot - buyback;
    expect(protocol).toEqual((amount * 1500) / 10000 + 1);
    expect(holders + protocol + pot + buyback).toEqual(amount);
    expect(res).toHaveTx({ from: w.splitter.address, to: w.protocol.address, value: protocol });
    // recipients pay their own receive gas (treasuries): deltas are within 0.001 TON of the shares
    expect(holders - (testing.getAccountBalance(w.vault.address) - v0) < ton("0.001")).toBeTrue();
    expect(pot - (testing.getAccountBalance(w.pot.address) - pot0) < ton("0.001")).toBeTrue();
    expect(buyback - (testing.getAccountBalance(w.buyback.address) - b0) < ton("0.001")).toBeTrue();
    expect(protocol - (testing.getAccountBalance(w.protocol.address) - p0) < ton("0.001")).toBeTrue();

    val ev = findEvent<FeeSplitEvent>(res, w.splitter.address, EVENT_TOPIC_FEE_SPLIT);
    expect(ev).toBeNotNull();
    expect(ev!.amount).toEqual(amount);
    expect(ev!.lockedHolders).toBeFalse();

    val data = w.splitter.getSplitterData();
    expect(data.accrued).toEqual(0);
    expect(data.totalIn).toEqual(amount);
    expect(data.locked).toEqual(0);
    // the splitter never keeps more than its gas leftovers
    expect(testing.getAccountBalance(w.splitter.address) < ton("0.2")).toBeTrue();
}

get fun `test splitter: small fees accrue until minSplit, Distribute flushes`() {
    val w = setupSplitter(true, ton("1"));
    expect(feeIn(w, ton("0.3"))).toHaveSuccessfulTx<FeeIn>({ to: w.splitter.address });
    expect(countEvents(feeIn(w, ton("0.3")), w.splitter.address, EVENT_TOPIC_FEE_SPLIT)).toEqual(0);
    expect(w.splitter.getSplitterData().accrued).toEqual(ton("0.6"));

    expect(w.splitter.sendDistribute(w.curve.address, 1, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<Distribute>({ to: w.splitter.address, exitCode: Errors.BelowThreshold });

    val third = feeIn(w, ton("0.4"));
    expect(countEvents(third, w.splitter.address, EVENT_TOPIC_FEE_SPLIT)).toEqual(1);
    expect(w.splitter.getSplitterData().accrued).toEqual(0);
    expect(w.splitter.getSplitterData().totalIn).toEqual(ton("1"));

    // plain TON is a gas top-up, never a fee
    expect(net.send(w.curve.address, createMessage({ bounce: false, value: ton("1.2"), dest: w.splitter.address, body: createEmptyCell() })))
        .toHaveTx({ to: w.splitter.address });
    expect(w.splitter.getSplitterData().accrued).toEqual(0);

    // fees below minSplit accumulate, an explicit Distribute flushes them
    feeIn(w, ton("0.5"), ton("0.001"));
    expect(feeIn(w, ton("0.5"))).toHaveSuccessfulTx<FeeIn>({ to: w.splitter.address });
    feeIn(w, ton("0.7"));
    expect(w.splitter.getSplitterData().accrued).toEqual(0);
    feeIn(w, ton("0.6"));
    expect(w.splitter.getSplitterData().accrued).toEqual(ton("0.6"));
    val flush = w.splitter.sendDistribute(w.protocol.address, 2, { value: ton("0.05"), bounce: true });
    expect(flush).toHaveFailedTx<Distribute>({ to: w.splitter.address, exitCode: Errors.BelowThreshold });
    feeIn(w, ton("0.6"), ton("0.001"));
    feeIn(w, ton("0.4"));
    expect(w.splitter.getSplitterData().accrued).toEqual(0);
    expect(w.splitter.getSplitterData().totalIn).toEqual(ton("3.2"));
}

get fun `test splitter: pending reward locks the holders share until activation`() {
    val w = setupSplitter(false);
    val v0 = testing.getAccountBalance(w.vault.address);
    val res = feeIn(w, ton("2"));
    expect(res).toHaveSuccessfulTx<FeeIn>({ to: w.splitter.address });
    expect(res).toHaveTx<PotTopUp>({ to: w.pot.address, value: ton("0.2") });
    val ev = findEvent<FeeSplitEvent>(res, w.splitter.address, EVENT_TOPIC_FEE_SPLIT);
    expect(ev!.lockedHolders).toBeTrue();
    expect(testing.getAccountBalance(w.vault.address)).toEqual(v0);
    expect(w.splitter.getSplitterData().locked).toEqual(ton("1.4"));
    expect(testing.getAccountBalance(w.splitter.address) >= ton("1.4")).toBeTrue();

    expect(w.splitter.sendSetSplitterVault(w.curve.address, 0, w.vault.address, true, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSplitterVault>({ to: w.splitter.address, exitCode: Errors.NotFromAdmin });
    expect(w.splitter.sendSetSplitterVault(w.admin.address, 0, w.vault.address, true, { value: ton("0.001"), bounce: true }))
        .toHaveFailedTx<SetSplitterVault>({ to: w.splitter.address, exitCode: Errors.InsufficientValue });

    val activate = w.splitter.sendSetSplitterVault(w.admin.address, 0, w.vault.address, true, { value: ton("0.05"), bounce: true });
    expect(activate).toHaveSuccessfulTx<SetSplitterVault>({ to: w.splitter.address });
    expect(activate).toHaveTx<RewardIn>({ from: w.splitter.address, to: w.vault.address, value: ton("1.4") });
    expect(ton("1.4") - (testing.getAccountBalance(w.vault.address) - v0) < ton("0.001")).toBeTrue();
    val data = w.splitter.getSplitterData();
    expect(data.locked).toEqual(0);
    expect(data.active).toBeTrue();
    expect(data.reward.vault!).toEqual(w.vault.address);

    // once active, the holders share flows straight to the vault
    expect(feeIn(w, ton("1"))).toHaveTx<RewardIn>({ to: w.vault.address, value: ton("0.7") });

    // ... and nobody, admin included, can ever redirect or re-lock it (one-shot, F-03)
    val elsewhere = testing.treasury("elsewhere");
    expect(w.splitter.sendSetSplitterVault(w.admin.address, 0, elsewhere.address, true, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSplitterVault>({ to: w.splitter.address, exitCode: Errors.AlreadyWired });
    expect(w.splitter.sendSetSplitterVault(w.admin.address, 0, w.vault.address, false, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSplitterVault>({ to: w.splitter.address, exitCode: Errors.AlreadyWired });
    expect(w.splitter.getSplitterData().reward.vault!).toEqual(w.vault.address);
    expect(w.splitter.getSplitterData().active).toBeTrue();
}

get fun `test splitter: admin can hand over the role; the old admin loses it`() {
    val w = setupSplitter(false);
    val stranger = testing.treasury("stranger");
    expect(w.splitter.sendChangeSplitterAdmin(stranger.address, 0, stranger.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<ChangeSplitterAdmin>({ to: w.splitter.address, exitCode: Errors.NotFromAdmin });
    expect(w.splitter.sendChangeSplitterAdmin(w.admin.address, 0, stranger.address, { value: ton("0.05") }))
        .toHaveSuccessfulTx<ChangeSplitterAdmin>({ to: w.splitter.address });
    expect(w.splitter.getSplitterData().admin).toEqual(stranger.address);
    // old admin is now a stranger; new admin can act (the splitter is still locked, so wiring is allowed)
    expect(w.splitter.sendSetSplitterVault(w.admin.address, 0, w.vault.address, true, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetSplitterVault>({ to: w.splitter.address, exitCode: Errors.NotFromAdmin });
    expect(w.splitter.sendSetSplitterVault(stranger.address, 0, w.vault.address, true, { value: ton("0.05") }))
        .toHaveSuccessfulTx<SetSplitterVault>({ to: w.splitter.address });
}

get fun `test splitter: fee needs gas, unknown opcodes bounce`() {
    val w = setupSplitter(true);
    expect(feeIn(w, ton("1"), ton("0.01")))
        .toHaveFailedTx<FeeIn>({ to: w.splitter.address, exitCode: Errors.InsufficientValue });
    expect(w.splitter.getSplitterData().totalIn).toEqual(0);

    val junk = beginCell().storeUint(0x12345678, 32).storeUint(0, 64).endCell();
    val res = net.send(w.curve.address, createMessage({ bounce: true, value: ton("0.1"), dest: w.splitter.address, body: junk }));
    expect(res).toHaveFailedTx({ to: w.splitter.address, exitCode: 0xFFFF });
}
