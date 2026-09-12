// Launcher v2: FactoryV2 launches (4 contracts wired in one transaction), config bounds, 48 h
// timelock on codes / roles, admin premint, and the real RewardVaultV2 payout paths.
import "@stdlib/strings"
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@acton/types/big_array"
import "@acton/types/transaction"
import "@tests/fixtures"
import "@tests/v2-fixtures"
import "@wrappers/CurveV2.gen"
import "@wrappers/FactoryV2.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/PoolV2.gen"
import "@wrappers/RewardMasterV2.gen"
import "@wrappers/RewardVaultV2.gen"
import "@wrappers/RewardWalletV2.gen"
import "@wrappers/utils"
import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher-v2/factory-messages"
import "@contracts/launcher-v2/factory-types"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/launcher-v2/reward-types"
import "@contracts/launcher-v2/vault-messages"
import "@contracts/launcher-v2/vault-types"
import "@contracts/vendor/jetton/messages"

struct FactoryWorld {
    factory: FactoryV2
    admin: Treasury
    keeper: Treasury
    protocol: Treasury
    pot: Treasury
    buyback: Treasury
    dex: Treasury
    issuer: Treasury
    creator: Treasury
    usdt: JettonMinter
    other: JettonMinter
}

struct Launched {
    master: RewardMasterV2
    vault: RewardVaultV2
    splitter: FeeSplitterV2
    curve: CurveV2
}

const LAUNCH_FEE = ton("0.5")

fun named(prefix: string, i: int): string {
    return StringBuilder.create().append(prefix).appendInt(i).build();
}

fun v2Codes(): FactoryCodes {
    return {
        master: build("RewardMasterV2"),
        vault: build("RewardVaultV2"),
        splitter: build("FeeSplitterV2"),
        more: FactoryCodesMore {
            curve: build("CurveV2"),
            wallet: build("RewardWalletV2"),
        }.toCell(),
    };
}

fun curveDefaults(sellOut: bool = true): CurveDefaults {
    return {
        feeBps: FEE_BPS,
        curveSupply: CURVE_SUPPLY,
        poolSupply: POOL_SUPPLY,
        graduationTon: GRADUATION_TON,
        graduationFee: GRADUATION_FEE,
        minBuy: ton("0.1"),
        poolLpFeeBps: 100,
        poolProtocolFeeBps: 100,
        virtualTon0: V_TON0,
        virtualToken0: V_TOKEN0,
        sellOutGraduation: sellOut,
    };
}

fun factoryConfig(dex: address, usdt: address, curve: CurveDefaults): FactoryConfig {
    var dexPools: map<address, bool> = [];
    dexPools.set(dex, true);
    var whitelist: map<address, bool> = [];
    whitelist.set(usdt, true);
    return {
        launchFee: LAUNCH_FEE,
        vaultReserve: ton("0.5"),
        vaultPendingTimeout: 600,
        minSplit: 0,
        minProtocolBps: 1000,
        splits: {
            holdersBps: 7000,
            protocolBps: 1500,
            potBps: 1000,
            buybackBps: 500,
        },
        curve: curve.toCell(),
        dexVault: dex,
        dexPools,
        rewardWhitelist: whitelist,
    };
}

