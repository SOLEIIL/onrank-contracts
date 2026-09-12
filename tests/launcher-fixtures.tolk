// Launch world: RewardMaster + RewardVault + FeeSplitter + a real Curve (opened by a "factory"
// treasury). Graduation deploys the Pool.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/fee-splitter-types"
import "@contracts/launcher/launcher-messages"
import "@contracts/launcher/launcher-types"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/Curve.gen"
import "@wrappers/FeeSplitter.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pool.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"

struct LaunchWorld {
    r: RewardWorld
    protocol: Treasury
    pot: Treasury
    buyback: Treasury
    splitter: FeeSplitter
    curve: Curve
}

const CURVE_SUPPLY = 800 * COIN
const POOL_SUPPLY = 200 * COIN
const V_TON0 = ton("30")
const V_TOKEN0 = 1073 * COIN
const GRADUATION_TON = ton("85")
const GRADUATION_FEE = ton("1")

fun curveParams(protocol: address): CurveParams {
    return {
        protocol,
        feeBps: 100,
        curveSupply: CURVE_SUPPLY,
        poolSupply: POOL_SUPPLY,
        graduationTon: GRADUATION_TON,
        graduationFee: GRADUATION_FEE,
        minBuy: ton("0.1"),
        poolLpFeeBps: 100,
        poolProtocolFeeBps: 100,
        walletCode: build("RewardWallet"),
    };
}

fun setupLaunch(): LaunchWorld {
    testing.setNow(WORLD_T0);
    val factory = testing.treasury("r-factory");
    val keeper = testing.treasury("r-keeper");
    val admin = testing.treasury("r-admin");
    val issuer = testing.treasury("r-issuer");
    val dex = testing.treasury("r-dex");
    val pool = testing.treasury("r-pool");
    val protocol = testing.treasury("l-protocol");
    val pot = testing.treasury("l-pot");
    val buyback = testing.treasury("l-buyback");

    val reward0 = deployJetton(issuer, "AAPLx");
    val reward1 = deployJetton(issuer, "NVDAx");

    val master = RewardMaster.fromStorage({
        totalSupply: 0,
        excluded: 0,
        curveOpen: false,
        pool: null,
        roles: RewardMasterRoles { factory: factory.address, seq: 0, curve: null, vault: null }.toCell(),
        indices: createEmptyMap(),
        remainders: createEmptyMap(),
        metadata: jettonMetadata("COIN"),
    });
    expect(master.deploy(factory.address, { value: ton("0.5"), bounce: false })).toHaveSuccessfulDeploy({ to: master.address });

    var dexPools: map<address, bool> = createEmptyMap();
    dexPools.set(pool.address, true);
    val vault = RewardVault.fromStorage({
        rewardCount: 0,
        cycleNext: 0,
        totalTonIn: 0,
        totalTonSpent: 0,
        reserve: ton("0.5"),
        pendingTimeout: 600,
        roles: RewardVaultRoles { admin: admin.address, keeper: keeper.address, master: master.address }.toCell(),
        rewards: createEmptyMap(),
        dexVault: dex.address,
        dexPools,
        pending: null,
    });
    expect(vault.deploy(admin.address, { value: ton("1"), bounce: false })).toHaveSuccessfulDeploy({ to: vault.address });
    addReward(vault, admin.address, 0, reward0);

    val splitter = FeeSplitter.fromStorage({
        admin: factory.address,
        active: true,
        locked: 0,
        accrued: 0,
        totalIn: 0,
        minSplit: 0,
        routes: FeeRoutes { protocol: protocol.address, pot: pot.address, buyback: buyback.address }.toCell(),
        reward: RewardRoute { vault: vault.address, splits: { holdersBps: 7000, protocolBps: 1500, potBps: 1000, buybackBps: 500 } }.toCell(),
    });
    expect(splitter.deploy(factory.address, { value: ton("0.1"), bounce: false })).toHaveSuccessfulDeploy({ to: splitter.address });

    val curve = Curve.fromStorage({
        state: CURVE_INIT,
        virtualTon: V_TON0,
        virtualToken: V_TOKEN0,
        realTon: 0,
        sold: 0,
        pool: null,
        roles: CurveRoles { factory: factory.address, master: master.address, splitter: splitter.address }.toCell(),
        params: curveParams(protocol.address).toCell(),
    });
    expect(curve.deploy(factory.address, { value: ton("0.2"), bounce: false })).toHaveSuccessfulDeploy({ to: curve.address });

    expect(master.sendWireMaster(factory.address, 0, curve.address, vault.address, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<WireMaster>({ to: master.address });

    val r: RewardWorld = { factory, curve: factory, keeper, admin, issuer, dex, pool, reward0, reward1, master, vault };
    return { r, protocol, pot, buyback, splitter, curve };
}

fun openCurve(w: LaunchWorld) {
    expect(w.curve.sendOpenCurve(w.r.factory.address, 0, { value: ton("0.05"), bounce: true })).toHaveSuccessfulTx<OpenCurve>({ to: w.curve.address });
}

fun buy(w: LaunchWorld, who: address, value: coins, minOut: coins = 0, recipient: address? = null): SendResultList {
    return w.curve.sendBuy(who, 3, minOut, recipient, { value, bounce: true });
}

/// Sell on the curve: burn with a SellIntent from the holder's coin wallet.
fun sell(w: LaunchWorld, who: address, amount: coins, minTon: coins, value: coins = ton("0.2")): SendResultList {
    return coinWallet(w.r, who).sendBurn(who, value, amount, minTon);
}

fun poolOf(w: LaunchWorld): Pool {
    return Pool.fromAddress(w.curve.getCurveData().pool!);
}

fun poolBuy(w: LaunchWorld, who: address, value: coins, minOut: coins = 0): SendResultList {
    return poolOf(w).sendSwapTonForCoin(who, 4, minOut, { value, bounce: true });
}

/// Sell on the pool: coin transfer with a SwapCoinForTon forward payload.
fun poolSell(w: LaunchWorld, who: address, amount: coins, minOut: coins, forwardTon: coins = ton("0.12")): SendResultList {
    val payload = SwapCoinForTon { minOut }.toCell();
    return coinWallet(w.r, who).sendTransfer(who, forwardTon + ton("0.15"), amount, poolOf(w).address, who, null, forwardTon, payload);
}

/// Buys until the curve graduates (at most `maxBuys` purchases of `each` TON).
fun graduate(w: LaunchWorld, whale: address, each: coins = ton("20"), maxBuys: int = 10): SendResultList {
    var last: SendResultList = buy(w, whale, each);
    expect(last).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
    var i = 1;
    while (w.curve.getCurveData().state != CURVE_GRADUATED && i < maxBuys) {
        last = buy(w, whale, each);
        expect(last).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
        i += 1;
    }
    expect(w.curve.getCurveData().state).toEqual(CURVE_GRADUATED);
    return last;
}
