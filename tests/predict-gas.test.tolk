// Predict gas budgets: every value constant that funds a downstream chain is checked against the fees the emulator
// charges on that chain, with headroom — a path that gets more expensive fails here instead of stranding a market.
//   BET_GAS            → RecordBet (deploy + write of the BetPosition + the excess refund to the owner)
//   MARKET_GAS         → the market's own PlaceBet compute + BetPlacedEvent (stays in the market's reserve)
//   PARTNER_GAS        → the PartnerPayout forwarded on a partner bet
//   ORACLE_MSG_VALUE   → Resolve compute + HousePayout forward (+ event)
//   POSITION_CLAIM_GAS → Claim → ClaimPayout → WinPayout + ClaimAck
// It also prints the reserve a market burns over its life, the number the keeper's deployValue-per-cadence rests on.
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/big_array"
import "@acton/types/transaction"

import "@wrappers/BetPosition.gen"
import "@wrappers/Market.gen"
import "@contracts/predict/predict-messages"
import "@contracts/predict/predict-types"

const HEADROOM_PCT = 25
const BET_GAS = ton("0.02") // Market.BET_GAS
const MARKET_GAS = ton("0.005") // Market.MARKET_GAS
const PARTNER_GAS = ton("0.005") // Market.PARTNER_GAS
/// What a native / partner PlaceBet leaves in the market on top of the gross stake (app onchain.ts betValue()).
const NATIVE_KEPT = BET_GAS + MARKET_GAS
const PARTNER_KEPT = BET_GAS + MARKET_GAS + PARTNER_GAS
const ORACLE_MSG_VALUE = ton("0.05") // app onchain.ts ORACLE_MSG_VALUE
const POSITION_CLAIM_GAS = ton("0.03") // BetPosition.POSITION_CLAIM_GAS
const T0: uint32 = 1800000000
const RESOLVES: uint32 = 1800000000 + 3600

fun downstreamFees(res: SendResultList): coins {
    var total = 0;
    var i = 1;
    while (i < res.size()) {
        total += res.get(i).tx.load().totalFees.grams;
        i += 1;
    }
    return total;
}

fun allFees(res: SendResultList): coins {
    var total = 0;
    var i = 0;
    while (i < res.size()) {
        total += res.get(i).tx.load().totalFees.grams;
        i += 1;
    }
    return total;
}

fun expectBudgetCovers(budget: coins, fees: coins, label: string) {
    println("gas {}: fees {} nanoTON, budget {} nanoTON", label, fees, budget);
    expect(fees * (100 + HEADROOM_PCT) / 100 <= budget).toBeTrue();
}

fun deploy(oracle: address, house: address): Market {
    val cfg = MarketConfig {
        oracle,
        house,
        asset: 0,
        cadence: 0,
        openAt: T0,
        closesAt: RESOLVES,
        resolvesAt: RESOLVES,
        feeBps: 200,
        kind: KIND_UPDOWN,
        threshold: 0,
        partnerBps: 300,
        claimWindowSec: 7 * 86400,
        limits: MarketLimits {
            minBet: ton("0.1"),
            maxBet: 0,
            maxPool: 0,
        }.toCell(),
    };
    return Market.fromStorage({ config: cfg.toCell(), poolYes: 0, poolNo: 0, openPrice: 0, closePrice: 0, openSet: false, resolved: false, outcome: 0, proof: null });
}