fun setupFactory(): FactoryWorld {
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("f2-admin");
    val keeper = testing.treasury("f2-keeper");
    val protocol = testing.treasury("f2-protocol");
    val pot = testing.treasury("f2-pot");
    val buyback = testing.treasury("f2-buyback");
    val dex = testing.treasury("f2-dex");
    val issuer = testing.treasury("f2-issuer");
    val creator = testing.treasury("f2-creator");
    val usdt = deployJetton(issuer, "USDT");
    val other = deployJetton(issuer, "OTHER");

    val factory = FactoryV2.fromStorage({
        seq: 0,
        paused: false,
        roles: FactoryRoles {
            admin: admin.address,
            keeper: keeper.address,
            protocol: protocol.address,
        }.toCell(),
        routes: FactoryRoutes {
            pot: pot.address,
            buyback: buyback.address,
        }.toCell(),
        config: factoryConfig(dex.address, usdt.address, curveDefaults()).toCell(),
        gov: FactoryGovernance {
            codes: v2Codes().toCell(),
            proposal: null,
        }.toCell(),
    });
    expect(
        factory.deploy(admin.address, { value: ton("1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    return {
        factory,
        admin,
        keeper,
        protocol,
        pot,
        buyback,
        dex,
        issuer,
        creator,
        usdt,
        other,
    };
}

fun rewardsOf(a: address): map<uint8, address> {
    var m: map<uint8, address> = [];
    m.set(0, a);
    return m;
}

fun launched(
    w: FactoryWorld,
    seq: int,
    metadata: cell,
    rewards: map<uint8, address>,
    premint: Cell<Premint>? = null,
): Launched {
    val a = w.factory.getLaunchAddresses(seq as uint64, metadata, rewards, null, premint);
    val more = a.more.load();
    return {
        master: RewardMasterV2.fromAddress(a.master),
        vault: RewardVaultV2.fromAddress(a.vault),
        splitter: FeeSplitterV2.fromAddress(more.splitter),
        curve: CurveV2.fromAddress(more.curve),
    };
}

fun createLaunch(
    w: FactoryWorld,
    from: address,
    metadata: cell,
    rewards: map<uint8, address>,
    firstBuyTon: coins,
    value: coins,
    splits: FeeSplits? = null,
    premint: Cell<Premint>? = null,
): SendResultList {
    return w
        .factory
        .sendCreateLaunch(
            from,
            1,
            metadata,
            rewards,
            firstBuyTon,
            splits,
            premint,
            { value, bounce: true },
        );
}

fun walletOf(l: Launched, owner: address): RewardWalletV2 {
    return RewardWalletV2.fromAddress(l.master.getWalletAddress(owner));
}

fun coinBalance(l: Launched, owner: address): int {
    return walletOf(l, owner).getRewardWalletData().balance;
}

fun claimableOf(l: Launched, owner: address, id: int): int {
    return amountOf(
        walletOf(l, owner).getClaimable(l.master.getRewardMasterData().indices),
        id as uint8,
    );
}

// ---------------------------------------------------------------------------
// Launch
// ---------------------------------------------------------------------------

get fun `test factory v2: one transaction deploys, wires and opens a coin; the creator gets its first buy`() {
    val w = setupFactory();
    val meta = jettonMetadata("ALPHA");
    val rewards = rewardsOf(w.usdt.address);
    val l = launched(w, 0, meta, rewards);
    val creatorBefore = testing.getAccountBalance(w.creator.address);

    val res = createLaunch(
        w,
        w.creator.address,
        meta,
        rewards,
        ton("2"),
        LAUNCH_FEE + ton("2") + ton("0.15") + ton("0.04") + ton("1"),
    );
    expect(res).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.master.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.vault.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.splitter.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.curve.address });
    expect(res).toHaveSuccessfulTx<WireMaster>({ from: w.factory.address, to: l.master.address });
    expect(res).toHaveSuccessfulTx<OpenCurve>({ from: w.factory.address, to: l.curve.address });
    expect(res).toHaveSuccessfulTx<Buy>({ from: w.factory.address, to: l.curve.address });
    expect(res).toHaveSuccessfulTx<ResponseWalletAddress>({
        from: w.usdt.address,
        to: l.vault.address,
    });

    val m = l.master.getRewardMasterData();
    expect(m.roles.curve!).toEqual(l.curve.address);
    expect(m.roles.vault!).toEqual(l.vault.address);
    expect(m.curveOpen).toBeTrue();
    expect(l.curve.getCurveData().state).toEqual(CURVE_OPEN);
    expect(coinBalance(l, w.creator.address) > 0).toBeTrue();
    expect(m.totalSupply).toEqual(coinBalance(l, w.creator.address));
    expect(l.vault.getVaultData().rewards.mustGet(0).vaultWallet!).toEqual(
        w.usdt.getWalletAddress(l.vault.address),
    );
    expect(l.vault.getVaultData().roles.walletCode.hash()).toEqual(build("RewardWalletV2").hash());
    expect(l.splitter.getSplitterData().reward.vault!).toEqual(l.vault.address);
    expect(l.splitter.getSplitterData().active).toBeTrue();
    expect(l.master.getCodeVersion()).toEqual(2);
    expect(w.factory.getFactoryData().seq).toEqual(1);

    val ev = findEvent<LaunchCreatedEvent>(res, w.factory.address, EVENT_TOPIC_LAUNCH_CREATED);
    expect(ev!.codeVersion).toEqual(2);
    expect(ev!.preminted).toEqual(0);
    expect(ev!.rewardCount).toEqual(1);
    // the creator paid the fee, the first buy and gas; the unspent gas came back
    expect(
        testing.getAccountBalance(w.creator.address) >
        creatorBefore - LAUNCH_FEE - ton("2") - ton("0.7"),
    ).toBeTrue();
    expect(
        testing.getAccountBalance(w.protocol.address) >= ton("10000") + LAUNCH_FEE - ton("0.01"),
    ).toBeTrue();
}

get fun `test factory v2: refusals — reward not whitelisted, non-admin splits or premint, paused, underpaid`() {
    val w = setupFactory();
    val meta = jettonMetadata("BETA");
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.other.address),
            0,
            LAUNCH_FEE + ton("1.04"),
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.DestNotWhitelisted });
    val splits: FeeSplits = {
        holdersBps: 0,
        protocolBps: 5000,
        potBps: 5000,
        buybackBps: 0,
    };
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.usdt.address),
            0,
            LAUNCH_FEE + ton("1.04"),
            splits,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
    var holders: map<address, coins> = [];
    holders.set(w.creator.address, 10 * COIN);
    val premint = Premint {
        holders,
        sold: 10 * COIN,
        seedTon: ton("1"),
    }.toCell();
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.usdt.address),
            0,
            LAUNCH_FEE + ton("3"),
            null,
            premint,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.usdt.address),
            ton("1"),
            LAUNCH_FEE + ton("1.5"),
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.LaunchFeeUnpaid });
    // an admin split below the protocol floor is refused too
    val low: FeeSplits = {
        holdersBps: 9500,
        protocolBps: 500,
        potBps: 0,
        buybackBps: 0,
    };
    expect(
        createLaunch(
            w,
            w.admin.address,
            meta,
            rewardsOf(w.usdt.address),
            0,
            LAUNCH_FEE + ton("1.04"),
            low,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.InvalidSplits });

    expect(
        w
            .factory
            .sendSetFactoryPaused(w.admin.address, 1, true, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<SetFactoryPaused>({ to: w.factory.address });
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.usdt.address),
            0,
            LAUNCH_FEE + ton("1.04"),
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.FactoryPaused });
    expect(w.factory.getFactoryData().seq).toEqual(0);
}

