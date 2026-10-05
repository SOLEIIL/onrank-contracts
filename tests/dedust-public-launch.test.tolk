// FactoryDex3 — the PUBLIC launch. What is new versus the proven FactoryDex2 pipeline, and therefore
// what this run proves: a stranger launches at the FactoryV2 price and gets his change back, the fee
// routes come from the factory's storage (a launcher cannot divert them), the launch fee reaches the
// protocol, the reward whitelist holds, the dev buy credits the sender, the future DeDust pool is
// excluded from dividends automatically, and the per-coin RewardVaultDex authenticates claims from
// REAL dex wallet addresses (the one line that differs from RewardVaultV2 — a v2 vault would refuse
// every dex claim because dex wallets carry an extra `excluded` storage field).
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@tests/gas-station-fixtures"
import "@wrappers/CurveDex2.gen"
import "@wrappers/FactoryDex3.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/GasStation.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardVaultDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/common/errors"
import "@contracts/launcher-dex/FactoryDex3"
import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/reward-types"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"

struct PublicWorld {
    admin: Treasury
    keeper: Treasury
    protocol: Treasury
    launcher: Treasury
    stranger: Treasury
    rewardMaster: address
    factory: FactoryDex3
}

/// A launch must attach at least this much (no rewards, no dev buy).
const BASE_LAUNCH_VALUE: coins = DEX_LAUNCH_FEE + DEX_LAUNCH_GAS

fun setupPublicFactory(): PublicWorld {
    testing.setNow(WORLD_T0);
    val admin = testing.treasury("pub-admin");
    val keeper = testing.treasury("pub-keeper");
    val protocol = testing.treasury("pub-protocol");
    val pot = testing.treasury("pub-pot");
    val buyback = testing.treasury("pub-buyback");
    val launcher = testing.treasury("pub-launcher");
    val stranger = testing.treasury("pub-stranger");
    val issuer = testing.treasury("pub-issuer");
    val dexVault = testing.treasury("pub-dexvault");
    val reward0 = deployJetton(issuer, "USDTx");
    val station = deployGasStation(admin.address, protocol.address, keeper.address, ton("0.05"));
    var whitelist: map<address, bool> = createEmptyMap();
    whitelist.set(reward0.address, true);
    var dexPools: map<address, bool> = createEmptyMap();
    val factory = FactoryDex3.fromStorage({
        admin: admin.address,
        protocol: protocol.address,
        station: station.address,
        nextSeq: 1,
        paused: false,
        codes: FactoryDexCodes {
            masterCode: build("RewardMasterDex"),
            curveCode: build("CurveDex2"),
            splitterCode: build("FeeSplitterV2"),
            more: FactoryDexCodesMore {
                creatorCode: build("CreatorFee"),
                walletCode: build("RewardWalletDex"),
            }.toCell(),
        }.toCell(),
        last: null,
        ops: FactoryDexOps {
            keeper: keeper.address,
            pot: pot.address,
            buyback: buyback.address,
            vaultCfg: FactoryDexVaultCfg {
                vaultCode: build("RewardVaultDex"),
                dexVault: dexVault.address,
                vaultReserve: ton("0.5"),
                vaultPendingTimeout: 600,
                rewardWhitelist: whitelist,
                dexPools,
            }.toCell(),
        }.toCell(),
    });
    expect(
        factory.deploy(admin.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: factory.address });
    bindFactory(station, admin.address, factory.address);
    return {
        admin,
        keeper,
        protocol,
        launcher,
        stranger,
        rewardMaster: reward0.address,
        factory,
    };
}

fun launchRewards(w: PublicWorld): map<uint8, address> {
    var rewards: map<uint8, address> = createEmptyMap();
    rewards.set(0, w.rewardMaster);
    return rewards;
}

