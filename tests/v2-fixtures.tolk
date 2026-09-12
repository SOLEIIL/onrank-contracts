// Launcher v2 world: RewardMasterV2 + FeeSplitterV2 + a real CurveV2 (opened by a "factory"
// treasury); graduation deploys the PoolV2. The vault is a treasury until RewardVaultV2 lands: it
// receives PayRewardReq and bumps indices directly.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"

import "@tests/fixtures"
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

struct V2World {
    factory: Treasury
    vault: Treasury
    protocol: Treasury
    pot: Treasury
    buyback: Treasury
    master: RewardMasterV2
    splitter: FeeSplitterV2
    curve: CurveV2
}

const COIN = 1000000000 // 9 decimals
const REWARD_UNIT = 1000000 // 6 decimals (USDT-like)

const CURVE_SUPPLY = 800 * COIN
const POOL_SUPPLY = 200 * COIN
const V_TON0 = ton("30")
const V_TOKEN0 = 1073 * COIN
const GRADUATION_TON = ton("85")
const GRADUATION_FEE = ton("1")
const FEE_BPS = 100

fun v2CurveParams(protocol: address): CurveParams {
    return {
        protocol,
        feeBps: FEE_BPS,
        curveSupply: CURVE_SUPPLY,
        poolSupply: POOL_SUPPLY,
        graduationTon: GRADUATION_TON,
        graduationFee: GRADUATION_FEE,
        minBuy: ton("0.1"),
        poolLpFeeBps: 100,
        poolProtocolFeeBps: 100,
        walletCode: build("RewardWalletV2"),
    };
}