get fun `test gas: BET_GAS, PARTNER_GAS, ORACLE_MSG_VALUE and POSITION_CLAIM_GAS cover their chains with headroom`() {
    val oracle = testing.treasury("oracle");
    val house = testing.treasury("house");
    val alice = testing.treasury("alice");
    val bob = testing.treasury("bob");
    val partner = testing.treasury("partner");
    testing.setNow(T0);
    val market = deploy(oracle.address, house.address);
    val dep = market.deploy(oracle.address, { value: ton("0.06"), bounce: false });
    expect(dep).toHaveSuccessfulDeploy({ to: market.address });
    val lock = market.sendLockOpen(
        oracle.address,
        1,
        100,
        T0,
        0xA1,
        { value: ORACLE_MSG_VALUE },
    );
    expect(lock).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    println("gas deploy: {} nanoTON, lock: {} nanoTON", allFees(dep), allFees(lock));

    // native bet: BET_GAS must pay the RecordBet (position deploy + excess refund) chain
    val b1 = market.sendPlaceBet(alice.address, 1, true, null, { value: ton("10") + NATIVE_KEPT });
    expect(b1).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expectBudgetCovers(BET_GAS, downstreamFees(b1), "BET_GAS → RecordBet");
    // MARKET_GAS must pay the market's own compute + the BetPlacedEvent (what the reserve used to bleed per bet)
    expectBudgetCovers(MARKET_GAS, b1.get(0).tx.load().totalFees.grams, "MARKET_GAS → PlaceBet compute + event");

    // partner bet: PARTNER_GAS must pay the PartnerPayout forward, on top of the RecordBet chain
    val b2 = market.sendPlaceBet(
        bob.address,
        1,
        false,
        partner.address,
        { value: ton("20") + PARTNER_KEPT },
    );
    expect(b2).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expectBudgetCovers(
        BET_GAS + PARTNER_GAS,
        downstreamFees(b2),
        "BET_GAS + PARTNER_GAS → RecordBet + PartnerPayout",
    );
    expectBudgetCovers(MARKET_GAS, b2.get(0).tx.load().totalFees.grams, "MARKET_GAS → partner PlaceBet compute + event");

    // resolve: ORACLE_MSG_VALUE covers the compute and the HousePayout forward
    val before = testing.getAccountBalance(market.address);
    testing.setNow(RESOLVES);
    val res = market.sendResolve(
        oracle.address,
        2,
        50,
        RESOLVES,
        0xB2,
        { value: ORACLE_MSG_VALUE },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expectBudgetCovers(ORACLE_MSG_VALUE, allFees(res), "ORACLE_MSG_VALUE → Resolve + HousePayout");

    // claim: POSITION_CLAIM_GAS covers Claim → ClaimPayout → WinPayout + ClaimAck
    val posB = BetPosition.fromAddress(market.getPositionAddress(bob.address));
    val claim = posB.sendClaim(bob.address, 1, { value: POSITION_CLAIM_GAS });
    expect(claim).toHaveTx<WinPayout>({ from: market.address, to: bob.address });
    expectBudgetCovers(POSITION_CLAIM_GAS, allFees(claim), "POSITION_CLAIM_GAS → Claim chain");
    val posA = BetPosition.fromAddress(market.getPositionAddress(alice.address));
    expect(
        posA.sendClaim(alice.address, 1, { value: POSITION_CLAIM_GAS }),
    ).toHaveSuccessfulTx<ClaimPayout>({ to: market.address });

    // what the market's own reserve paid over its life (deploy → resolve → 2 claims): the deployValue floor
    val after = testing.getAccountBalance(market.address);
    println(
        "gas market reserve: {} → {} nanoTON over the life of a 2-bet market (pot 10 + 19.4 paid out)",
        before,
        after,
    );
    expect(
        after > ton("0.03"),
    ).toBeTrue();                           // a 0.06 reserve (the short-window deployValue) still ends above half: ample margin
}

/// The market's own headroom (balance minus the pot it owes) is what funds PlaceBet compute + the event message,
/// the payout forward fees and rent. Since v1.1 a PlaceBet keeps MARKET_GAS in the market on top of BET_GAS
/// (forwarded whole to the position), so a bet must never shrink the headroom: a busy short-window market
/// (deployValue 0.06 + two oracle messages) ends its betting phase at least as collateralised as it started.
get fun `test gas: headroom never shrinks over 200 bets and the market still pays every claim`() {
    val oracle = testing.treasury("oracle");
    val house = testing.treasury("house");
    val alice = testing.treasury("alice");
    val bob = testing.treasury("bob");
    testing.setNow(T0);
    val market = deploy(oracle.address, house.address);
    expect(
        market.deploy(oracle.address, { value: ton("0.06"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: market.address });
    expect(
        market.sendLockOpen(oracle.address, 1, 100, T0, 0xA1, { value: ORACLE_MSG_VALUE }),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    val headroom0 = testing.getAccountBalance(market.address);

    var i = 0;
    while (i < 200) {
        val who: Treasury = i % 2 == 0 ? alice : bob;
        expect(
            market.sendPlaceBet(who.address, i as uint64, i % 2 == 0, null, { value: ton("1") + NATIVE_KEPT }),
        ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
        i += 1;
    }
    val st = market.getMarketState();
    expect(st.poolYes + st.poolNo).toEqual(ton("200"));
    val headroom = testing.getAccountBalance(market.address) - (st.poolYes + st.poolNo);
    println(
        "gas headroom: {} → {} nanoTON after 200 bets ({} nanoTON per bet)",
        headroom0,
        headroom,
        (headroom - headroom0) / 200,
    );
    // the pot stays fully collateralised and the reserve is stable or growing: MARKET_GAS covers every bet's own cost
    expect(headroom >= headroom0).toBeTrue();

    testing.setNow(RESOLVES);
    expect(
        market.sendResolve(oracle.address, 999, 200, RESOLVES, 0xB2, { value: ORACLE_MSG_VALUE }),
    ).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // YES (alice, 100) wins the whole distributable 196; both claims settle
    val posA = BetPosition.fromAddress(market.getPositionAddress(alice.address));
    expect(
        posA.sendClaim(alice.address, 1, { value: POSITION_CLAIM_GAS }),
    ).toHaveTx<WinPayout>({ from: market.address, to: alice.address, value: ton("196") });
    val posB = BetPosition.fromAddress(market.getPositionAddress(bob.address));
    expect(
        posB.sendClaim(bob.address, 1, { value: POSITION_CLAIM_GAS }),
    ).toHaveSuccessfulTx<ClaimPayout>({ to: market.address });
    expect(posB.getBetPositionData().claimed).toBeTrue();
    val after = testing.getAccountBalance(market.address);
    println("gas headroom after resolve + 2 claims: {} nanoTON", after);
    expect(after > 0).toBeTrue();
}
