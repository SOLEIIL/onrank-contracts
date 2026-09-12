// Shared world for the reward-bearing jetton tests: RewardMaster + RewardVault wired by a
// "factory" treasury, a "curve" treasury that mints, and one or two standard jettons as rewards.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/common/consts"
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

struct RewardWorld {
    factory: Treasury
    curve: Treasury
    keeper: Treasury
    admin: Treasury
    issuer: Treasury
    dex: Treasury
    pool: Treasury
    reward0: JettonMinter
    reward1: JettonMinter
    master: RewardMaster
    vault: RewardVault
}

const REWARD_UNIT = 100000000 // 8 decimals (xStock-like)
const COIN = 1000000000 // 9 decimals

fun setupRewardWorld(rewardCount: int = 1): RewardWorld {
    testing.setNow(WORLD_T0);
    val factory = testing.treasury("r-factory");
    val curve = testing.treasury("r-curve");
    val keeper = testing.treasury("r-keeper");
    val admin = testing.treasury("r-admin");
    val issuer = testing.treasury("r-issuer");
    val dex = testing.treasury("r-dex");
    val pool = testing.treasury("r-pool");

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

    expect(master.sendWireMaster(factory.address, 0, curve.address, vault.address, { value: ton("0.05"), bounce: true }))
        .toHaveSuccessfulTx<WireMaster>({ to: master.address });

    addReward(vault, admin.address, 0, reward0);
    if (rewardCount > 1) {
        addReward(vault, admin.address, 1, reward1);
    }

    return { factory, curve, keeper, admin, issuer, dex, pool, reward0, reward1, master, vault };
}

/// Admin adds a reward; the vault discovers its wallet through TEP-89 in the same trace.
fun addReward(vault: RewardVault, admin: address, id: int, jetton: JettonMinter) {
    val res = vault.sendAddReward(admin, 0, id as uint8, jetton.address, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx<AddReward>({ to: vault.address });
    expect(res).toHaveSuccessfulTx<RequestWalletAddress>({ from: vault.address, to: jetton.address });
    expect(res).toHaveSuccessfulTx<ResponseWalletAddress>({ from: jetton.address, to: vault.address });
    expect(vault.getVaultData().rewards.mustGet(id as uint8).vaultWallet!).toEqual(jetton.getWalletAddress(vault.address));
}

fun coinWallet(w: RewardWorld, owner: address): RewardWallet {
    return RewardWallet.fromAddress(w.master.getWalletAddress(owner));
}

fun coinBalance(w: RewardWorld, owner: address): int {
    return coinWallet(w, owner).getRewardWalletData().balance;
}

/// The curve mints `amount` coin to `to`.
fun mintCoin(w: RewardWorld, to: address, amount: int): SendResultList {
    val res = w.master.sendMintReward(w.curve.address, 1, to, amount, 0, null, { value: ton("0.1"), bounce: true });
    expect(res).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.master.address });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({ from: w.master.address, to: w.master.getWalletAddress(to) });
    return res;
}

fun rewardOf(w: RewardWorld, id: int): JettonMinter {
    return id == 0 ? w.reward0 : w.reward1;
}

/// Reward `id` lands in the vault's jetton wallet (DEX fill or donation) and bumps the index.
fun arriveReward(w: RewardWorld, id: int, amount: int): SendResultList {
    val res = rewardOf(w, id).sendMint(w.issuer.address, w.vault.address, amount, ton("0.05"), ton("0.3"));
    expect(res).toHaveSuccessfulTx<TransferNotificationForRecipient>({ to: w.vault.address });
    expect(res).toHaveSuccessfulTx<IndexBump>({ from: w.vault.address, to: w.master.address });
    return res;
}

fun rewardBalance(w: RewardWorld, id: int, owner: address): int {
    return rewardOf(w, id).walletOf(owner).getJettonBalance();
}

fun indexValue(w: RewardWorld, id: int): int {
    return indexOf(w.master.getRewardMasterData().indices, id as uint8);
}

fun claimable(w: RewardWorld, owner: address, id: int): int {
    val m = coinWallet(w, owner).getClaimable(w.master.getRewardMasterData().indices);
    return amountOf(m, id as uint8);
}

fun claim(w: RewardWorld, owner: address, value: coins = ton("0.3")): SendResultList {
    return coinWallet(w, owner).sendClaimRewards(owner, 5, { value, bounce: true });
}

fun transferCoin(w: RewardWorld, from: address, to: address, amount: int, value: coins = ton("0.2")): SendResultList {
    return coinWallet(w, from).sendTransfer(from, value, amount, to, from, null, 0, null);
}

/// TEP-74 transfer on a RewardWallet (same body as a standard jetton wallet).
fun RewardWallet.sendTransfer(
    self,
    from: address,
    value: int,
    jettonAmount: int,
    recipient: address,
    responseAddress: address,
    customPayload: cell?,
    forwardTonAmount: int,
    forwardPayload: cell?,
): SendResultList {
    val outMessage = createMessage({
        bounce: true,
        value,
        dest: self.address,
        body: AskToTransfer {
            queryId: 0,
            jettonAmount,
            transferRecipient: recipient,
            sendExcessesTo: responseAddress,
            customPayload,
            forwardTonAmount,
            forwardPayload: beginCell().storeMaybeRef(forwardPayload).endCell().beginParse(),
        },
    });
    return net.send(from, outMessage);
}

fun RewardWallet.sendBurn(self, from: address, value: int, jettonAmount: int, sellMinTon: coins?): SendResultList {
    val customPayload: cell? = sellMinTon != null ? SellIntent { minTon: sellMinTon! }.toCell() : null;
    val outMessage = createMessage({
        bounce: true,
        value,
        dest: self.address,
        body: AskToBurn { queryId: 0, jettonAmount, sendExcessesTo: from, customPayload },
    });
    return net.send(from, outMessage);
}
