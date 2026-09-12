import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@acton/types/transaction"

import "@contracts/common/consts"
import "@contracts/common/dedust"
import "@contracts/common/errors"
import "@contracts/launcher/fee-splitter-messages"
import "@contracts/launcher/reward-messages"
import "@contracts/launcher/reward-types"
import "@contracts/vendor/jetton/messages"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"

// ---------------------------------------------------------------------------
// Mint / TEP-74 surface
// ---------------------------------------------------------------------------

get fun `test reward: curve mints, wallets are deterministic, supply tracked`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    mintCoin(w, a.address, 100 * COIN);

    expect(coinBalance(w, a.address)).toEqual(100 * COIN);
    expect(w.master.getJettonData().totalSupply).toEqual(100 * COIN);
    expect(w.master.getJettonData().mintable).toBeTrue();
    val wd = coinWallet(w, a.address).getWalletData();
    expect(wd.ownerAddress).toEqual(a.address);
    expect(wd.minterAddress).toEqual(w.master.address);
    expect(coinWallet(w, a.address).getRewardWalletData().busy).toBeFalse();

    // only the curve mints
    expect(w.master.sendMintReward(a.address, 1, a.address, COIN, 0, null, { value: ton("0.1"), bounce: true }))
        .toHaveFailedTx<MintReward>({ to: w.master.address, exitCode: Errors.NotFromCurve });
    expect(w.master.getJettonData().totalSupply).toEqual(100 * COIN);
}

get fun `test reward: transfer moves balance, notifies recipient, returns excesses`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    mintCoin(w, a.address, 100 * COIN);

    val res = coinWallet(w, a.address).sendTransfer(a.address, ton("0.25"), 30 * COIN, b.address, a.address, null, ton("0.01"), null);
    expect(res).toHaveSuccessfulTx<AskToTransfer>({ from: a.address, to: coinWallet(w, a.address).address });
    expect(res).toHaveSuccessfulTx<Settle>({ from: coinWallet(w, a.address).address, to: w.master.address });
    expect(res).toHaveSuccessfulTx<SettleAck>({ from: w.master.address, to: coinWallet(w, a.address).address });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({ from: coinWallet(w, a.address).address, to: coinWallet(w, b.address).address });
    expect(res).toHaveTx<TransferNotificationForRecipient>({ from: coinWallet(w, b.address).address, to: b.address, value: ton("0.01") });
    expect(res).toHaveTx<ReturnExcessesBack>({ from: coinWallet(w, b.address).address, to: a.address });

    expect(coinBalance(w, a.address)).toEqual(70 * COIN);
    expect(coinBalance(w, b.address)).toEqual(30 * COIN);
    expect(w.master.getJettonData().totalSupply).toEqual(100 * COIN);
    expect(coinWallet(w, a.address).getRewardWalletData().busy).toBeFalse();
}

