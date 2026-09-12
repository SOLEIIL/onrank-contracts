// Gas budgets (security review F-14). Every value constant that funds a downstream chain is checked against the
// fees the emulator actually charges on that chain, with headroom, so a change that makes a path more expensive
// (or a constant that is silently lowered) fails here instead of freezing a wallet on mainnet (F-04/F-07/F-08).
//
// Method: `totalFees` of a transaction = storage + compute + action (forward) fees the network kept. A budget is
// sound when it covers the fees of every transaction it has to pay for, plus `HEADROOM_PCT` for config drift.
import "@acton/build"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/message"
import "@acton/types/transaction"

import "@contracts/common/consts"
import "@contracts/common/dedust"
import "@contracts/desk/desk-messages"
import "@contracts/launcher/reward-messages"
import "@contracts/pot/pot-messages"
import "@contracts/vendor/jetton/messages"
import "@wrappers/DeskItem.gen"
import "@wrappers/JettonMinter.gen"
import "@wrappers/JettonWallet.gen"
import "@wrappers/Pot.gen"
import "@wrappers/RewardMaster.gen"
import "@wrappers/RewardVault.gen"
import "@wrappers/RewardWallet.gen"
import "@wrappers/utils"
import "@tests/fixtures"
import "@tests/reward-fixtures"

/// Mainnet gas price can move (config param 21) and our own code grows: a budget must cover fees × 1.25.
const HEADROOM_PCT = 25

// Mirrors of contract-private constants (not exported): keep in sync with the source they name.
const POT_ROUND_KEEPER_GAS = ton("0.02")      // Pot.tolk ROUND_KEEPER_GAS
const POT_CONVERT_KEEPER_GAS = ton("0.02")    // Pot.tolk CONVERT_KEEPER_GAS
const VAULT_CONVERT_KEEPER_GAS = ton("0.02")  // RewardVault.tolk CONVERT_KEEPER_GAS
const MASTER_ACK_VALUE = ton("0.02")          // RewardMaster.tolk ACK_VALUE
const MASTER_PAYOUT_VALUE = ton("0.07")       // RewardMaster.tolk PAYOUT_VALUE

fun feesOf(tx: TlbTransaction?): coins {
    expect(tx).toBeNotNull();
    return tx!.totalFees.grams;
}

/// Fees charged on every transaction of the trace except the first one (the message the user / keeper paid for).
fun downstreamFees(res: SendResultList): coins {
    var total = 0;
    var i = 1;
    while (i < res.size()) {
        total += res.get(i).tx.load().totalFees.grams;
        i += 1;
    }
    return total;
}

fun expectBudgetCovers(budget: coins, fees: coins, label: string) {
    println("gas {}: fees {} nanoTON, budget {} nanoTON", label, fees, budget);
    expect(fees > 0).toBeTrue();
    expect(fees * (100 + HEADROOM_PCT) / 100).toBeLessOrEqual(budget);
}

// ---------------------------------------------------------------------------
// Keeper paths (Pot / RewardVault): the keeper's gas constant must cover the contract's own compute
// ---------------------------------------------------------------------------

get fun `test gas: Pot Convert compute fits CONVERT_KEEPER_GAS and the swap carries DEDUST_SWAP_GAS`() {
    val w = setupWorld();
    net.send(w.issuer.address, createMessage({ bounce: false, value: ton("10"), dest: w.pot.address, body: createEmptyCell() }));

    val res = w.pot.sendConvert(w.keeper.address, 1, w.pool.address, ton("5"), floorUsdtFor(ton("5")), { value: DEDUST_SWAP_GAS + POT_CONVERT_KEEPER_GAS, bounce: true });
    val tx = res.findTransaction<Convert>({ from: w.keeper.address, to: w.pot.address });
    expectBudgetCovers(POT_CONVERT_KEEPER_GAS, feesOf(tx), "Pot.Convert");

    // the vault receives spend + the whole DEX gas chain, whatever the Pot's compute cost
    val swap = res.findTransaction<DedustNativeSwap>({ from: w.pot.address, to: w.dex.address });
    expect(swap).toBeNotNull();
    val info = swap!.loadInMsg<DedustNativeSwap>().info;
    expect(info is TlbInternalMessage).toBeTrue();
    if (info is TlbInternalMessage) {
        expect(info.value.grams).toBeGreaterOrEqual(ton("5") + DEDUST_SWAP_GAS);
    }
}

get fun `test gas: Pot Round compute fits ROUND_KEEPER_GAS and forwardTon funds the usdt transfer chain`() {
    val w = setupWorld();
    mintDesk(w, testing.treasury("a").address);
    arriveUsdt(w, 1000 * USDT_UNIT);

    val forwardTon = ton("0.1");
    val payload = escrowPayloadFor(w.pot.address, floorStockFor(400 * USDT_UNIT));
    val res = w.pot.sendRound(w.keeper.address, 2, 0, 400 * USDT_UNIT, floorStockFor(400 * USDT_UNIT), forwardTon, true, payload, { value: POT_ROUND_KEEPER_GAS + forwardTon + ton("0.05"), bounce: true });
    val tx = res.findTransaction<Round>({ from: w.keeper.address, to: w.pot.address });
    expectBudgetCovers(POT_ROUND_KEEPER_GAS, feesOf(tx), "Pot.Round");
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.escrow.address });
    // transfer + internal transfer + escrow notification are all paid out of what the keeper attached
    expectBudgetCovers(forwardTon + ton("0.05"), downstreamFees(res) - feesOf(tx), "Pot.Round usdt chain");
}