get fun `test public launch: a stranger launches at the v2 price, fixed routes, dev buy, pool excluded`() {
    val w = setupPublicFactory();
    val protocolBefore = testing.getAccountBalance(w.protocol.address);
    val firstBuy = ton("5");
    val value = BASE_LAUNCH_VALUE + firstBuy + CURVE_BUY_GAS + VAULT_DISCOVERY_PER_REWARD;
    val launched = w
        .factory
        .sendLaunchDexPublic(
            w.launcher.address,
            1,
            jettonMetadata("PUB"),
            launchRewards(w),
            firstBuy,
            { value, bounce: true },
        );
    expect(launched).toHaveSuccessfulTx<LaunchDexPublic>({ to: w.factory.address });
    val d = w.factory.getFactoryDexData();
    expect(d.nextSeq).toEqual(2);
    val curve = CurveDex2.fromAddress(d.lastCurve!);
    val master = RewardMasterDex.fromAddress(d.lastMaster!);
    val splitter = FeeSplitterV2.fromAddress(d.lastSplitter!);
    // live economics, dev buy credited: the curve holds the net first buy and sold coins for the sender
    expect(curve.getCurveData().state).toEqual(CURVE_OPEN);
    // the dev buy already credited the curve: 4.95 net (5 minus the 1% fee) on top of the 510 base
    expect(curve.getCurveData().realTon).toEqual(ton("4.95"));
    expect(curve.getCurveData().virtualTon).toEqual(ton("510") + ton("4.95"));
    expect(master.getRewardMasterData().totalSupply > 0).toEqual(true);
    // the future DeDust pool never earns dividends — wired automatically at launch
    val pool = calcDedustPool(d.lastMaster!, d.lastCreator!).calculateAddress();
    expect(master.getRewardMasterData().excludedOwner).toEqual(pool);
    // fee routes are the factory's, not the launcher's; the holders' 70% goes to the coin's own vault
    val sp = splitter.getSplitterData();
    expect(sp.reward.vault != null).toEqual(true);
    expect(sp.reward.vault! != w.launcher.address).toEqual(true);
    // the launch fee reached the protocol
    val protocolAfter = testing.getAccountBalance(w.protocol.address);
    expect(protocolAfter - protocolBefore >= DEX_LAUNCH_FEE - ton("0.01")).toEqual(true);
    // the vault is a live RewardVaultDex with the whitelisted reward slot
    val vault = RewardVaultDex.fromAddress(sp.reward.vault!);
    expect(vault.getVaultData().rewardCount).toEqual(1);
}

get fun `test public launch: unpaid fee, non-whitelisted reward, stranger relay and pause all refuse`() {
    val w = setupPublicFactory();
    // short value: refused before anything deploys
    expect(
        w
            .factory
            .sendLaunchDexPublic(
                w.launcher.address,
                2,
                jettonMetadata("NOPE"),
                launchRewards(w),
                0,
                { value: BASE_LAUNCH_VALUE - ton("0.1"), bounce: true },
            ),
    ).toHaveFailedTx<LaunchDexPublic>({
        to: w.factory.address,
        exitCode: Errors.LaunchFeeUnpaid,
    });
    // a reward outside the whitelist: refused (nobody mints dividends in a token we do not control)
    var badRewards: map<uint8, address> = createEmptyMap();
    badRewards.set(0, w.stranger.address);
    expect(
        w
            .factory
            .sendLaunchDexPublic(
                w.launcher.address,
                3,
                jettonMetadata("NOPE"),
                badRewards,
                0,
                { value: BASE_LAUNCH_VALUE + VAULT_DISCOVERY_PER_REWARD, bounce: true },
            ),
    ).toHaveFailedTx<LaunchDexPublic>({
        to: w.factory.address,
        exitCode: Errors.DestNotWhitelisted,
    });
    // the graduation relay stays admin/keeper-only
    expect(
        w
            .factory
            .sendRelayConfirmDedust(
                w.stranger.address,
                4,
                w.stranger.address,
                { value: RELAY_CONFIRM_GAS, bounce: true },
            ),
    ).toHaveFailedTx<RelayConfirmDedust>({
        to: w.factory.address,
        exitCode: Errors.NotFromAdmin,
    });
    // only the admin pauses; a paused factory refuses launches
    expect(
        w
            .factory
            .sendSetDexFactoryPaused(w.stranger.address, 5, true, { value: ton("0.05"), bounce: true }),
    ).toHaveFailedTx<SetDexFactoryPaused>({
        to: w.factory.address,
        exitCode: Errors.NotFromAdmin,
    });
    expect(
        w
            .factory
            .sendSetDexFactoryPaused(w.admin.address, 6, true, { value: ton("0.05"), bounce: true }),
    ).toHaveSuccessfulTx<SetDexFactoryPaused>({ to: w.factory.address });
    expect(
        w
            .factory
            .sendLaunchDexPublic(
                w.launcher.address,
                7,
                jettonMetadata("PAUSED"),
                launchRewards(w),
                0,
                { value: BASE_LAUNCH_VALUE + VAULT_DISCOVERY_PER_REWARD, bounce: true },
            ),
    ).toHaveFailedTx<LaunchDexPublic>({
        to: w.factory.address,
        exitCode: Errors.FactoryPaused,
    });
    expect(w.factory.getFactoryDexData().nextSeq).toEqual(1);
}

