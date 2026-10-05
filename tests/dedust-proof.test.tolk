// Proofs required before a DeDust graduation path exists.
// MockDex is not used: it is not a DeDust pool.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/v2-fixtures"
import "@wrappers/notify-probes"
import "@contracts/common/errors"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/vendor/jetton/messages"

/// Wallet refuses a transfer whose attached value is below forward + 0.1 GRAM,
/// and delivers opcode 0x7362d09c to a contract that understands our notification layout.
get fun `test dedust proof: our notification is delivered when the sender adds 0.1 GRAM`() {
    val w = setupV2();
    val holder = testing.treasury("dedust-holder");
    buyOk(w, holder.address, ton("5"));
    val lot = balanceOf(w, holder.address) / 5;
    val probe = NotifyProbe.fromStorage({ hits: 0, amount: 0 });
    expect(
        probe.deploy(w.factory.address, { value: ton("0.05"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: probe.address });

    val forward = ton("0.05");
    val short = transfer(
        w,
        holder.address,
        probe.address,
        lot,
        ton("0.1"),
        forward,
    );
    expect(short).toHaveFailedTx<AskToTransfer>({
        to: wallet(w, holder.address).address,
        exitCode: Errors.InsufficientValue,
    });
    expect(balanceOf(w, holder.address) > lot).toBeTrue();

    val sent = transfer(
        w,
        holder.address,
        probe.address,
        lot,
        ton("0.2"),
        forward,
    );
    expect(sent).toHaveSuccessfulTx<Settle>({ to: w.master.address });
    expect(sent).toHaveSuccessfulTx<RewardTransferStep>({
        to: wallet(w, probe.address).address,
    });
    expect(sent).toHaveTx<TransferNotificationForRecipient>({
        from: wallet(w, probe.address).address,
        to: probe.address,
        value: forward,
    });
    expect(balanceOf(w, probe.address)).toEqual(lot);
    val (hits, amount) = probe.getNotifyProbe();
    expect(hits).toEqual(1);
    expect(amount).toEqual(lot);
}

/// A receiver that reads `sender` as a plain MsgAddress still credits the amount.
get fun `test dedust proof: a standard TEP-74 parser accepts our notification`() {
    val w = setupV2();
    val holder = testing.treasury("dedust-holder-strict");
    buyOk(w, holder.address, ton("5"));
    val lot = balanceOf(w, holder.address) / 5;
    val sink = StrictNotify.fromStorage({ hits: 0, amount: 0 });
    expect(
        sink.deploy(w.factory.address, { value: ton("0.05"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: sink.address });

    val sent = transfer(
        w,
        holder.address,
        sink.address,
        lot,
        ton("0.2"),
        ton("0.05"),
    );
    expect(sent).toHaveSuccessfulTx<RewardTransferStep>({ to: wallet(w, sink.address).address });
    expect(sent).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: sink.address });
    val (hits, amount) = sink.getStrictNotify();
    expect(hits).toEqual(1);
    expect(amount).toEqual(lot);
    expect(balanceOf(w, sink.address)).toEqual(lot);
}

/// Coins in an ordinary wallet earn. A DeDust pool wallet would take its share of every bump.
get fun `test dedust proof: wallet coins are inside the dividend supply`() {
    val w = setupV2();
    val holder = testing.treasury("dedust-earn-holder");
    val dex = testing.treasury("dedust-earn-pool");
    buyOk(w, holder.address, ton("5"));
    val held = balanceOf(w, holder.address);
    val parked = held / 2;
    expect(
        transfer(w, holder.address, dex.address, parked),
    ).toHaveSuccessfulTx<RewardTransferStep>({
        to: wallet(w, dex.address).address,
    });

    val reward = 100000000; // 100 tokens of a 6-decimal reward
    bump(w, 0, reward);
    val holderDue = claimable(w, holder.address, 0);
    val dexDue = claimable(w, dex.address, 0);
    expect(dexDue > 0).toBeTrue();
    expect(holderDue < reward).toBeTrue();
    expect(holderDue + dexDue <= reward).toBeTrue();
}
