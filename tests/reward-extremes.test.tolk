// Extreme amounts on the dividend index: dust rewards on a huge supply, huge rewards on a dust
// supply. Rounding never loses units (remainder carried), overflow is refused and kept as carry.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
import "@contracts/common/errors"
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

const E18 = 1000000000000000000

get fun `test reward extremes: dust rewards on a 1e18 supply are carried, then paid once they add up`() {
    val w = setupRewardWorld();
    val a = testing.treasury("x-a");
    mintCoin(w, a.address, 1000000000 * COIN); // 1e18 units circulating: index step = 1e6 units
    // 1e6 - 1 units: index does not move, nothing is lost
    arriveReward(w, 0, 999999);
    expect(indexValue(w, 0)).toEqual(0);
    expect(claimable(w, a.address, 0)).toEqual(0);
    // 1 more unit: the carried remainder tips the index by exactly one step
    arriveReward(w, 0, 1);
    expect(indexValue(w, 0)).toEqual(1);
    expect(claimable(w, a.address, 0)).toEqual(1000000);
    claim(w, a.address);
    expect(rewardBalance(w, 0, a.address)).toEqual(1000000);
    expect(claimable(w, a.address, 0)).toEqual(0);
    expect(rewardBalance(w, 0, w.vault.address)).toEqual(0);
}

get fun `test reward extremes: many dusty bumps lose nothing (sum of payouts == sum of arrivals)`() {
    val w = setupRewardWorld();
    val a = testing.treasury("x-a");
    val b = testing.treasury("x-b");
    mintCoin(w, a.address, 700000000 * COIN);
    mintCoin(w, b.address, 300000000 * COIN);
    var i = 0;
    var total = 0;
    while (i < 12) {
        val amt = 1234567 + i * 777777;
        arriveReward(w, 0, amt);
        total += amt;
        i += 1;
    }
    // without remainder carry each bump would drop up to 1e6 units: 12 bumps -> up to 12e6 lost
    val promised = claimable(w, a.address, 0) + claimable(w, b.address, 0);
    expect(promised <= total).toBeTrue();
    expect(promised >= total - 1000000 - 2).toBeTrue(); // only the current remainder (< one step) is still pending
    val remainder = w.master.getRewardMasterData().remainders.get(0);
    val rem: int = remainder.isFound ? (remainder.loadValue() as int) : 0;
    expect(rem < E18).toBeTrue();
    expect(promised + rem / (1000000000000)).toBeApproxEqAbs(total, 2);
}

get fun `test reward extremes: huge reward on a 1 nano supply overflows uint128 -> refused, carried, nothing claimable`() {
    val w = setupRewardWorld();
    val a = testing.treasury("x-a");
    mintCoin(w, a.address, 1);
    val huge = 1 << 100; // * 1e12 / 1 = 1.3e42 > 2^128
    val res = w.reward0.sendMint(w.issuer.address, w.vault.address, huge, ton("0.05"), ton("0.3"));
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.vault.address });
    expect(res).toHaveFailedTx<IndexBump>({ from: w.vault.address, to: w.master.address, exitCode: Errors.IndexOverflow });
    expect(indexValue(w, 0)).toEqual(0);
    expect(claimable(w, a.address, 0)).toEqual(0);
    expect(rewardBalance(w, 0, w.vault.address)).toEqual(huge);
    expect(w.vault.getVaultData().rewards.mustGet(0).carry).toEqual(huge);
    // a sane reward on a sane supply still works afterwards
    mintCoin(w, a.address, 1000 * COIN);
    arriveReward(w, 0, 10 * REWARD_UNIT);
    expect(claimable(w, a.address, 0) > 0).toBeTrue();
}

get fun `test reward extremes: 2^120 supply with 1 unit -> whole unit carried as remainder`() {
    val w = setupRewardWorld();
    val a = testing.treasury("x-a");
    mintCoin(w, a.address, (1 << 120) - 1);
    arriveReward(w, 0, 1);
    expect(indexValue(w, 0)).toEqual(0);
    expect(claimable(w, a.address, 0)).toEqual(0);
    expect(w.master.getRewardMasterData().remainders.mustGet(0)).toEqual(1000000000000);
}

get fun `test reward extremes: 1 nano supply with 1e18 units -> paid in full`() {
    val w2 = setupRewardWorld();
    val b = testing.treasury("x-b");
    mintCoin(w2, b.address, 1);
    arriveReward(w2, 0, E18);
    expect(indexValue(w2, 0)).toEqual(E18 * 1000000000000);
    expect(claimable(w2, b.address, 0)).toEqual(E18);
    claim(w2, b.address);
    expect(rewardBalance(w2, 0, b.address)).toEqual(E18);
}