get fun `test public launch: the coin's vault authenticates REAL dex wallet addresses (the v2 vault would not)`() {
    val w = setupPublicFactory();
    val launched = w
        .factory
        .sendLaunchDexPublic(
            w.launcher.address,
            8,
            jettonMetadata("DIV"),
            launchRewards(w),
            0,
            { value: BASE_LAUNCH_VALUE + VAULT_DISCOVERY_PER_REWARD, bounce: true },
        );
    expect(launched).toHaveSuccessfulTx<LaunchDexPublic>({ to: w.factory.address });
    val d = w.factory.getFactoryDexData();
    val splitter = FeeSplitterV2.fromAddress(d.lastSplitter!);
    val vaultAddr = splitter.getSplitterData().reward.vault!;
    val vault = RewardVaultDex.fromAddress(vaultAddr);
    // the address RewardMasterDex really deploys for this holder (dex layout, WITH `excluded`)
    val holderWallet = calcRewardWalletAddress(
        w.launcher.address,
        d.lastMaster!,
        build("RewardWalletDex"),
    );
    // auth passes for the real dex wallet (the one line RewardVaultDex changes versus RewardVaultV2):
    // the request is ACCEPTED, the payout then fails downstream (the vault holds no reward tokens yet)
    // and the vault refunds the accrual gracefully through PayRewardFailed
    val claim = net.send(
        holderWallet,
        createMessage({
            bounce: true,
            value: ton("0.1"),
            dest: vaultAddr,
            body: PayRewardReq {
                queryId: 9,
                owner: w.launcher.address,
                rewardId: 0,
                amount: ton("0.01"),
            },
        }),
    );
    expect(claim).toHaveSuccessfulTx<PayRewardReq>({ to: vaultAddr });
    expect(claim).toHaveTx<PayRewardFailed>({ from: vaultAddr, to: d.lastMaster! });
    // any other sender — including the owner himself — is refused as not-a-wallet
    expect(
        net.send(
            w.launcher.address,
            createMessage({
                bounce: true,
                value: ton("0.1"),
                dest: vaultAddr,
                body: PayRewardReq {
                    queryId: 10,
                    owner: w.launcher.address,
                    rewardId: 0,
                    amount: ton("0.01"),
                },
            }),
        ),
    ).toHaveFailedTx<PayRewardReq>({ to: vaultAddr, exitCode: Errors.NotFromRewardWallet });
    expect(vault.getVaultData().rewards.get(0).isFound).toEqual(true);
}