/// Deploys the world. `masterValue` is the master's initial balance (rule 6: it must work with the
/// bare storage reserve).
fun setupV2(masterValue: coins = ton("0.15"), open: bool = true): V2World {
    testing.setNow(WORLD_T0);
    val factory = testing.treasury("v2-factory");
    val vault = testing.treasury("v2-vault");
    val protocol = testing.treasury("v2-protocol");
    val pot = testing.treasury("v2-pot");
    val buyback = testing.treasury("v2-buyback");

    val master = RewardMasterV2.fromStorage({
        totalSupply: 0,
        poolReserve: 0,
        curveOpen: false,
        pool: null,
        roles: RewardMasterRoles {
            factory: factory.address,
            seq: 0,
            curve: null,
            vault: null,
        }.toCell(),
        indices: createEmptyMap(),
        remainders: createEmptyMap(),
        metadata: jettonMetadata("COIN"),
    });
    expect(
        master.deploy(factory.address, { value: masterValue, bounce: false }),
    ).toHaveSuccessfulDeploy({ to: master.address });

    val splitter = FeeSplitterV2.fromStorage({
        admin: factory.address,
        active: true,
        locked: 0,
        accrued: 0,
        totalIn: 0,
        minSplit: 0,
        minProtocolBps: 1000,
        routes: FeeRoutes {
            protocol: protocol.address,
            pot: pot.address,
            buyback: buyback.address,
        }.toCell(),
        reward: RewardRoute {
            vault: vault.address,
            splits: {
                holdersBps: 7000,
                protocolBps: 1500,
                potBps: 1000,
                buybackBps: 500,
            },
        }.toCell(),
        proposal: null,
    });
    expect(
        splitter.deploy(factory.address, { value: ton("0.1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: splitter.address });

    val curve = CurveV2.fromStorage({
        state: CURVE_INIT,
        virtualTon: V_TON0,
        virtualToken: V_TOKEN0,
        realTon: 0,
        sold: 0,
        pool: null,
        roles: CurveRoles {
            factory: factory.address,
            master: master.address,
            splitter: splitter.address,
        }.toCell(),
        params: v2CurveParams(protocol.address).toCell(),
    });
    expect(
        curve.deploy(factory.address, { value: ton("0.15"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: curve.address });

    expect(
        master.sendWireMaster(
            factory.address,
            0,
            curve.address,
            vault.address,
            { value: ton("0.05"), bounce: true },
        ),
    ).toHaveSuccessfulTx<WireMaster>({ to: master.address });
    if (open) {
        expect(
            curve.sendOpenCurve(factory.address, 0, { value: ton("0.05"), bounce: true }),
        ).toHaveSuccessfulTx<OpenCurve>({ to: curve.address });
    }
    return {
        factory,
        vault,
        protocol,
        pot,
        buyback,
        master,
        splitter,
        curve,
    };
}

fun wallet(w: V2World, owner: address): RewardWalletV2 {
    return RewardWalletV2.fromAddress(w.master.getWalletAddress(owner));
}

fun balanceOf(w: V2World, owner: address): int {
    return wallet(w, owner).getRewardWalletData().balance;
}

fun isBusy(w: V2World, owner: address): bool {
    return wallet(w, owner).getRewardWalletData().pending != null;
}

fun masterData(w: V2World): RewardMasterDataReply {
    return w.master.getRewardMasterData();
}

fun indexValue(w: V2World, id: int): int {
    return indexOf(masterData(w).indices, id as uint8);
}

fun claimable(w: V2World, owner: address, id: int): int {
    return amountOf(wallet(w, owner).getClaimable(masterData(w).indices), id as uint8);
}

/// The vault bumps reward `id` by `amount` (in the real world: reward jettons arrived).
fun bump(w: V2World, id: int, amount: int): SendResultList {
    val res = w
        .master
        .sendIndexBump(
            w.vault.address,
            7,
            id as uint8,
            amount,
            { value: ton("0.05"), bounce: true },
        );
    expect(res).toHaveSuccessfulTx<IndexBump>({ from: w.vault.address, to: w.master.address });
    return res;
}

fun buy(
    w: V2World,
    who: address,
    value: coins,
    minOut: coins = 0,
    recipient: address? = null,
): SendResultList {
    return w.curve.sendBuy(who, 3, minOut, recipient, { value, bounce: true });
}

/// Buy on the curve and check the coins landed.
fun buyOk(w: V2World, who: address, value: coins): SendResultList {
    val res = buy(w, who, value);
    expect(res).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
    expect(res).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.master.address });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({
        from: w.master.address,
        to: w.master.getWalletAddress(who),
    });
    return res;
}

fun sell(
    w: V2World,
    who: address,
    amount: coins,
    minTon: coins,
    value: coins = ton("0.2"),
): SendResultList {
    return wallet(w, who).sendBurn(who, value, amount, minTon);
}

fun claim(w: V2World, owner: address, value: coins = ton("0.3")): SendResultList {
    return wallet(w, owner).sendClaimRewards(owner, 5, { value, bounce: true });
}

fun transfer(
    w: V2World,
    from: address,
    to: address,
    amount: int,
    value: coins = ton("0.2"),
    forwardTon: coins = 0,
): SendResultList {
    return wallet(w, from).sendTransfer(
        from,
        value,
        amount,
        to,
        from,
        null,
        forwardTon,
        null,
    );
}

fun poolOf(w: V2World): PoolV2 {
    return PoolV2.fromAddress(w.curve.getCurveData().pool!);
}

fun poolBuy(w: V2World, who: address, value: coins, minOut: coins = 0): SendResultList {
    return poolOf(w).sendSwapTonForCoin(who, 4, minOut, { value, bounce: true });
}

/// Buys until the curve graduates (at most `maxBuys` purchases of `each` TON).
fun graduate(
    w: V2World,
    whale: address,
    each: coins = ton("20"),
    maxBuys: int = 10,
): SendResultList {
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

/// Sum of wallet balances of `owners` plus the pool reserve: must equal the master's supply when
/// nothing is in flight.
fun supplyInvariant(w: V2World, owners: BigArray<address>) {
    val m = masterData(w);
    var held = 0;
    var i = 0;
    while (i < owners.size()) {
        val owner = owners.get(i);
        if (testing.isDeployed(w.master.getWalletAddress(owner))) {
            held += balanceOf(w, owner);
        }
        i += 1;
    }
    expect(m.totalSupply).toEqual(held);
    if (m.pool != null) {
        expect(PoolV2.fromAddress(m.pool!).getPoolData().reserveCoin).toEqual(m.poolReserve);
    }
}

/// TEP-74 transfer on a RewardWalletV2 (same body as a standard jetton wallet).
fun RewardWalletV2.sendTransfer(
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

fun RewardWalletV2.sendBurn(
    self,
    from: address,
    value: int,
    jettonAmount: int,
    sellMinTon: coins?,
): SendResultList {
    val customPayload: cell? = sellMinTon != null
        ? SellIntent { minTon: sellMinTon! }.toCell()
        : null;
    val outMessage = createMessage({
        bounce: true,
        value,
        dest: self.address,
        body: AskToBurn {
            queryId: 0,
            jettonAmount,
            sendExcessesTo: from,
            customPayload,
        },
    });
    return net.send(from, outMessage);
}
