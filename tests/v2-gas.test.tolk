// Launcher v2 gas budgets (docs/10 §7.1, phase C): every value constant that funds a downstream chain is
// checked against the fees the emulator charges on that chain, with headroom. Rule 6 of the v2 design is
// that the master never pays from its own balance, so these budgets are what keeps every path alive.
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"

import "@tests/fixtures"
import "@tests/v2-fixtures"
import "@wrappers/CurveV2.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/PoolV2.gen"
import "@wrappers/RewardMasterV2.gen"
import "@wrappers/RewardWalletV2.gen"
import "@wrappers/utils"
import "@contracts/common/consts"
import "@contracts/common/errors"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/launcher-v2/reward-types"
import "@contracts/vendor/jetton/messages"

const HEADROOM_PCT = 25

// Mirrors of contract-private constants: keep in sync with the source they name.
const ACK_MIN = ton("0.03") // RewardMasterV2 ACK_MIN
const SELL_NOTIFY_VALUE = ton("0.1") // RewardMasterV2 SELL_NOTIFY_VALUE
const WALLET_CLAIM_GAS = ton("0.05") // RewardWalletV2 WALLET_CLAIM_GAS
const WALLET_BURN_GAS = ton("0.16") // RewardWalletV2 WALLET_BURN_GAS
const WALLET_TRANSFER_GAS = ton("0.1") // RewardWalletV2 WALLET_TRANSFER_GAS
const PAYOUT_VALUE = ton("0.07") // RewardWalletV2 PAYOUT_VALUE
const CLAIM_KEEP = ton("0.02") // RewardWalletV2 CLAIM_KEEP
const POOL_OUT_VALUE = ton("0.1") // PoolV2 POOL_OUT_VALUE
const SWAP_GAS = ton("0.15") // PoolV2 SWAP_GAS
const MINT_VALUE = ton("0.06") // CurveV2 MINT_VALUE
const SPLIT_GAS = ton("0.03") // SPLIT_GAS_* (curve / pool)
const POOL_CREDIT_VALUE = ton("0.01") // PoolV2 POOL_CREDIT_VALUE

fun feesOf(tx: TlbTransaction?): coins {
    expect(tx).toBeNotNull();
    return tx!.totalFees.grams;
}

fun expectBudgetCovers(budget: coins, fees: coins, label: string) {
    println("gas v2 {}: fees {} nanoTON, budget {} nanoTON", label, fees, budget);
    expect(fees > 0).toBeTrue();
    expect(fees * (100 + HEADROOM_PCT) / 100).toBeLessOrEqual(budget);
}

get fun `test gas v2: claim at MAX_REWARDS — the ack fits ACK_MIN, the master's compute fits the claim gas`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    buyOk(w, a.address, ton("6"));
    var id = 0;
    while (id < MAX_REWARDS) {
        bump(w, id, (100 + id) * REWARD_UNIT);
        id += 1;
    }
    val wa = wallet(w, a.address);
    val res = claim(w, a.address, WALLET_CLAIM_GAS + MAX_REWARDS * PAYOUT_VALUE);
    val settle = res.findTransaction<Settle>({ from: wa.address, to: w.master.address });
    val ack = res.findTransaction<SettleAck>({ from: w.master.address, to: wa.address });
    // the master's own compute is paid by what the wallet forwarded, leaving at least ACK_MIN
    expectBudgetCovers(WALLET_CLAIM_GAS - ACK_MIN, feesOf(settle), "master.Settle(claim)");
    // the wallet's ack handler at 5 rewards + its excess message live on CLAIM_KEEP (ACK_MIN is the floor the master enforces)
    expectBudgetCovers(CLAIM_KEEP, feesOf(ack), "wallet.SettleAck(5 payouts)");
    // every reward was paid (accrued is cleared only when a request left)
    id = 0;
    while (id < MAX_REWARDS) {
        expect(claimable(w, a.address, id)).toEqual(0);
        id += 1;
    }
    expect(isBusy(w, a.address)).toBeFalse();
}