get fun `test gas: RewardVault ConvertReward compute fits CONVERT_KEEPER_GAS`() {
    val w = setupRewardWorld(1);
    mintCoin(w, testing.treasury("a").address, 100 * COIN);
    w.vault.sendRewardIn(w.factory.address, 0, { value: ton("10"), bounce: false });

    val res = w.vault.sendConvertReward(w.keeper.address, 0, 0, w.pool.address, ton("5"), REWARD_UNIT, { value: DEDUST_SWAP_GAS + VAULT_CONVERT_KEEPER_GAS, bounce: true });
    val tx = res.findTransaction<ConvertReward>({ from: w.keeper.address, to: w.vault.address });
    expectBudgetCovers(VAULT_CONVERT_KEEPER_GAS, feesOf(tx), "RewardVault.ConvertReward");
    expect(res).toHaveSuccessfulTx<DedustNativeSwap>({ from: w.vault.address, to: w.dex.address });
}

// ---------------------------------------------------------------------------
// Desk sweep (F-04): SWEEP_REQUEST_VALUE pays Pot compute + jetton transfer (with the desk wallet deploy) + ack
// ---------------------------------------------------------------------------

get fun `test gas: SWEEP_REQUEST_VALUE covers the whole sweep chain including the desk wallet deploy`() {
    val w = setupWorld();
    val a = testing.treasury("a");
    val desk = mintDesk(w, a.address);
    arriveStock(w, 0, 300 * STOCK_UNIT);

    // first sweep: the desk's stock wallet does not exist yet (most expensive path)
    val first = sweep(w, desk, a.address, 0b01);
    expect(first).toHaveSuccessfulTx<SweepRequest>({ from: desk.address, to: w.pot.address });
    expect(first).toHaveSuccessfulTx<InternalTransferStep>({ to: deskStockWallet(w, 0, desk).address });
    expect(first).toHaveSuccessfulTx<SweepAck>({ from: w.pot.address, to: desk.address });
    expect(deskStockWallet(w, 0, desk).getJettonBalance()).toEqual(300 * STOCK_UNIT);
    expectBudgetCovers(SWEEP_REQUEST_VALUE, downstreamFees(first), "DeskItem.Sweep (1 slot, wallet deploy)");

    // the jetton transfer itself (wallet deploy included) must fit the value the Pot attaches to it
    val transfer = first.findTransaction<AskToTransfer>({ from: w.pot.address, to: potStockWallet(w, 0).address });
    val step = first.findTransaction<InternalTransferStep>({ to: deskStockWallet(w, 0, desk).address });
    expectBudgetCovers(POT_JETTON_TRANSFER_VALUE, feesOf(transfer) + feesOf(step), "Pot jetton transfer to desk");
}

// ---------------------------------------------------------------------------
// Reward claim (F-07 / F-08): ACK_VALUE funds SettleAck on the wallet, PAYOUT_VALUE funds vault + jetton transfer
// ---------------------------------------------------------------------------

get fun `test gas: claim — ACK_VALUE covers SettleAck and PAYOUT_VALUE covers the payout transfer chain`() {
    val w = setupRewardWorld(2);
    val a = testing.treasury("a");
    mintCoin(w, a.address, 100 * COIN);
    arriveReward(w, 0, 100 * REWARD_UNIT);
    arriveReward(w, 1, 50 * REWARD_UNIT);

    // first claim for both rewards: the holder's reward wallets are deployed on the way (most expensive path)
    val res = claim(w, a.address);
    val wallet = coinWallet(w, a.address);
    val ack = res.findTransaction<SettleAck>({ from: w.master.address, to: wallet.address });
    expectBudgetCovers(MASTER_ACK_VALUE, feesOf(ack), "RewardMaster.SettleAck");
    expect(wallet.getRewardWalletData().busy).toBeFalse();

    val pay = res.findTransaction<PayReward>({ from: w.master.address, to: w.vault.address });
    val transfer = res.findTransaction<AskToTransfer>({ from: w.vault.address, to: w.reward0.getWalletAddress(w.vault.address) });
    val step = res.findTransaction<InternalTransferStep>({ to: w.reward0.getWalletAddress(a.address) });
    expectBudgetCovers(MASTER_PAYOUT_VALUE, feesOf(pay) + feesOf(transfer) + feesOf(step), "RewardMaster.PayReward chain");
    expect(rewardBalance(w, 0, a.address)).toEqual(100 * REWARD_UNIT);
    expect(rewardBalance(w, 1, a.address)).toEqual(50 * REWARD_UNIT);
}
