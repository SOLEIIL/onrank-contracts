// Async ordering fuzz: three message chains (transfer a->b, reward arrival, claim) are executed
// step by step in a random interleaving. Whatever the order, no double payment, no stuck pending,
// supply conserved, and the vault never promises more than it received.
import "@stdlib/strings"
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"

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

fun transferMsg(w: RewardWorld, from: address, to: address, amount: int): OutMessage {
    return createMessage({
        bounce: true,
        value: ton("0.2"),
        dest: coinWallet(w, from).address,
        body: AskToTransfer {
            queryId: 1,
            jettonAmount: amount,
            transferRecipient: to,
            sendExcessesTo: from,
            customPayload: null,
            forwardTonAmount: 0,
            forwardPayload: emptyForwardPayload(),
        },
    });
}

fun rewardMsg(w: RewardWorld, amount: int): OutMessage {
    return createMessage({
        bounce: false,
        value: ton("0.315"),
        dest: w.reward0.address,
        body: MintNewJettons {
            queryId: 2,
            mintRecipient: w.vault.address,
            tonAmount: ton("0.3"),
            internalTransferMsg: InternalTransferStep {
                queryId: 2,
                jettonAmount: amount,
                transferInitiator: null,
                sendExcessesTo: w.reward0.address,
                forwardTonAmount: ton("0.05"),
                forwardPayload: beginCell().storeMaybeRef(null).endCell().beginParse(),
            }.toCell(),
        },
    });
}

fun claimMsg(w: RewardWorld, owner: address): OutMessage {
    return createMessage({
        bounce: true,
        value: ton("0.3"),
        dest: coinWallet(w, owner).address,
        body: ClaimRewards { queryId: 3 },
    });
}

fun pendingOf(w: RewardWorld, owner: address): bool {
    return coinWallet(w, owner).getRewardWalletData().busy;
}

get fun `test reward: index bump while a transfer is in flight — the lot in flight still earns (regression)`() {
    val w = setupRewardWorld();
    val a = testing.treasury("il-a");
    val b = testing.treasury("il-b");
    mintCoin(w, a.address, 600 * COIN);
    mintCoin(w, b.address, 400 * COIN);
    arriveReward(w, 0, 100 * REWARD_UNIT);

    // a's wallet settles and emits the transfer step, which we hold back...
    val c1 = testing.createTraceIterationCursor(a.address, transferMsg(w, a.address, b.address, 276 * COIN));
    c1.executeTill<SettleAck>({ to: coinWallet(w, a.address).address });
    expect(coinBalance(w, a.address)).toEqual(324 * COIN);
    expect(coinBalance(w, b.address)).toEqual(400 * COIN);
    // ...while a reward lands: 276 COIN are in flight, counted in circulating but held by nobody
    arriveReward(w, 0, 222 * REWARD_UNIT);
    // b even claims in between (its stamp moves ahead of the snapshot carried by the step)
    claim(w, b.address);
    expect(rewardBalance(w, 0, b.address)).toEqual(400 * 322 * REWARD_UNIT / 1000);
    c1.executeAllRemaining();

    // the lot's share of the second reward is credited to the recipient, nothing stranded
    expect(coinBalance(w, b.address)).toEqual(676 * COIN);
    expect(claimable(w, b.address, 0)).toEqual(276 * 222 * REWARD_UNIT / 1000);
    expect(claimable(w, a.address, 0)).toEqual(600 * 100 * REWARD_UNIT / 1000 + 324 * 222 * REWARD_UNIT / 1000);
    claim(w, a.address);
    claim(w, b.address);
    expect(rewardBalance(w, 0, w.vault.address)).toEqual(0);
    expect(w.vault.getVaultData().rewards.mustGet(0).paid).toEqual(322 * REWARD_UNIT);
}

