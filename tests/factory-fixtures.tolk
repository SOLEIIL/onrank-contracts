// Shared fixture: a Factory with default config and its treasuries.
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

struct FactoryWorld {
    factory: Factory
    admin: Treasury
    keeper: Treasury
    protocol: Treasury
    pot: Treasury
    buyback: Treasury
    dex: Treasury
    issuer: Treasury
    creator: Treasury
    reward0: JettonMinter
    reward1: JettonMinter
}

const LAUNCH_FEE = ton("0.5")

fun factoryConfig(dex: address): FactoryConfig {
    var dexPools: map<address, bool> = createEmptyMap();
    dexPools.set(dex, true);
    return {
        launchFee: LAUNCH_FEE,
        vaultReserve: ton("0.5"),
        vaultPendingTimeout: 600,
        minSplit: 0,
        splits: { holdersBps: 7000, protocolBps: 1500, potBps: 1000, buybackBps: 500 },
        curve: CurveDefaults {
            feeBps: 100,
            curveSupply: CURVE_SUPPLY,
            poolSupply: POOL_SUPPLY,
            graduationTon: GRADUATION_TON,
            graduationFee: GRADUATION_FEE,
            minBuy: ton("0.1"),
            poolLpFeeBps: 100,
            poolProtocolFeeBps: 100,
            virtualTon0: V_TON0,
            virtualToken0: V_TOKEN0,
        }.toCell(),
        dexVault: dex,
        dexPools,
    };
}

fun setupFactory(): FactoryWorld {
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("f-admin");
    val keeper = testing.treasury("f-keeper");
    val protocol = testing.treasury("f-protocol");
    val pot = testing.treasury("f-pot");
    val buyback = testing.treasury("f-buyback");
    val dex = testing.treasury("f-dex");
    val issuer = testing.treasury("f-issuer");
    val creator = testing.treasury("f-creator");
    val reward0 = deployJetton(issuer, "AAPLx");
    val reward1 = deployJetton(issuer, "NVDAx");

    val factory = Factory.fromStorage({
        seq: 0,
        paused: false,
        roles: FactoryRoles { admin: admin.address, keeper: keeper.address, protocol: protocol.address }.toCell(),
        routes: FactoryRoutes { pot: pot.address, buyback: buyback.address }.toCell(),
        config: factoryConfig(dex.address).toCell(),
        codes: FactoryCodes {
            master: build("RewardMaster"),
            vault: build("RewardVault"),
            splitter: build("FeeSplitter"),
            more: FactoryCodesMore { curve: build("Curve"), wallet: build("RewardWallet") }.toCell(),
        }.toCell(),
    });
    expect(factory.deploy(admin.address, { value: ton("1"), bounce: false })).toHaveSuccessfulDeploy({ to: factory.address });
    return { factory, admin, keeper, protocol, pot, buyback, dex, issuer, creator, reward0, reward1 };
}

fun rewardsOf(a: address, b: address? = null): map<uint8, address> {
    var m: map<uint8, address> = createEmptyMap();
    m.set(0, a);
    if (b != null) {
        m.set(1, b);
    }
    return m;
}

struct Launched {
    master: RewardMaster
    vault: RewardVault
    splitter: FeeSplitter
    curve: Curve
}

fun launched(w: FactoryWorld, seq: int, metadata: cell, rewards: map<uint8, address>): Launched {
    val a = w.factory.getLaunchAddresses(seq as uint64, metadata, rewards, null);
    val more = a.more.load();
    return {
        master: RewardMaster.fromAddress(a.master),
        vault: RewardVault.fromAddress(a.vault),
        splitter: FeeSplitter.fromAddress(more.splitter),
        curve: Curve.fromAddress(more.curve),
    };
}