get fun `test gas v2: sell on the curve and on the pool — SELL_NOTIFY_VALUE covers the market, WALLET_BURN_GAS the whole chain`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    buyOk(w, a.address, ton("10"));
    val wa = wallet(w, a.address);

    val onCurve = sell(w, a.address, 10 * COIN, 0, WALLET_BURN_GAS);
    expect(onCurve).toHaveSuccessfulTx<SettleAck>({ to: wa.address });
    val settle = onCurve.findTransaction<Settle>({ from: wa.address, to: w.master.address });
    val notify = onCurve.findTransaction<SellNotify>({
        from: w.master.address,
        to: w.curve.address,
    });
    val burnTx = onCurve.findTransaction<AskToBurn>({ to: wa.address });
    // wallet compute + master compute + SellNotify + ack floor must fit the burn gas
    expectBudgetCovers(
        WALLET_BURN_GAS - SELL_NOTIFY_VALUE - ACK_MIN,
        feesOf(burnTx) + feesOf(settle),
        "wallet+master (burn)",
    );
    // the curve pays its compute, the FeeIn gas and the payout message out of SELL_NOTIFY_VALUE
    expectBudgetCovers(SELL_NOTIFY_VALUE - SPLIT_GAS, feesOf(notify), "curve.SellNotify");

    val whale = testing.treasury("v2-whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val onPool = sell(w, a.address, 10 * COIN, 0, WALLET_BURN_GAS);
    expect(onPool).toHaveSuccessfulTx<PoolCredit>({ from: pool.address, to: w.master.address });
    val poolNotify = onPool.findTransaction<SellNotify>({
        from: w.master.address,
        to: pool.address,
    });
    expectBudgetCovers(
        SELL_NOTIFY_VALUE - SPLIT_GAS - POOL_CREDIT_VALUE,
        feesOf(poolNotify),
        "pool.SellNotify",
    );
    expect(isBusy(w, a.address)).toBeFalse();
}

get fun `test gas v2: pool buy — POOL_OUT_VALUE covers the master, the wallet deploy and the notification`() {
    val w = setupV2();
    val whale = testing.treasury("v2-whale");
    graduate(w, whale.address);
    val pool = poolOf(w);
    val buyer = testing.treasury("v2-buyer");
    val res = poolBuy(w, buyer.address, ton("1"));
    val out = res.findTransaction<PoolOut>({ from: pool.address, to: w.master.address });
    val deliver = res.findTransaction<PoolDeliver>({
        from: w.master.address,
        to: w.master.getWalletAddress(buyer.address),
    });
    expectBudgetCovers(
        POOL_OUT_VALUE,
        feesOf(out) + feesOf(deliver),
        "master.PoolOut + wallet.PoolDeliver(deploy)",
    );
    val swap = res.findTransaction<SwapTonForCoin>({ to: pool.address });
    expectBudgetCovers(SWAP_GAS - POOL_OUT_VALUE - SPLIT_GAS, feesOf(swap), "pool.SwapTonForCoin");
    expect(balanceOf(w, buyer.address) > 0).toBeTrue();
}

get fun `test gas v2: curve buy and transfer — MINT_VALUE and WALLET_TRANSFER_GAS cover deploys`() {
    val w = setupV2();
    val a = testing.treasury("v2-a");
    val b = testing.treasury("v2-b");
    val res = buyOk(w, a.address, ton("2"));
    val mint = res.findTransaction<MintReward>({ from: w.curve.address, to: w.master.address });
    val step = res.findTransaction<RewardTransferStep>({
        from: w.master.address,
        to: w.master.getWalletAddress(a.address),
    });
    expectBudgetCovers(
        MINT_VALUE,
        feesOf(mint) + feesOf(step),
        "master.MintReward + wallet deploy",
    );

    val tr = transfer(w, a.address, b.address, 1 * COIN, WALLET_TRANSFER_GAS);
    expect(tr).toHaveSuccessfulTx<RewardTransferStep>({ to: w.master.getWalletAddress(b.address) });
    val ask = tr.findTransaction<AskToTransfer>({ to: w.master.getWalletAddress(a.address) });
    val settle = tr.findTransaction<Settle>({ to: w.master.address });
    val ack = tr.findTransaction<SettleAck>({ to: w.master.getWalletAddress(a.address) });
    val recv = tr.findTransaction<RewardTransferStep>({ to: w.master.getWalletAddress(b.address) });
    expectBudgetCovers(
        WALLET_TRANSFER_GAS,
        feesOf(ask) + feesOf(settle) + feesOf(ack) + feesOf(recv),
        "transfer chain (recipient deploy)",
    );
    expect(balanceOf(w, b.address)).toEqual(1 * COIN);
}