get fun `test factory v2: the required value covers every send — 5 rewards + first buy at the exact minimum`() {
    val w = setupFactory();
    val meta = jettonMetadata("FIVE");
    // whitelist five reward masters (addresses only: undiscovered slots are fine for this test)
    var cfg = factoryConfig(w.dex.address, w.usdt.address, curveDefaults());
    var rewards: map<uint8, address> = [];
    var i = 0;
    while (i < 5) {
        val m = testing.treasury(named("f2-reward-", i)).address;
        cfg.rewardWhitelist.set(m, true);
        rewards.set(i as uint8, m);
        i += 1;
    }
    expect(
        w
            .factory
            .sendSetFactoryConfig(w.admin.address, 1, cfg, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<SetFactoryConfig>({ to: w.factory.address });
    // launchFee + firstBuy + CURVE_BUY_GAS + 5 × VAULT_DISCOVERY_PER_REWARD + LAUNCH_GAS
    val minimum = LAUNCH_FEE + ton("2") + ton("0.15") + 5 * ton("0.04") + ton("1");
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewards,
            ton("2"),
            minimum - 1,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.LaunchFeeUnpaid });
    val l = launched(w, 0, meta, rewards);
    val res = createLaunch(
        w,
        w.creator.address,
        meta,
        rewards,
        ton("2"),
        minimum,
    );
    expect(res).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    expect(res).toHaveSuccessfulDeploy({ to: l.vault.address });
    expect(res).toHaveSuccessfulTx<Buy>({ from: w.factory.address, to: l.curve.address });
    expect(res).toHaveSuccessfulTx<ReturnExcessesBack>({
        from: w.factory.address,
        to: w.creator.address,
    });
    expect(l.vault.getVaultData().rewardCount).toEqual(5);
    expect(coinBalance(l, w.creator.address) > 0).toBeTrue();
    // config bounds added with the fix
    var tiny = curveDefaults();
    tiny.minBuy = ton("0.001");
    expect(
        w
            .factory
            .sendSetFactoryConfig(
                w.admin.address,
                1,
                factoryConfig(w.dex.address, w.usdt.address, tiny),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    var flat = curveDefaults();
    flat.virtualTon0 = 0;
    expect(
        w
            .factory
            .sendSetFactoryConfig(
                w.admin.address,
                1,
                factoryConfig(w.dex.address, w.usdt.address, flat),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidParams });
}

get fun `test factory v2: a premint of MAX_PREMINT holders fits one transaction`() {
    val w = setupFactory();
    val meta = jettonMetadata("BIG");
    val rewards = rewardsOf(w.usdt.address);
    var holders: map<address, coins> = [];
    var i = 0;
    while (i < MAX_PREMINT) {
        holders.set(testing.treasury(named("f2-premint-", i)).address, 1 * COIN);
        i += 1;
    }
    val sold = MAX_PREMINT * COIN;
    val seed = (V_TON0 * sold + (V_TOKEN0 - sold) - 1) / (V_TOKEN0 - sold);
    val premint = Premint {
        holders,
        sold,
        seedTon: seed,
    }.toCell();
    val l = launched(w, 0, meta, rewards, premint);
    val res = createLaunch(
        w,
        w.admin.address,
        meta,
        rewards,
        0,
        LAUNCH_FEE + ton("1") + ton("0.04") + seed + MAX_PREMINT * ton("0.05"),
        null,
        premint,
    );
    expect(res).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    val tx = res.findTransaction<CreateLaunch>({ to: w.factory.address });
    println("premint {} holders: factory tx fees {} nanoTON", MAX_PREMINT, tx!.totalFees.grams);
    expect(l.master.getRewardMasterData().totalSupply).toEqual(sold);
    expect(coinBalance(l, testing.treasury(named("f2-premint-", 0)).address)).toEqual(1 * COIN);
    expect(coinBalance(l, testing.treasury(named("f2-premint-", MAX_PREMINT - 1)).address)).toEqual(
        1 * COIN,
    );
    expect(l.curve.getCurveData().sold).toEqual(sold);
}

get fun `test factory v2: config bounds — an unreachable graduationTon needs the sell-out flag`() {
    val w = setupFactory();
    // a graduationTon above the sell-out cost of the curve (~88.8 TON here) is refused without the flag
    var unreachable = curveDefaults(false);
    unreachable.graduationTon = ton("200");
    val strict = factoryConfig(w.dex.address, w.usdt.address, unreachable);
    expect(
        w
            .factory
            .sendSetFactoryConfig(w.admin.address, 1, strict, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    var reachable = curveDefaults(false);
    reachable.graduationTon = ton("40");
    expect(
        w
            .factory
            .sendSetFactoryConfig(
                w.admin.address,
                1,
                factoryConfig(w.dex.address, w.usdt.address, reachable),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveSuccessfulTx<SetFactoryConfig>({ to: w.factory.address });
    expect(w.factory.getFactoryData().config.curve.load().graduationTon).toEqual(ton("40"));
    // fee above 10 %, graduation fee below gas + margin, splits under the protocol floor
    var greedy = curveDefaults();
    greedy.feeBps = 1500;
    expect(
        w
            .factory
            .sendSetFactoryConfig(
                w.admin.address,
                1,
                factoryConfig(w.dex.address, w.usdt.address, greedy),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    var cheap = curveDefaults();
    cheap.graduationFee = ton("0.3");
    expect(
        w
            .factory
            .sendSetFactoryConfig(
                w.admin.address,
                1,
                factoryConfig(w.dex.address, w.usdt.address, cheap),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    var cfg = factoryConfig(w.dex.address, w.usdt.address, curveDefaults());
    cfg.splits = {
        holdersBps: 9500,
        protocolBps: 500,
        potBps: 0,
        buybackBps: 0,
    };
    expect(
        w
            .factory
            .sendSetFactoryConfig(w.admin.address, 1, cfg, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.InvalidSplits });
    expect(
        w
            .factory
            .sendSetFactoryConfig(w.creator.address, 1, cfg, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<SetFactoryConfig>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
}

get fun `test factory v2: codes and roles change through the 48 h timelock`() {
    val w = setupFactory();
    var codes = v2Codes();
    codes.splitter = build("FeeSplitter");
    expect(
        w
            .factory
            .sendProposeFactoryChange(
                w.creator.address,
                1,
                PROPOSAL_CODES as uint8,
                codes.toCell(),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<ProposeFactoryChange>({
        to: w.factory.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(
        w
            .factory
            .sendProposeFactoryChange(
                w.admin.address,
                1,
                9,
                codes.toCell(),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<ProposeFactoryChange>({
        to: w.factory.address,
        exitCode: Errors.InvalidParams,
    });
    expect(
        w.factory.sendApplyFactoryChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<ApplyFactoryChange>({
        to: w.factory.address,
        exitCode: Errors.NothingPending,
    });

    expect(
        w
            .factory
            .sendProposeFactoryChange(
                w.admin.address,
                1,
                PROPOSAL_CODES as uint8,
                codes.toCell(),
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveSuccessfulTx<ProposeFactoryChange>({ to: w.factory.address });
    expect(w.factory.getFactoryData().proposal!.readyAt).toEqual(WORLD_T0 + FACTORY_DELAY);
    expect(
        w.factory.sendApplyFactoryChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<ApplyFactoryChange>({
        to: w.factory.address,
        exitCode: Errors.PendingNotExpired,
    });
    testing.setNow(WORLD_T0 + FACTORY_DELAY - 1);
    expect(
        w.factory.sendApplyFactoryChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<ApplyFactoryChange>({
        to: w.factory.address,
        exitCode: Errors.PendingNotExpired,
    });
    // launches meanwhile still use the current codes
    expect(w.factory.getFactoryCodes().splitter.hash()).toEqual(build("FeeSplitterV2").hash());
    testing.setNow(WORLD_T0 + FACTORY_DELAY);
    expect(
        w.factory.sendApplyFactoryChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<ApplyFactoryChange>({ to: w.factory.address });
    expect(w.factory.getFactoryCodes().splitter.hash()).toEqual(build("FeeSplitter").hash());
    expect(w.factory.getFactoryData().proposal == null).toBeTrue();

    // roles: same path
    val newAdmin = testing.treasury("f2-admin-2");
    val p = RolesProposal {
        roles: FactoryRoles {
            admin: newAdmin.address,
            keeper: w.keeper.address,
            protocol: w.protocol.address,
        }.toCell(),
        routes: FactoryRoutes {
            pot: w.pot.address,
            buyback: w.buyback.address,
        }.toCell(),
    }.toCell();
    expect(
        w
            .factory
            .sendProposeFactoryChange(
                w.admin.address,
                1,
                PROPOSAL_ROLES as uint8,
                p,
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveSuccessfulTx<ProposeFactoryChange>({ to: w.factory.address });
    testing.setNow(WORLD_T0 + 2 * FACTORY_DELAY);
    expect(
        w.factory.sendApplyFactoryChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<ApplyFactoryChange>({ to: w.factory.address });
    expect(w.factory.getFactoryData().roles.admin).toEqual(newAdmin.address);
    expect(
        w
            .factory
            .sendSetFactoryPaused(w.admin.address, 1, true, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<SetFactoryPaused>({ to: w.factory.address, exitCode: Errors.NotFromAdmin });
}

get fun `test factory v2: governance events — a proposal is announced (applied false), its application too (applied true)`() {
    val w = setupFactory();
    var codes = w.factory.getFactoryCodes();
    codes.splitter = build("FeeSplitter");
    val res = w
        .factory
        .sendProposeFactoryChange(
            w.admin.address,
            1,
            PROPOSAL_CODES as uint8,
            codes.toCell(),
            { value: ton("0.05"), bounce: true },
        );
    val proposed = findEvent<FactoryChangedEvent>(
        res,
        w.factory.address,
        EVENT_TOPIC_FACTORY_CHANGED,
    );
    expect(proposed).toBeNotNull();
    expect(proposed!.applied).toBeFalse();
    expect(proposed!.readyAt).toEqual(WORLD_T0 + FACTORY_DELAY);
    expect(proposed!.kind).toEqual(PROPOSAL_CODES);
    testing.setNow(WORLD_T0 + FACTORY_DELAY);
    val applied = findEvent<FactoryChangedEvent>(
        w.factory.sendApplyFactoryChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
        w.factory.address,
        EVENT_TOPIC_FACTORY_CHANGED,
    );
    expect(applied).toBeNotNull();
    expect(applied!.applied).toBeTrue();
    testing.setNow(WORLD_T0);
}

get fun `test factory v2: a launch with the same reward twice is refused (a duplicate would stall every conversion)`() {
    val w = setupFactory();
    val meta = jettonMetadata("DUP");
    var rewards: map<uint8, address> = [];
    rewards.set(0, w.usdt.address);
    rewards.set(1, w.usdt.address);
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewards,
            0,
            LAUNCH_FEE + ton("1.08"),
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    // same guard on the vault's own AddReward
    val l = launched(w, 0, meta, rewardsOf(w.usdt.address));
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.usdt.address),
            0,
            LAUNCH_FEE + ton("1.04"),
        ),
    ).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    expect(
        l
            .vault
            .sendAddReward(
                w.admin.address,
                1,
                1,
                w.usdt.address,
                { value: ton("0.1"), bounce: true },
            ),
    ).toHaveFailedTx<AddReward>({ to: l.vault.address, exitCode: Errors.InvalidParams });
    expect(
        l
            .vault
            .sendAddReward(
                w.admin.address,
                1,
                1,
                w.other.address,
                { value: ton("0.1"), bounce: true },
            ),
    ).toHaveSuccessfulTx<AddReward>({ to: l.vault.address });
    expect(l.vault.getVaultData().rewardCount).toEqual(2);
}

get fun `test vault v2: DEX whitelist and roles only change through the 48 h timelock; the master never changes`() {
    val w = setupFactory();
    val meta = jettonMetadata("GOV");
    val l = launched(w, 0, meta, rewardsOf(w.usdt.address));
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewardsOf(w.usdt.address),
            0,
            LAUNCH_FEE + ton("1.04"),
        ),
    ).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    val junkPool = testing.treasury("f2-junk-pool").address;
    val dexChange = VaultDexChange {
        pool: junkPool,
        allowed: true,
    }.toCell();

    // not admin → refused ; unknown kind → refused ; nothing to apply → refused
    expect(
        l
            .vault
            .sendProposeVaultChange(
                w.keeper.address,
                1,
                VAULT_PROPOSAL_DEX as uint8,
                dexChange,
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<ProposeVaultChange>({ to: l.vault.address, exitCode: Errors.NotFromAdmin });
    expect(
        l
            .vault
            .sendProposeVaultChange(
                w.admin.address,
                1,
                9,
                dexChange,
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveFailedTx<ProposeVaultChange>({ to: l.vault.address, exitCode: Errors.InvalidParams });
    expect(
        l.vault.sendApplyVaultChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<ApplyVaultChange>({ to: l.vault.address, exitCode: Errors.NothingPending });

    // a compromised admin cannot route the TON through its own pool today: the pool is not whitelisted for 48 h
    val res = l
        .vault
        .sendProposeVaultChange(
            w.admin.address,
            1,
            VAULT_PROPOSAL_DEX as uint8,
            dexChange,
            { value: ton("0.05"), bounce: true },
        );
    expect(res).toHaveSuccessfulTx<ProposeVaultChange>({ to: l.vault.address });
    val ev = findEvent<VaultChangedEvent>(res, l.vault.address, EVENT_TOPIC_VAULT_CHANGED);
    expect(ev).toBeNotNull();
    expect(ev!.applied).toBeFalse();
    expect(l.vault.getVaultData().proposal!.readyAt).toEqual(WORLD_T0 + VAULT_DELAY);
    expect(
        l
            .vault
            .sendConvertReward(
                w.keeper.address,
                2,
                0,
                junkPool,
                ton("0.1"),
                1,
                { value: ton("0.3"), bounce: true },
            ),
    ).toHaveFailedTx<ConvertReward>({ to: l.vault.address, exitCode: Errors.DestNotWhitelisted });
    testing.setNow(WORLD_T0 + VAULT_DELAY - 1);
    expect(
        l.vault.sendApplyVaultChange(w.admin.address, 1, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<ApplyVaultChange>({ to: l.vault.address, exitCode: Errors.PendingNotExpired });
    testing.setNow(WORLD_T0 + VAULT_DELAY);
    val applied = l
        .vault
        .sendApplyVaultChange(w.admin.address, 1, { value: ton("0.05"), bounce: true });
    expect(applied).toHaveSuccessfulTx<ApplyVaultChange>({ to: l.vault.address });
    expect(
        findEvent<VaultChangedEvent>(applied, l.vault.address, EVENT_TOPIC_VAULT_CHANGED)!.applied,
    ).toBeTrue();
    expect(l.vault.getVaultData().proposal == null).toBeTrue();
    // now whitelisted: the same ConvertReward gets past the whitelist (and stops on the budget: empty vault)
    expect(
        l
            .vault
            .sendConvertReward(
                w.keeper.address,
                2,
                0,
                junkPool,
                ton("0.1"),
                1,
                { value: ton("0.3"), bounce: true },
            ),
    ).toHaveFailedTx<ConvertReward>({ to: l.vault.address, exitCode: Errors.BudgetExceeded });

    // roles: keeper changes, master cannot
    val newKeeper = testing.treasury("f2-keeper-2").address;
    val rolesChange = VaultRolesChange {
        admin: w.admin.address,
        keeper: newKeeper,
    }.toCell();
    expect(
        l
            .vault
            .sendProposeVaultChange(
                w.admin.address,
                3,
                VAULT_PROPOSAL_ROLES as uint8,
                rolesChange,
                { value: ton("0.05"), bounce: true },
            ),
    ).toHaveSuccessfulTx<ProposeVaultChange>({ to: l.vault.address });
    testing.setNow(WORLD_T0 + 2 * VAULT_DELAY);
    expect(
        l.vault.sendApplyVaultChange(w.admin.address, 3, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<ApplyVaultChange>({ to: l.vault.address });
    val roles = l.vault.getVaultData().roles;
    expect(roles.keeper).toEqual(newKeeper);
    expect(roles.master).toEqual(l.master.address);
    expect(roles.admin).toEqual(w.admin.address);
    testing.setNow(WORLD_T0);
}

get fun `test factory v2: admin premint — holders get their coins, the curve starts backed and sells work`() {
    val w = setupFactory();
    val meta = jettonMetadata("RANK2");
    val rewards = rewardsOf(w.usdt.address);
    val a = testing.treasury("f2-h-a");
    val b = testing.treasury("f2-h-b");
    val c = testing.treasury("f2-h-c");
    var holders: map<address, coins> = [];
    holders.set(a.address, 100 * COIN);
    holders.set(b.address, 60 * COIN);
    holders.set(c.address, 40 * COIN);
    val d = curveDefaults();
    val sold = 200 * COIN;
    val seed = (V_TON0 * sold + (V_TOKEN0 - sold) - 1) / (V_TOKEN0 - sold);

    // sum must match `sold`, seed must back the curve
    val bad1 = Premint {
        holders,
        sold: 150 * COIN,
        seedTon: seed,
    }.toCell();
    expect(
        createLaunch(
            w,
            w.admin.address,
            meta,
            rewards,
            0,
            LAUNCH_FEE + ton("2") + seed,
            null,
            bad1,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    val bad2 = Premint {
        holders,
        sold,
        seedTon: seed - 1,
    }.toCell();
    expect(
        createLaunch(
            w,
            w.admin.address,
            meta,
            rewards,
            0,
            LAUNCH_FEE + ton("2") + seed,
            null,
            bad2,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.InvalidParams });
    val premint = Premint {
        holders,
        sold,
        seedTon: seed,
    }.toCell();
    expect(
        createLaunch(
            w,
            w.admin.address,
            meta,
            rewards,
            0,
            LAUNCH_FEE + ton("1") + seed,
            null,
            premint,
        ),
    ).toHaveFailedTx<CreateLaunch>({ to: w.factory.address, exitCode: Errors.LaunchFeeUnpaid });

    val l = launched(w, 0, meta, rewards, premint);
    val res = createLaunch(
        w,
        w.admin.address,
        meta,
        rewards,
        0,
        LAUNCH_FEE + ton("2") + seed,
        null,
        premint,
    );
    expect(res).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    expect(res).toHaveSuccessfulTx<PremintCoins>({ from: w.factory.address, to: l.master.address });
    expect(coinBalance(l, a.address)).toEqual(100 * COIN);
    expect(coinBalance(l, b.address)).toEqual(60 * COIN);
    expect(coinBalance(l, c.address)).toEqual(40 * COIN);
    expect(l.master.getRewardMasterData().totalSupply).toEqual(sold);
    val cd = l.curve.getCurveData();
    expect(cd.state).toEqual(CURVE_OPEN);
    expect(cd.sold).toEqual(sold);
    expect(cd.realTon).toEqual(seed);
    expect(cd.virtualToken).toEqual(V_TOKEN0 - sold);
    expect(testing.getAccountBalance(l.curve.address) >= seed).toBeTrue();
    val ev = findEvent<LaunchCreatedEvent>(res, w.factory.address, EVENT_TOPIC_LAUNCH_CREATED);
    expect(ev!.preminted).toEqual(sold);

    // a preminted holder can sell right away: the curve is backed
    val tonBefore = testing.getAccountBalance(a.address);
    val quote = l.curve.getSellQuote(50 * COIN);
    val s = walletOf(l, a.address).sendBurn(a.address, ton("0.2"), 50 * COIN, quote.amountOut);
    expect(s).toHaveSuccessfulTx<SellNotify>({ from: l.master.address, to: l.curve.address });
    expect(coinBalance(l, a.address)).toEqual(50 * COIN);
    expect(
        testing.getAccountBalance(a.address) >= tonBefore + quote.amountOut - ton("0.25"),
    ).toBeTrue();
    expect(l.curve.getCurveData().sold).toEqual(150 * COIN);
    // and a preminted coin earns rewards like any other: nothing is excluded
    expect(l.master.getJettonData().totalSupply).toEqual(150 * COIN);
}

// ---------------------------------------------------------------------------
// Vault: real payouts
// ---------------------------------------------------------------------------

get fun `test vault v2: reward arrival bumps the index, claims are paid in jettons, paid is tracked`() {
    val w = setupFactory();
    val meta = jettonMetadata("GAMMA");
    val rewards = rewardsOf(w.usdt.address);
    val l = launched(w, 0, meta, rewards);
    expect(
        createLaunch(
            w,
            w.creator.address,
            meta,
            rewards,
            0,
            LAUNCH_FEE + ton("1.04"),
        ),
    ).toHaveSuccessfulTx<CreateLaunch>({ to: w.factory.address });
    val a = testing.treasury("f2-a");
    val b = testing.treasury("f2-b");
    expect(
        l.curve.sendBuy(a.address, 3, 0, null, { value: ton("6"), bounce: true }),
    ).toHaveSuccessfulTx<Buy>({ to: l.curve.address });
    expect(
        l.curve.sendBuy(b.address, 3, 0, null, { value: ton("3"), bounce: true }),
    ).toHaveSuccessfulTx<Buy>({ to: l.curve.address });
    val ba = coinBalance(l, a.address);
    val bb = coinBalance(l, b.address);

    // 1000 USDT land in the vault's wallet -> IndexBump
    val arrive = w
        .usdt
        .sendMint(w.issuer.address, l.vault.address, 1000 * REWARD_UNIT, ton("0.05"), ton("0.3"));
    expect(arrive).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: l.vault.address });
    expect(arrive).toHaveSuccessfulTx<IndexBump>({ from: l.vault.address, to: l.master.address });
    val index = indexOf(l.master.getRewardMasterData().indices, 0);
    val owedA = (ba * index) / INDEX_SCALE;
    val owedB = (bb * index) / INDEX_SCALE;
    expect(claimableOf(l, a.address, 0)).toEqual(owedA);
    expect(owedA + owedB <= 1000 * REWARD_UNIT).toBeTrue();

    val res = walletOf(l, a.address).sendClaimRewards(
        a.address,
        5,
        { value: ton("0.15"), bounce: true },
    );
    expect(res).toHaveSuccessfulTx<PayRewardReq>({
        from: walletOf(l, a.address).address,
        to: l.vault.address,
    });
    expect(res).toHaveSuccessfulTx<AskToTransfer>({
        from: l.vault.address,
        to: w.usdt.getWalletAddress(l.vault.address),
    });
    expect(w.usdt.walletOf(a.address).getJettonBalance()).toEqual(owedA);
    expect(claimableOf(l, a.address, 0)).toEqual(0);
    expect(l.vault.getVaultData().rewards.mustGet(0).paid).toEqual(owedA);
    expect(walletOf(l, a.address).getRewardWalletData().pending == null).toBeTrue();
    // a forged request is refused: wrong sender for that owner
    expect(
        l
            .vault
            .sendPayRewardReq(
                b.address,
                1,
                0,
                1,
                b.address,
                { value: ton("0.1"), bounce: true },
            ),
    ).toHaveFailedTx<PayRewardReq>({ to: l.vault.address, exitCode: Errors.NotFromRewardWallet });

    walletOf(l, b.address).sendClaimRewards(b.address, 5, { value: ton("0.15"), bounce: true });
    expect(w.usdt.walletOf(b.address).getJettonBalance()).toEqual(owedB);
    expect(w.usdt.walletOf(l.vault.address).getJettonBalance()).toEqual(
        1000 * REWARD_UNIT - owedA - owedB,
    );
}

get fun `test vault v2: a payout whose jetton transfer bounces is given back to the holder`() {
    // the "master" is a treasury so the test can drive the ack; the vault's reward wallet is a ghost
    val w = setupFactory();
    val master = testing.treasury("f2-master");
    val owner = testing.treasury("f2-owner");
    val ghostWallet = w.usdt.getWalletAddress(w.factory.address);
    var slots: map<uint8, RewardSlot> = [];
    slots.set(
        0,
        {
            rewardMaster: w.usdt.address,
            vaultWallet: ghostWallet,
            carry: 0,
            paid: 5 * REWARD_UNIT,
        },
    );
    val vault = RewardVaultV2.fromStorage({
        rewardCount: 1,
        cycleNext: 0,
        totalTonIn: 0,
        totalTonSpent: 0,
        reserve: ton("0.5"),
        pendingTimeout: 600,
        payoutNonce: 0,
        roles: RewardVaultRoles {
            admin: w.admin.address,
            keeper: w.keeper.address,
            master: master.address,
            walletCode: build("RewardWalletV2"),
        }.toCell(),
        rewards: slots,
        dexVault: w.dex.address,
        pending: null,
        extra: VaultExtra {
            dexPools: [],
            payouts: [],
            proposal: null,
        }.toCell(),
    });
    expect(
        vault.deploy(w.admin.address, { value: ton("1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: vault.address });

    // the wallet lives at its canonical address (the vault checks it) and earns through two steps
    val wallet = walletWithAccrued(master, owner.address, 0);
    val accruedBefore = amountOf(wallet.getRewardWalletData().accrued, 0);
    expect(accruedBefore > 0).toBeTrue();

    // claim: the Settle reaches the treasury "master"; the test answers with the ack
    val claim = wallet.sendClaimRewards(owner.address, 7, { value: ton("0.15"), bounce: true });
    expect(claim).toHaveSuccessfulTx<Settle>({ from: wallet.address, to: master.address });
    val ack = wallet.sendSettleAck(
        master.address,
        7,
        false,
        vault.address,
        [],
        { value: ton("0.12"), bounce: true },
    );
    expect(ack).toHaveSuccessfulTx<PayRewardReq>({ from: wallet.address, to: vault.address });
    // the vault accepted, the transfer to the ghost wallet bounced, the failure went to the master
    expect(ack).toHaveSuccessfulTx<PayRewardFailed>({ from: vault.address, to: master.address });
    expect(vault.getVaultData().rewards.mustGet(0).paid).toEqual(5 * REWARD_UNIT);
    expect(amountOf(wallet.getRewardWalletData().accrued, 0)).toEqual(0);
    // the master relays RestoreAccrued (here: the treasury does it)
    expect(
        wallet.sendRestoreAccrued(
            master.address,
            7,
            0,
            accruedBefore,
            { value: ton("0.02"), bounce: true },
        ),
    ).toHaveSuccessfulTx<RestoreAccrued>({ to: wallet.address });
    expect(amountOf(wallet.getRewardWalletData().accrued, 0)).toEqual(accruedBefore);
    expect(
        wallet.sendRestoreAccrued(
            owner.address,
            7,
            0,
            accruedBefore,
            { value: ton("0.02"), bounce: true },
        ),
    ).toHaveFailedTx<RestoreAccrued>({ to: wallet.address, exitCode: Errors.NotFromMaster });

    // a request for an unknown reward bounces straight back: accrued restored by the wallet itself
    val owner2 = testing.treasury("f2-owner-2");
    val wallet2 = walletWithAccrued(master, owner2.address, 3);
    val accrued2 = amountOf(wallet2.getRewardWalletData().accrued, 3);
    wallet2.sendClaimRewards(owner2.address, 8, { value: ton("0.15"), bounce: true });
    val ack2 = wallet2.sendSettleAck(
        master.address,
        8,
        false,
        vault.address,
        [],
        { value: ton("0.12"), bounce: true },
    );
    expect(
        ack2,
    ).toHaveFailedTx<PayRewardReq>({ from: wallet2.address, to: vault.address, exitCode: Errors.RewardUnknown });
    expect(amountOf(wallet2.getRewardWalletData().accrued, 3)).toEqual(accrued2);
    expect(wallet2.getRewardWalletData().pending == null).toBeTrue();
}

get fun `test vault v2: payouts ring — the 65th request evicts the first; its late bounce cannot restore that holder`() {
    val w = setupFactory();
    val master = testing.treasury("f2-master-ring");
    val ghostWallet = w.usdt.getWalletAddress(w.factory.address);
    var slots: map<uint8, RewardSlot> = [];
    slots.set(
        0,
        {
            rewardMaster: w.usdt.address,
            vaultWallet: ghostWallet,
            carry: 0,
            paid: 0,
        },
    );
    val vault = RewardVaultV2.fromStorage({
        rewardCount: 1,
        cycleNext: 0,
        totalTonIn: 0,
        totalTonSpent: 0,
        reserve: ton("0.5"),
        pendingTimeout: 600,
        payoutNonce: 0,
        roles: RewardVaultRoles {
            admin: w.admin.address,
            keeper: w.keeper.address,
            master: master.address,
            walletCode: build("RewardWalletV2"),
        }.toCell(),
        rewards: slots,
        dexVault: w.dex.address,
        pending: null,
        extra: VaultExtra {
            dexPools: [],
            payouts: [],
            proposal: null,
        }.toCell(),
    });
    expect(
        vault.deploy(w.admin.address, { value: ton("2"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: vault.address });

    var cursors = BigArray<TxCursor>.createEmpty();
    var wallets = BigArray<RewardWalletV2>.createEmpty();
    var owed = BigArray<int>.createEmpty();
    var i = 0;
    while (i < 65) {
        val owner = testing.treasury(named("f2-ring-owner-", i)).address;
        val wal = walletWithAccrued(master, owner, 0);
        wallets.push(wal);
        owed.push(amountOf(wal.getRewardWalletData().accrued, 0));
        wal.sendClaimRewards(owner, 7, { value: ton("0.15"), bounce: true });
        // the "master" acks: wallet -> PayRewardReq -> vault (transfer) ; the bounce of the transfer is held back
        val c = testing.createTraceIterationCursor(
            master.address,
            createMessage({
                bounce: true,
                value: ton("0.12"),
                dest: wal.address,
                body: SettleAck {
                    queryId: 7,
                    retry: false,
                    vault: vault.address,
                    indices: [],
                },
            }),
        );
        c.executeN(3);
        cursors.push(c);
        i += 1;
    }
    expect(vault.getVaultData().payoutNonce).toEqual(65);
    var paidBefore = vault.getVaultData().rewards.mustGet(0).paid;
    i = 0;
    while (i < 65) {
        cursors.get(i).executeAllRemaining();
        i += 1;
    }
    // 64 bounces restored `paid` and reached the master; the evicted one (nonce 1) left `paid` and its holder as they were
    expect(vault.getVaultData().rewards.mustGet(0).paid).toEqual(owed.get(0));
    expect(paidBefore > owed.get(0)).toBeTrue();
}

get fun `test wallet v2: a retried ack freezes the lot conservatively (balance only, not the amount in flight)`() {
    val w = setupFactory();
    val master = testing.treasury("f2-master-retry");
    val owner = testing.treasury("f2-retry-owner").address;
    val wal = walletWithAccrued(master, owner, 0);
    val accrued0 = amountOf(wal.getRewardWalletData().accrued, 0);
    val balance0 = wal.getRewardWalletData().balance; // 11 COIN, stamp = INDEX_SCALE / 2
    expect(
        wal.sendBurn(owner, ton("0.2"), 4 * COIN, null),
    ).toHaveSuccessfulTx<Settle>({ from: wal.address, to: master.address });
    expect(wal.getRewardWalletData().balance).toEqual(balance0 - 4 * COIN);
    var idx: map<uint8, uint128> = [];
    idx.set(
        0,
        INDEX_SCALE as uint128,
    );                                                // index moved from 0.5 to 1.0 since the wallet's last freeze
    expect(
        wal.sendSettleAck(
            master.address,
            0,
            true,
            null,
            idx,
            { value: ton("0.1"), bounce: true },
        ),
    ).toHaveSuccessfulTx<SettleAck>({ to: wal.address });
    val d = wal.getRewardWalletData();
    expect(d.pending == null).toBeTrue();
    // retry: only the 7 coins still here earn the 0.5 delta; a normal ack would have credited the 11
    expect(amountOf(d.accrued, 0)).toEqual(
        accrued0 + ((balance0 - 4 * COIN) * (INDEX_SCALE / 2)) / INDEX_SCALE,
    );
}

/// Deploys the canonical wallet of `owner` for a treasury "master" and makes it earn on reward `id`
/// through two transfer steps (the second one carries a higher index).
fun walletWithAccrued(master: Treasury, owner: address, id: int): RewardWalletV2 {
    val code = build("RewardWalletV2");
    val dest = calcDeployedRewardWallet(owner, master.address, code);
    var idx1: map<uint8, uint128> = [];
    idx1.set(id as uint8, (INDEX_SCALE / 10) as uint128);
    var idx2: map<uint8, uint128> = [];
    idx2.set(id as uint8, (INDEX_SCALE / 2) as uint128);
    val step1 = createMessage({
        bounce: true,
        value: ton("0.1"),
        dest,
        body: RewardTransferStep {
            queryId: 1,
            jettonAmount: 10 * COIN,
            transferInitiator: null,
            sendExcessesTo: null,
            forwardTonAmount: 0,
            indices: idx1,
            forwardPayload: emptyForwardPayload(),
        },
    });
    expect(net.send(master.address, step1)).toHaveSuccessfulDeploy({ to: dest.calculateAddress() });
    val step2 = createMessage({
        bounce: true,
        value: ton("0.1"),
        dest,
        body: RewardTransferStep {
            queryId: 2,
            jettonAmount: 1 * COIN,
            transferInitiator: null,
            sendExcessesTo: null,
            forwardTonAmount: 0,
            indices: idx2,
            forwardPayload: emptyForwardPayload(),
        },
    });
    expect(
        net.send(master.address, step2),
    ).toHaveSuccessfulTx<RewardTransferStep>({ to: dest.calculateAddress() });
    return RewardWalletV2.fromAddress(dest.calculateAddress());
}
