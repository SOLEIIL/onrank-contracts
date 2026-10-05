// Future-factory world: RewardMasterDex + CurveDex + RewardWalletDex.
// Graduation in these tests still deploys PoolV2. Live v2 contracts are not used here.
import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@tests/fixtures"
import "@wrappers/CurveDex.gen"
import "@wrappers/FeeSplitterV2.gen"
import "@wrappers/PoolV2.gen"
import "@wrappers/RewardMasterDex.gen"
import "@wrappers/RewardWalletDex.gen"
import "@contracts/common/consts"
import "@contracts/launcher-dex/curve-dex-storage"
import "@contracts/launcher-dex/dividend-messages"
import "@contracts/launcher-dex/reward-types"
import "@contracts/launcher-v2/fee-splitter-messages"
import "@contracts/launcher-v2/fee-splitter-types"
import "@contracts/launcher-v2/launcher-messages"
import "@contracts/launcher-v2/launcher-types"
import "@contracts/launcher-v2/reward-messages"
import "@contracts/vendor/jetton/messages"

struct DexWorld {
    factory: Treasury
    vault: Treasury
    protocol: Treasury
    pot: Treasury
    buyback: Treasury
    master: RewardMasterDex
    splitter: FeeSplitterV2
    curve: CurveDex
}

const COIN = 1000000000
const CURVE_SUPPLY = 800 * COIN
const POOL_SUPPLY = 200 * COIN
const V_TON0 = ton("30")
const V_TOKEN0 = 1073 * COIN
const GRADUATION_TON = ton("85")
const GRADUATION_FEE = ton("1")
const FEE_BPS = 100

fun dexCurveParams(protocol: address): CurveParams {
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
        walletCode: build("RewardWalletDex"),
    };
}

fun setupDex(masterValue: coins = ton("0.15"), open: bool = true): DexWorld {
    testing.setNow(WORLD_T0);
    val factory = testing.treasury("dex-factory");
    val vault = testing.treasury("dex-vault");
    val protocol = testing.treasury("dex-protocol");
    val pot = testing.treasury("dex-pot");
    val buyback = testing.treasury("dex-buyback");

    val master = RewardMasterDex.fromStorage({
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
        excludedOwner: null,
        excludedBalance: 0,
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

    val curve = CurveDex.fromStorage({
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
        params: dexCurveParams(protocol.address).toCell(),
        extra: CurveDexExtra { creator: null }.toCell(),
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

fun wallet(w: DexWorld, owner: address): RewardWalletDex {
    return RewardWalletDex.fromAddress(w.master.getWalletAddress(owner));
}

fun balanceOf(w: DexWorld, owner: address): int {
    return wallet(w, owner).getRewardWalletData().balance;
}

fun masterData(w: DexWorld): RewardMasterDataReply {
    return w.master.getRewardMasterData();
}

fun indexValue(w: DexWorld, id: int): int {
    return indexOf(masterData(w).indices, id as uint8);
}

fun claimable(w: DexWorld, owner: address, id: int): int {
    return amountOf(wallet(w, owner).getClaimable(masterData(w).indices), id as uint8);
}

fun bump(w: DexWorld, id: int, amount: int): SendResultList {
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

fun buy(w: DexWorld, who: address, value: coins, minOut: coins = 0): SendResultList {
    return w.curve.sendBuy(who, 3, minOut, null, { value, bounce: true });
}

fun buyOk(w: DexWorld, who: address, value: coins): SendResultList {
    val res = buy(w, who, value);
    expect(res).toHaveSuccessfulTx<Buy>({ to: w.curve.address });
    expect(res).toHaveSuccessfulTx<MintReward>({ from: w.curve.address, to: w.master.address });
    expect(res).toHaveSuccessfulTx<RewardTransferStep>({
        from: w.master.address,
        to: w.master.getWalletAddress(who),
    });
    return res;
}

fun transfer(
    w: DexWorld,
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

fun graduate(
    w: DexWorld,
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

fun RewardWalletDex.sendTransfer(
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