get fun `test reward: transfer guards — owner, balance, value, forged step, forged settle`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    mintCoin(w, a.address, 100 * COIN);
    val wa = coinWallet(w, a.address);

    expect(wa.sendTransfer(b.address, ton("0.2"), COIN, b.address, b.address, null, 0, null))
        .toHaveFailedTx<AskToTransfer>({ to: wa.address, exitCode: Errors.NotFromOwner });
    expect(wa.sendTransfer(a.address, ton("0.2"), 101 * COIN, b.address, a.address, null, 0, null))
        .toHaveFailedTx<AskToTransfer>({ to: wa.address, exitCode: Errors.BudgetExceeded });
    expect(wa.sendTransfer(a.address, ton("0.05"), COIN, b.address, a.address, null, 0, null))
        .toHaveFailedTx<AskToTransfer>({ to: wa.address, exitCode: Errors.InsufficientValue });

    // a forged step from a random account (claims to come from b) is rejected
    val forged = RewardTransferStep {
        queryId: 0,
        jettonAmount: 50 * COIN,
        transferInitiator: b.address,
        sendExcessesTo: null,
        forwardTonAmount: 0,
        indices: createEmptyMap(),
        forwardPayload: beginCell().storeUint(0, 1).endCell().beginParse(),
    };
    expect(net.send(b.address, createMessage({ bounce: true, value: ton("0.1"), dest: wa.address, body: forged })))
        .toHaveFailedTx<RewardTransferStep>({ to: wa.address, exitCode: Errors.NotFromRewardWallet });
    expect(coinBalance(w, a.address)).toEqual(100 * COIN);

    // a forged Settle (claim on behalf of a) is rejected by the master
    val settle = Settle {
        queryId: 0,
        owner: a.address,
        balance: 100 * COIN,
        action: ACTION_CLAIM,
        burnAmount: 0,
        sellMinTon: null,
        stamps: createEmptyMap(),
        accrued: createEmptyMap(),
    };
    expect(net.send(b.address, createMessage({ bounce: true, value: ton("0.3"), dest: w.master.address, body: settle })))
        .toHaveFailedTx<Settle>({ to: w.master.address, exitCode: Errors.NotFromRewardWallet });

    // wiring / bumps are restricted
    expect(w.master.sendWireMaster(w.factory.address, 0, b.address, b.address, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<WireMaster>({ to: w.master.address, exitCode: Errors.AlreadyWired });
    expect(w.master.sendIndexBump(b.address, 0, 0, REWARD_UNIT, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<IndexBump>({ to: w.master.address, exitCode: Errors.NotFromVault });
    expect(w.master.sendExcludedUpdate(b.address, 0, 1, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<ExcludedUpdate>({ to: w.master.address, exitCode: Errors.NotFromPool });
}

// ---------------------------------------------------------------------------
// Dividend index
// ---------------------------------------------------------------------------

get fun `test reward: distribution is pro-rata, claims pay exactly once`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    mintCoin(w, a.address, 60 * COIN);
    mintCoin(w, b.address, 40 * COIN);

    val res = arriveReward(w, 0, 100 * REWARD_UNIT);
    val ev = findEvent<IndexBumpedEvent>(res, w.master.address, EVENT_TOPIC_INDEX_BUMPED);
    expect(ev).toBeNotNull();
    expect(ev!.circulating).toEqual(100 * COIN);
    expect(indexValue(w, 0)).toEqual((100 * REWARD_UNIT * INDEX_SCALE) / (100 * COIN));

    expect(claimable(w, a.address, 0)).toEqual(60 * REWARD_UNIT);
    expect(claimable(w, b.address, 0)).toEqual(40 * REWARD_UNIT);

    val c = claim(w, a.address);
    expect(c).toHaveSuccessfulTx<Settle>({ to: w.master.address });
    expect(c).toHaveSuccessfulTx<PayReward>({ from: w.master.address, to: w.vault.address });
    expect(c).toHaveSuccessfulTx<AskToTransfer>({ from: w.vault.address, to: w.reward0.getWalletAddress(w.vault.address) });
    expect(c).toHaveSuccessfulTx<SettleAck>({ from: w.master.address, to: coinWallet(w, a.address).address });
    expect(rewardBalance(w, 0, a.address)).toEqual(60 * REWARD_UNIT);
    expect(claimable(w, a.address, 0)).toEqual(0);
    val paidEv = findEvent<RewardPaidEvent>(c, w.vault.address, EVENT_TOPIC_REWARD_PAID);
    expect(paidEv!.amount).toEqual(60 * REWARD_UNIT);

    // second claim: nothing owed, no payout, wallet idle again
    val again = claim(w, a.address);
    expect(again).toHaveSuccessfulTx<SettleAck>({ to: coinWallet(w, a.address).address });
    expect(countEvents(again, w.vault.address, EVENT_TOPIC_REWARD_PAID)).toEqual(0);
    expect(rewardBalance(w, 0, a.address)).toEqual(60 * REWARD_UNIT);
    expect(coinWallet(w, a.address).getRewardWalletData().busy).toBeFalse();

    claim(w, b.address);
    expect(rewardBalance(w, 0, b.address)).toEqual(40 * REWARD_UNIT);
    expect(rewardBalance(w, 0, w.vault.address)).toEqual(0);
    val slot = w.vault.getVaultData().rewards.mustGet(0);
    expect(slot.paid).toEqual(100 * REWARD_UNIT);
}

get fun `test reward: transfers freeze the sender position and stamp the recipient`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val c = testing.treasury("c");
    mintCoin(w, a.address, 60 * COIN);
    mintCoin(w, b.address, 40 * COIN);
    arriveReward(w, 0, 100 * REWARD_UNIT);

    // a sends half of its coins to c: a keeps its 60 earned, c starts at the current index
    expect(transferCoin(w, a.address, c.address, 30 * COIN)).toHaveSuccessfulTx<RewardTransferStep>({ to: coinWallet(w, c.address).address });
    expect(amountOf(coinWallet(w, a.address).getRewardWalletData().accrued, 0)).toEqual(60 * REWARD_UNIT);
    expect(indexOf(coinWallet(w, c.address).getRewardWalletData().stamps, 0)).toEqual(indexValue(w, 0));
    expect(claimable(w, a.address, 0)).toEqual(60 * REWARD_UNIT);
    expect(claimable(w, c.address, 0)).toEqual(0);

    // second distribution: a 30, b 40, c 30
    arriveReward(w, 0, 100 * REWARD_UNIT);
    expect(claimable(w, a.address, 0)).toEqual(90 * REWARD_UNIT);
    expect(claimable(w, b.address, 0)).toEqual(80 * REWARD_UNIT);
    expect(claimable(w, c.address, 0)).toEqual(30 * REWARD_UNIT);

    // recipient receiving more while already holding: its own position is frozen first
    transferCoin(w, b.address, c.address, 40 * COIN);
    expect(amountOf(coinWallet(w, c.address).getRewardWalletData().accrued, 0)).toEqual(30 * REWARD_UNIT);
    arriveReward(w, 0, 100 * REWARD_UNIT);
    // a 30 -> +30, b 0 -> +0, c 70 -> +70
    expect(claimable(w, a.address, 0)).toEqual(120 * REWARD_UNIT);
    expect(claimable(w, b.address, 0)).toEqual(80 * REWARD_UNIT);
    expect(claimable(w, c.address, 0)).toEqual(100 * REWARD_UNIT);

    claim(w, a.address);
    claim(w, b.address);
    claim(w, c.address);
    expect(rewardBalance(w, 0, a.address)).toEqual(120 * REWARD_UNIT);
    expect(rewardBalance(w, 0, b.address)).toEqual(80 * REWARD_UNIT);
    expect(rewardBalance(w, 0, c.address)).toEqual(100 * REWARD_UNIT);
    expect(rewardBalance(w, 0, w.vault.address)).toEqual(0);
}

get fun `test reward: cycle of two rewards, independent indices, claim pays both`() {
    val w = setupRewardWorld(2);
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    mintCoin(w, a.address, 75 * COIN);
    mintCoin(w, b.address, 25 * COIN);

    arriveReward(w, 0, 40 * REWARD_UNIT);
    arriveReward(w, 1, 200 * REWARD_UNIT);
    expect(claimable(w, a.address, 0)).toEqual(30 * REWARD_UNIT);
    expect(claimable(w, a.address, 1)).toEqual(150 * REWARD_UNIT);

    // claim with too little value for two payouts fails atomically (nothing paid, wallet idle)
    val short = claim(w, a.address, ton("0.1"));
    expect(short).toHaveFailedTx<Settle>({ to: w.master.address, exitCode: Errors.InsufficientValue });
    expect(coinWallet(w, a.address).getRewardWalletData().busy).toBeFalse();
    expect(rewardBalance(w, 0, a.address)).toEqual(0);

    val ok = claim(w, a.address, ton("0.3"));
    expect(countEvents(ok, w.vault.address, EVENT_TOPIC_REWARD_PAID)).toEqual(2);
    expect(rewardBalance(w, 0, a.address)).toEqual(30 * REWARD_UNIT);
    expect(rewardBalance(w, 1, a.address)).toEqual(150 * REWARD_UNIT);
    claim(w, b.address);
    expect(rewardBalance(w, 0, b.address)).toEqual(10 * REWARD_UNIT);
    expect(rewardBalance(w, 1, b.address)).toEqual(50 * REWARD_UNIT);
}

get fun `test reward: nothing circulating — bump refused and carried to the next arrival`() {
    val w = setupRewardWorld();
    val res = arriveReward(w, 0, 10 * REWARD_UNIT);
    expect(res).toHaveSuccessfulTx<IndexBumpRefused>({ from: w.master.address, to: w.vault.address });
    expect(indexValue(w, 0)).toEqual(0);
    expect(w.vault.getVaultData().rewards.mustGet(0).carry).toEqual(10 * REWARD_UNIT);

    val a = testing.treasury("a");
    mintCoin(w, a.address, 10 * COIN);
    arriveReward(w, 0, 5 * REWARD_UNIT);
    expect(w.vault.getVaultData().rewards.mustGet(0).carry).toEqual(0);
    expect(claimable(w, a.address, 0)).toEqual(15 * REWARD_UNIT);
    claim(w, a.address);
    expect(rewardBalance(w, 0, a.address)).toEqual(15 * REWARD_UNIT);
}

get fun `test reward: pool coins are excluded from the index and cannot claim`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    val pool = testing.treasury("pool");
    mintCoin(w, a.address, 50 * COIN);

    expect(w.master.sendCurveGraduated(w.curve.address, 0, pool.address, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<CurveGraduated>({ to: w.master.address });
    expect(w.master.getJettonData().mintable).toBeFalse();
    mintCoin(w, pool.address, 50 * COIN);
    expect(w.master.sendExcludedUpdate(pool.address, 0, 50 * COIN, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<ExcludedUpdate>({ to: w.master.address });

    val res = arriveReward(w, 0, 100 * REWARD_UNIT);
    val ev = findEvent<IndexBumpedEvent>(res, w.master.address, EVENT_TOPIC_INDEX_BUMPED);
    expect(ev!.circulating).toEqual(50 * COIN);
    expect(claimable(w, a.address, 0)).toEqual(100 * REWARD_UNIT);

    // the pool wallet would compute a share but the master never pays it
    val poolClaim = claim(w, pool.address);
    expect(poolClaim).toHaveSuccessfulTx<SettleAck>({ to: coinWallet(w, pool.address).address });
    expect(countEvents(poolClaim, w.vault.address, EVENT_TOPIC_REWARD_PAID)).toEqual(0);
    claim(w, a.address);
    expect(rewardBalance(w, 0, a.address)).toEqual(100 * REWARD_UNIT);
}

// ---------------------------------------------------------------------------
// Burns and sells
// ---------------------------------------------------------------------------

get fun `test reward: plain burn reduces supply, sell burn notifies the curve, closed curve refuses`() {
    val w = setupRewardWorld();
    val a = testing.treasury("a");
    mintCoin(w, a.address, 100 * COIN);
    arriveReward(w, 0, 100 * REWARD_UNIT);

    val burn = coinWallet(w, a.address).sendBurn(a.address, ton("0.2"), 10 * COIN, null);
    expect(burn).toHaveSuccessfulTx<Settle>({ to: w.master.address });
    expect(burn).toHaveSuccessfulTx<SettleAck>({ to: coinWallet(w, a.address).address });
    expect(countEvents(burn, w.vault.address, EVENT_TOPIC_REWARD_PAID)).toEqual(0);
    expect(coinBalance(w, a.address)).toEqual(90 * COIN);
    expect(w.master.getJettonData().totalSupply).toEqual(90 * COIN);
    // burned coins had earned until now: still claimable
    expect(claimable(w, a.address, 0)).toEqual(100 * REWARD_UNIT);

    val sell = coinWallet(w, a.address).sendBurn(a.address, ton("0.2"), 40 * COIN, ton("1"));
    expect(sell).toHaveSuccessfulTx<SellNotify>({ from: w.master.address, to: w.curve.address });
    expect(coinBalance(w, a.address)).toEqual(50 * COIN);
    expect(w.master.getJettonData().totalSupply).toEqual(50 * COIN);

    // after graduation sells bounce: balance and supply untouched, wallet idle again
    val pool = testing.treasury("pool");
    w.master.sendCurveGraduated(w.curve.address, 0, pool.address, { value: ton("0.05"), bounce: true });
    val refused = coinWallet(w, a.address).sendBurn(a.address, ton("0.2"), 10 * COIN, ton("1"));
    expect(refused).toHaveFailedTx<Settle>({ to: w.master.address, exitCode: Errors.CurveClosed });
    expect(coinBalance(w, a.address)).toEqual(50 * COIN);
    expect(w.master.getJettonData().totalSupply).toEqual(50 * COIN);
    expect(coinWallet(w, a.address).getRewardWalletData().busy).toBeFalse();
    // plain burns still work after graduation
    expect(coinWallet(w, a.address).sendBurn(a.address, ton("0.2"), 10 * COIN, null)).toHaveSuccessfulTx<SettleAck>({ to: coinWallet(w, a.address).address });
    expect(coinBalance(w, a.address)).toEqual(40 * COIN);
}

// ---------------------------------------------------------------------------
// Vault: keeper conversion
// ---------------------------------------------------------------------------

/// Keeper ConvertReward through the whitelisted pool with enough value for the DEX gas chain.
fun convertReward(w: RewardWorld, from: address, rewardId: int, pool: address, spend: coins, minOut: coins, value: coins = ton("0.3")): SendResultList {
    return w.vault.sendConvertReward(from, 0, rewardId as uint8, pool, spend, minOut, { value, bounce: true });
}

get fun `test vault: keeper convert is bounded, settles on arrival, rotates the cycle`() {
    val w = setupRewardWorld(2);
    val a = testing.treasury("a");
    mintCoin(w, a.address, 100 * COIN);
    // holders' TON arrives from the splitter
    expect(w.vault.sendRewardIn(w.factory.address, 0, { value: ton("10"), bounce: false })).toHaveSuccessfulTx<RewardIn>({ to: w.vault.address });
    expect(w.vault.getVaultData().totalTonIn).toEqual(ton("10"));

    expect(convertReward(w, a.address, 0, w.pool.address, ton("5"), REWARD_UNIT))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.NotFromKeeper });
    expect(convertReward(w, w.keeper.address, 1, w.pool.address, ton("5"), REWARD_UNIT))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.NotRotationNext });
    // neither a stranger nor the vault itself is a whitelisted pool
    expect(convertReward(w, w.keeper.address, 0, a.address, ton("5"), REWARD_UNIT))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.DestNotWhitelisted });
    expect(convertReward(w, w.keeper.address, 0, w.dex.address, ton("5"), REWARD_UNIT))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.DestNotWhitelisted });
    // balance ~11 TON, reserve 0.5 -> 10.8 is too much
    expect(convertReward(w, w.keeper.address, 0, w.pool.address, ton("10.8"), REWARD_UNIT))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.BudgetExceeded });
    // a zero minimum would let the pool return dust
    expect(convertReward(w, w.keeper.address, 0, w.pool.address, ton("5"), 0))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.InvalidParams });
    // the keeper funds the DEX gas chain
    expect(convertReward(w, w.keeper.address, 0, w.pool.address, ton("5"), REWARD_UNIT, ton("0.1")))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.InsufficientValue });

    val ok = convertReward(w, w.keeper.address, 0, w.pool.address, ton("5"), REWARD_UNIT);
    // swap body built by the vault: our pool, our address as receiver, our limit
    val swapTx = ok.findTransaction<DedustNativeSwap>({ from: w.vault.address, to: w.dex.address });
    expect(swapTx).toBeNotNull();
    val swap = swapTx!.loadBody<DedustNativeSwap>();
    expect(swap.amount).toEqual(ton("5"));
    expect(swap.pool).toEqual(w.pool.address);
    expect(swap.limit).toEqual(REWARD_UNIT);
    expect(swap.params.load().recipient).toEqual(w.vault.address);
    expect(w.vault.getVaultData().pending).toBeNotNull();
    expect(w.vault.getVaultData().totalTonSpent).toEqual(ton("5"));
    expect(convertReward(w, w.keeper.address, 0, w.pool.address, ton("1"), REWARD_UNIT))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.OperationInFlight });

    val fill = arriveReward(w, 0, 3 * REWARD_UNIT);
    val ev = findEvent<RewardConvertedEvent>(fill, w.vault.address, EVENT_TOPIC_REWARD_CONVERTED);
    expect(ev).toBeNotNull();
    expect(ev!.spendTon).toEqual(ton("5"));
    expect(ev!.received).toEqual(3 * REWARD_UNIT);
    expect(w.vault.getVaultData().pending).toBeNull();
    expect(w.vault.getVaultData().cycleNext).toEqual(1);
    expect(claimable(w, a.address, 0)).toEqual(3 * REWARD_UNIT);

    // cycle wraps after the second reward
    convertReward(w, w.keeper.address, 1, w.pool.address, ton("2"), REWARD_UNIT);
    arriveReward(w, 1, REWARD_UNIT);
    expect(w.vault.getVaultData().cycleNext).toEqual(0);

    // timeout cancel
    convertReward(w, w.keeper.address, 0, w.pool.address, ton("1"), REWARD_UNIT);
    expect(w.vault.sendCancelVaultPending(w.keeper.address, 0, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<CancelVaultPending>({ to: w.vault.address, exitCode: Errors.PendingNotExpired });
    testing.setNow(WORLD_T0 + 601);
    expect(w.vault.sendCancelVaultPending(w.keeper.address, 0, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<CancelVaultPending>({ to: w.vault.address });
    expect(w.vault.getVaultData().pending).toBeNull();
}

get fun `test vault: bounced swap restores the TON accounting`() {
    val w = setupRewardWorld();
    w.vault.sendRewardIn(w.factory.address, 0, { value: ton("10"), bounce: false });
    // the DEX vault is fixed in storage; a vault deployed with an undeployed one sees its swap bounce
    val ghost = w.master.getWalletAddress(w.dex.address); // undeployed account -> bounce
    val roles = w.vault.getVaultData().roles;
    val broken = RewardVault.fromStorage({
        rewardCount: 1,
        cycleNext: 0,
        totalTonIn: 0,
        totalTonSpent: 0,
        reserve: ton("0.5"),
        pendingTimeout: 600,
        roles: RewardVaultRoles { admin: roles.admin, keeper: roles.keeper, master: roles.master }.toCell(),
        rewards: w.vault.getVaultData().rewards,
        dexVault: ghost,
        dexPools: poolsWith(w.pool.address),
        pending: null,
    });
    expect(broken.deploy(w.admin.address, { value: ton("11"), bounce: false })).toHaveSuccessfulDeploy({ to: broken.address });
    val res = broken.sendConvertReward(w.keeper.address, 0, 0, w.pool.address, ton("5"), REWARD_UNIT, { value: ton("0.3"), bounce: true });
    expect(res).toHaveTx({ from: broken.address, to: ghost });
    expect(broken.getVaultData().pending).toBeNull();
    expect(broken.getVaultData().totalTonSpent).toEqual(0);
    expect(testing.getAccountBalance(broken.address) > ton("10.5")).toBeTrue();

    // admin manages the pool whitelist; a de-listed pool is refused
    expect(w.vault.sendSetVaultDex(w.keeper.address, 0, w.pool.address, false, { value: ton("0.05"), bounce: true }))
        .toHaveFailedTx<SetVaultDex>({ to: w.vault.address, exitCode: Errors.NotFromAdmin });
    expect(w.vault.sendSetVaultDex(w.admin.address, 0, w.pool.address, false, { value: ton("0.05"), bounce: true })).toHaveSuccessfulTx<SetVaultDex>({ to: w.vault.address });
    expect(w.vault.sendConvertReward(w.keeper.address, 0, 0, w.pool.address, ton("5"), REWARD_UNIT, { value: ton("0.3"), bounce: true }))
        .toHaveFailedTx<ConvertReward>({ to: w.vault.address, exitCode: Errors.DestNotWhitelisted });
}

fun poolsWith(pool: address): map<address, bool> {
    var m: map<address, bool> = createEmptyMap();
    m.set(pool, true);
    return m;
}

get fun `test vault: dex payout of the full amount undoes the conversion`() {
    val w = setupRewardWorld();
    w.vault.sendRewardIn(w.factory.address, 0, { value: ton("10"), bounce: false });
    convertReward(w, w.keeper.address, 0, w.pool.address, ton("5"), REWARD_UNIT);
    expect(w.vault.getVaultData().pending).toBeNotNull();

    // strangers cannot speak payout; leftover gas from the vault changes nothing
    expect(net.send(w.issuer.address, createMessage({ bounce: true, value: ton("5.2"), dest: w.vault.address, body: DedustPayout { queryId: 0, payload: null } })))
        .toHaveFailedTx<DedustPayout>({ to: w.vault.address, exitCode: Errors.DestNotWhitelisted });
    expect(net.send(w.dex.address, createMessage({ bounce: true, value: ton("0.1"), dest: w.vault.address, body: DedustPayout { queryId: 0, payload: null } })))
        .toHaveSuccessfulTx<DedustPayout>({ to: w.vault.address });
    expect(w.vault.getVaultData().pending).toBeNotNull();

    // rejected swap: the amount comes back, the conversion is undone
    expect(net.send(w.dex.address, createMessage({ bounce: true, value: ton("5.1"), dest: w.vault.address, body: DedustPayout { queryId: 0, payload: null } })))
        .toHaveSuccessfulTx<DedustPayout>({ to: w.vault.address });
    expect(w.vault.getVaultData().pending).toBeNull();
    expect(w.vault.getVaultData().totalTonSpent).toEqual(0);
}

// ---------------------------------------------------------------------------
// Fuzz: total paid never exceeds total distributed; everyone can claim what get_claimable says
// ---------------------------------------------------------------------------

@test.fuzz(16)
get fun `test reward: fuzz — payouts are conservative and claims always succeed`(m1: int, m2: int, t1: int, d1: int, d2: int) {
    val a1 = fuzz.bound(m1, 1, 1000) * COIN;
    val a2 = fuzz.bound(m2, 1, 1000) * COIN;
    val tr = fuzz.bound(t1, 0, a1 / COIN) * COIN;
    val r1 = fuzz.bound(d1, 1, 5000 * REWARD_UNIT);
    val r2 = fuzz.bound(d2, 0, 5000 * REWARD_UNIT);

    val w = setupRewardWorld();
    val a = testing.treasury("a");
    val b = testing.treasury("b");
    val c = testing.treasury("c");
    mintCoin(w, a.address, a1);
    mintCoin(w, b.address, a2);
    arriveReward(w, 0, r1);
    if (tr > 0) {
        expect(transferCoin(w, a.address, c.address, tr)).toHaveSuccessfulTx<RewardTransferStep>({ to: coinWallet(w, c.address).address });
    }
    if (r2 > 0) {
        arriveReward(w, 0, r2);
    }

    val owedA = claimable(w, a.address, 0);
    val owedB = claimable(w, b.address, 0);
    val owedC = tr > 0 ? claimable(w, c.address, 0) : 0;
    expect(owedA + owedB + owedC <= r1 + r2).toBeTrue();
    // rounding loses at most one unit per (holder, distribution)
    expect(owedA + owedB + owedC + 6 >= r1 + r2).toBeTrue();

    claim(w, a.address);
    claim(w, b.address);
    if (tr > 0) {
        claim(w, c.address);
    }
    expect(rewardBalance(w, 0, a.address)).toEqual(owedA);
    expect(rewardBalance(w, 0, b.address)).toEqual(owedB);
    if (tr > 0) {
        expect(rewardBalance(w, 0, c.address)).toEqual(owedC);
    }
    expect(rewardBalance(w, 0, w.vault.address)).toEqual(r1 + r2 - owedA - owedB - owedC);
    expect(claimable(w, a.address, 0) + claimable(w, b.address, 0)).toEqual(0);
}
