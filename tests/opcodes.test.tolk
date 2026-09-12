// Opcode surface: every contract bounces an unknown opcode (0xFFFF) and accepts plain TON; the
// last untested admin message (SetVaultRoles) is admin-only and applied.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/desk/desk-messages"
import "@contracts/desk/desk-types"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/BuybackVault.gen"
import "@wrappers/Curve.gen"
import "@wrappers/DeskMinter.gen"
import "@wrappers/Factory.gen"
import "@wrappers/FeeSplitter.gen"
import "@wrappers/Pool.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"
import "@tests/launcher-fixtures"
import "@tests/factory-fixtures"

fun unknownBody(): cell {
    return beginCell().storeUint(0x12345678, 32).storeUint(0, 64).endCell();
}

fun expectUnknownBounces(from: address, res: SendResultList, to: address) {
    expect(res).toHaveTx({ from, to, success: false, exitCode: 0xFFFF });
}

get fun `test opcodes: launcher contracts bounce unknown opcodes and keep plain ton`() {
    val w = setupLaunch();
    openCurve(w);
    val a = testing.treasury("op-a");
    expect(buy(w, a.address, ton("2"))).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
    graduate(w, a.address);
    val pool = poolOf(w);
    val wallet = coinWallet(w.r, a.address);

    expectUnknownBounces(a.address, w.r.master.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), w.r.master.address);
    expectUnknownBounces(a.address, w.r.vault.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), w.r.vault.address);
    expectUnknownBounces(a.address, wallet.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), wallet.address);
    expectUnknownBounces(a.address, w.curve.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), w.curve.address);
    expectUnknownBounces(a.address, pool.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), pool.address);

    // plain TON: accepted as gas everywhere (state untouched)
    val supply = w.r.master.getRewardMasterData().totalSupply;
    val tonIn = w.r.vault.getVaultData().totalTonIn;
    expect(w.r.master.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: w.r.master.address, success: true });
    expect(w.r.vault.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: w.r.vault.address, success: true });
    expect(wallet.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: wallet.address, success: true });
    expect(w.curve.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: w.curve.address, success: true });
    expect(pool.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: pool.address, success: true });
    expect(w.r.master.getRewardMasterData().totalSupply).toEqual(supply);
    expect(w.r.vault.getVaultData().totalTonIn).toEqual(tonIn);
}

get fun `test opcodes: factory and minter bounce unknown opcodes`() {
    val f = setupFactory();
    val a = testing.treasury("op-a");
    expectUnknownBounces(a.address, f.factory.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), f.factory.address);
    expect(f.factory.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: f.factory.address, success: true });

    val w = setupWorld(10);
    val minter = DeskMinter.fromStorage({
        admin: w.admin.address,
        collection: w.collection.address,
        pot: w.pot.address,
        minted: 0,
        cap: 10,
        paused: false,
        unburned: 0,
        config: DeskMinterConfig { deskJettonWallet: null, protocolWallet: w.admin.address, depositAmount: 1, surcharge: 0, protocolShareBps: 0 }.toCell(),
        pendingDeploys: createEmptyMap(),
    });
    expect(minter.deploy(w.admin.address, { value: ton("0.5"), bounce: false })).toHaveSuccessfulDeploy({ to: minter.address });
    expectUnknownBounces(a.address, minter.sendAny(a.address, unknownBody(), { value: ton("0.05"), bounce: true }), minter.address);
    expect(minter.sendAny(a.address, createEmptyCell(), { value: ton("0.05"), bounce: true })).toHaveTx({ to: minter.address, success: true });
}

get fun `test opcodes: vault roles are admin-only and applied`() {
    val w = setupRewardWorld();
    val a = testing.treasury("op-a");
    val newKeeper = testing.treasury("op-keeper");
    expect(w.vault.sendSetVaultRoles(a.address, 0, w.admin.address, newKeeper.address, w.master.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetVaultRoles>({ to: w.vault.address, exitCode: Errors.NotFromAdmin });
    expect(w.vault.sendSetVaultRoles(w.admin.address, 0, w.admin.address, newKeeper.address, w.master.address, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<SetVaultRoles>({ to: w.vault.address });
    expect(w.vault.getVaultData().roles.keeper).toEqual(newKeeper.address);
    expect(w.vault.getVaultData().roles.admin).toEqual(w.admin.address);
}
