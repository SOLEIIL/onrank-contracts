// The creator-fee contract forwards native GRAM into the existing splitter. Not a pool test.
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@wrappers/CreatorFee.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@contracts/launcher-dex/CreatorFee"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/pot/pot-messages"

const FEE = 10000000 // 0.01 GRAM

fun setupFee(): FeeSplitterV2 {
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("fee-admin");
    val vault = testing.treasury("fee-vault");
    val protocol = testing.treasury("fee-protocol");
    val pot = testing.treasury("fee-pot");
    val buyback = testing.treasury("fee-buyback");
    val splitter = FeeSplitterV2.fromStorage({
        admin: admin.address,
        active: true,
        locked: 0,
        accrued: 0,
        totalIn: 0,
        minSplit: 0,
        minProtocolBps: 1000,
        routes: FeeRoutes {
            protocol: protocol.address,
            pot: pot.address,
            buyback: buyback.address,
        }.toCell(),
        reward: RewardRoute {
            vault: vault.address,
            splits: {
                holdersBps: 7000,
                protocolBps: 1500,
                potBps: 1000,
                buybackBps: 500,
            },
        }.toCell(),
        proposal: null,
    });
    expect(
        splitter.deploy(admin.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: splitter.address });
    return splitter;
}

get fun `test creator fee: 0.01 GRAM splits 70 15 10 5 and a pool fee is not added`() {
    val splitter = setupFee();
    val payer = testing.treasury("fee-payer");
    val forwarder = CreatorFee.fromStorage({
        splitter: splitter.address,
        accrued: 0,
        master: payer.address,
        keeper: payer.address,
    });
    expect(
        forwarder.deploy(payer.address, { value: ton("0.05"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: forwarder.address });

    // 0.01 is the creator fee. The 0.001 base-pool fee is not attached and not forwarded.
    val res = net.send(
        payer.address,
        createMessage({
            bounce: true,
            value: FEE + ton("0.05"),
            dest: forwarder.address,
            body: CreatorFeeIn {
                queryId: 1,
                amount: FEE,
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<FeeIn>({ from: forwarder.address, to: splitter.address });
    expect(splitter.getSplitterData().totalIn).toEqual(FEE);
    expect(res).toHaveTx<RewardIn>({
        from: splitter.address,
        value: (FEE * 7000) / 10000,
    });
    expect(res).toHaveTx({
        from: splitter.address,
        to: splitter.getSplitterData().routes.protocol,
        value: (FEE * 1500) / 10000,
    });
    expect(res).toHaveTx<PotTopUp>({ from: splitter.address, value: (FEE * 1000) / 10000 });
    expect(res).toHaveTx<BuybackIn>({ from: splitter.address, value: (FEE * 500) / 10000 });
    val holders = (FEE * 7000) / 10000;
    val protocol = (FEE * 1500) / 10000;
    val pot = (FEE * 1000) / 10000;
    val buyback = (FEE * 500) / 10000;
    expect(holders).toEqual(7000000);
    expect(protocol).toEqual(1500000);
    expect(pot).toEqual(1000000);
    expect(buyback).toEqual(500000);
    expect(holders + protocol + pot + buyback).toEqual(FEE);
}