@test.fuzz(30)
get fun `test reward: fuzz — transfer, reward arrival and claim interleaved in any order`(seed: int, pct: int, r1: int) {
    val w = setupRewardWorld();
    val a = testing.treasury("il-a");
    val b = testing.treasury("il-b");
    mintCoin(w, a.address, 600 * COIN);
    mintCoin(w, b.address, 400 * COIN);
    // a first reward so both have something claimable before the race
    arriveReward(w, 0, 100 * REWARD_UNIT);

    val amount = (600 * COIN * fuzz.bound(pct, 1, 100)) / 100;
    val reward = fuzz.bound(r1, 1, 500) * REWARD_UNIT;
    val c1 = testing.createTraceIterationCursor(a.address, transferMsg(w, a.address, b.address, amount));
    val c2 = testing.createTraceIterationCursor(w.issuer.address, rewardMsg(w, reward));
    val c3 = testing.createTraceIterationCursor(b.address, claimMsg(w, b.address));

    var bits = seed;
    var guard = 0;
    while (!(c1.isDone() && c2.isDone() && c3.isDone()) && guard < 200) {
        val pick = bits & 3;
        val n = 1 + ((bits >> 2) & 1);
        bits = bits >> 3;
        if (bits == 0) {
            bits = seed ^ guard;
        }
        if (pick == 0 && !c1.isDone()) {
            c1.executeN(n);
        } else if (pick == 1 && !c2.isDone()) {
            c2.executeN(n);
        } else if (pick == 2 && !c3.isDone()) {
            c3.executeN(n);
        } else {
            // pick something still running
            if (!c1.isDone()) { c1.executeN(n); } else if (!c2.isDone()) { c2.executeN(n); } else { c3.executeN(n); }
        }
        guard += 1;
    }
    expect(c1.isDone() && c2.isDone() && c3.isDone()).toBeTrue();

    // no stuck pending, supply conserved
    expect(pendingOf(w, a.address)).toBeFalse();
    expect(pendingOf(w, b.address)).toBeFalse();
    val balA = coinBalance(w, a.address);
    val balB = coinBalance(w, b.address);
    expect(balA + balB).toEqual(1000 * COIN);
    // the transfer either went through entirely or not at all
    expect(balA == 600 * COIN - amount || balA == 600 * COIN).toBeTrue();

    // whatever landed: total arrived is what the vault holds + paid; nobody can claim more than that
    val arrived = 100 * REWARD_UNIT + reward;
    val vd = w.vault.getVaultData();
    val paidBefore = vd.rewards.mustGet(0).paid;
    expect(paidBefore <= arrived).toBeTrue();
    val promised = claimable(w, a.address, 0) + claimable(w, b.address, 0);
    expect(promised + paidBefore <= arrived).toBeTrue();

    // everyone claims: all paid out (minus rounding dust), nothing claimable left, claims never fail
    expect(claim(w, a.address)).toHaveSuccessfulTx<ClaimRewards>({ to: coinWallet(w, a.address).address });
    expect(claim(w, b.address)).toHaveSuccessfulTx<ClaimRewards>({ to: coinWallet(w, b.address).address });
    val paidAfter = w.vault.getVaultData().rewards.mustGet(0).paid;
    expect(paidAfter <= arrived).toBeTrue();
    if (paidAfter < arrived - 4) {
        var sb = StringBuilder.create();
        sb.append("paidAfter=").appendInt(paidAfter).append(" arrived=").appendInt(arrived).append(" paidBefore=").appendInt(paidBefore)
          .append(" promised=").appendInt(promised).append(" balA=").appendInt(balA).append(" amount=").appendInt(amount)
          .append(" carry=").appendInt(w.vault.getVaultData().rewards.mustGet(0).carry)
          .append(" vaultBal=").appendInt(rewardBalance(w, 0, w.vault.address))
          .append(" index=").appendInt(indexValue(w, 0));
        expect(sb.build()).toEqual("");
    }
    expect(claimable(w, a.address, 0)).toEqual(0);
    expect(claimable(w, b.address, 0)).toEqual(0);
    expect(rewardBalance(w, 0, a.address) + rewardBalance(w, 0, b.address)).toEqual(paidAfter);
}
