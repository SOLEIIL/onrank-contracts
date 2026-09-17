import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@wrappers/BetPosition.gen"
import "@wrappers/Market.gen"
import "@contracts/common/errors"
import "@contracts/predict/predict-messages"
import "@contracts/predict/predict-types"

const T0: uint32 = 1800000000
const CLOSES: uint32 = 1800000000 + 1800
const RESOLVES: uint32 = 1800000000 + 3600
const VOID_GRACE: uint32 = 3600
const CLAIM_WINDOW: uint32 = 7 * 86400
/// Mirror of Market.BET_GAS + MARKET_GAS + PARTNER_GAS: what a partner bet leaves in the market on top of the gross stake.
const PARTNER_KEPT = ton("0.03")
/// Mirror of Market.BET_GAS + MARKET_GAS: what a native bet leaves on top of the gross stake.
const BET_KEPT = ton("0.025")
/// Mirror of BetPosition.POSITION_RESERVE: the only TON a position keeps after a RecordBet / ClaimAck.
const POSITION_RESERVE = ton("0.01")

struct Actors {
    oracle: Treasury
    house: Treasury
    alice: Treasury
    bob: Treasury
    carol: Treasury
    partner: Treasury
}

fun actors(): Actors {
    return {
        oracle: testing.treasury("oracle"),
        house: testing.treasury("house"),
        alice: testing.treasury("alice"),
        bob: testing.treasury("bob"),
        carol: testing.treasury("carol"),
        partner: testing.treasury("partner"),
    };
}

fun deployMarket(a: Actors, feeBps: uint16): Market {
    return deployKind(a, feeBps, KIND_UPDOWN, 0);
}

/// Price-target market: YES on a touch of `threshold` any time before RESOLVES (the deadline).
fun deployHit(a: Actors, threshold: uint128): Market {
    return deployKind(a, 200, KIND_HIT, threshold);
}

fun deployKind(a: Actors, feeBps: uint16, kind: uint8, threshold: uint128): Market {
    return deployCfg(a, feeBps, kind, threshold, { minBet: ton("0.1"), maxBet: 0, maxPool: 0 });
}

/// Up/down window with explicit per-bet / per-market caps (0 = unlimited).
fun deployLimited(a: Actors, minBet: coins, maxBet: coins, maxPool: coins): Market {
    return deployCfg(a, 200, KIND_UPDOWN, 0, { minBet, maxBet, maxPool });
}

fun deployCfg(a: Actors, feeBps: uint16, kind: uint8, threshold: uint128, limits: MarketLimits): Market {
    val cfg = MarketConfig {
        oracle: a.oracle.address,
        house: a.house.address,
        asset: 0,
        cadence: kind == KIND_HIT ? 255 : 1,
        openAt: T0,
        closesAt: kind == KIND_HIT ? RESOLVES : CLOSES,
        resolvesAt: RESOLVES,
        feeBps,
        kind,
        threshold,
        partnerBps: 300,
        claimWindowSec: CLAIM_WINDOW,
        limits: limits.toCell(),
    };
    val market = Market.fromStorage({
        config: cfg.toCell(),
        poolYes: 0,
        poolNo: 0,
        openPrice: 0,
        closePrice: 0,
        openSet: false,
        resolved: false,
        outcome: 0,
        proof: null,
    });
    expect(
        market.deploy(a.house.address, { value: ton("1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: market.address });
    return market;
}

/// Bet `stake` GRAM on `isYes`; the value carries stake + BET_GAS + MARKET_GAS (0.025) so the recorded stake is exactly `stake`.
fun bet(market: Market, who: Treasury, isYes: bool, stake: coins): SendResultList {
    return market.sendPlaceBet(who.address, 1, isYes, null, { value: stake + BET_KEPT });
}

/// A bet placed through an integration: `gross` GRAM in (+ BET_GAS + MARKET_GAS + PARTNER_GAS), the partner's cut is taken off before the pool.
fun partnerBet(
    market: Market,
    who: Treasury,
    partner: Treasury,
    isYes: bool,
    gross: coins,
): SendResultList {
    return market.sendPlaceBet(
        who.address,
        1,
        isYes,
        partner.address,
        { value: gross + PARTNER_KEPT },
    );
}

fun positionOf(market: Market, owner: address): BetPosition {
    return BetPosition.fromAddress(market.getPositionAddress(owner));
}

/// Oracle locks open price 100 at T0 (the usual up/down prelude).
fun lockOpen(market: Market, a: Actors) {
    expect(
        market.sendLockOpen(a.oracle.address, 1, 100, T0, 0xA1, { value: ton("0.1") }),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
}

/// Oracle resolves at RESOLVES with `price` (open is 100: >100 → YES, <100 → NO, 100 → void).
fun resolveAt(market: Market, a: Actors, price: uint128): SendResultList {
    testing.setNow(RESOLVES);
    return market.sendResolve(a.oracle.address, 1, price, RESOLVES, 0xB2, { value: ton("0.1") });
}

// ---------------------------------------------------------------------------

/// Prints the inputs and the resulting Market address so the TypeScript init-data builder (app/src/lib/predict/
/// onchain.ts) can be checked bit-for-bit against the Tolk serialization: same code + same config ⇒ same address.
get fun `test predict: layout cross-check — addresses for the TS builder test`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    println(
        "xcheck oracle={} house={} market={}",
        a.oracle.address,
        a.house.address,
        market.address,
    );
}

get fun `test predict: two-sided market pays the house fee to the Ledger and winners pro-rata`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200); // 2%

    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });

    val b1 = bet(market, a.alice, true, ton("10"));
    expect(b1).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    // the position keeps POSITION_RESERVE only: the rest of BET_GAS comes straight back to the bettor
    val posA = positionOf(market, a.alice.address);
    expect(b1).toHaveTx<PositionExcess>({ from: posA.address, to: a.alice.address });
    expect(testing.getAccountBalance(posA.address) <= POSITION_RESERVE).toBeTrue();
    expect(testing.getAccountBalance(posA.address) > 0).toBeTrue();
    expect(
        bet(market, a.bob, false, ton("20")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    val data = market.getMarketData();
    expect(data.poolYes).toEqual(ton("10"));
    expect(data.poolNo).toEqual(ton("20"));
    // the open-price proof is committed on chain for public verification
    expect(data.proof!.openAttestation).toEqual(0xA1);
    // the flat state the keeper polls agrees
    val st = market.getMarketState();
    expect(st.poolNo).toEqual(ton("20"));
    expect(st.openSet).toBeTrue();
    expect(st.resolved).toBeFalse();

    // resolve: close 200 > open 100 → YES wins. Fee = 2% of 30 = 0.6 GRAM straight to the house (Ledger).
    testing.setNow(RESOLVES);
    val res = market.sendResolve(
        a.oracle.address,
        1,
        200,
        RESOLVES,
        0xB2,
        { value: ton("0.1") },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(res).toHaveTx<HousePayout>({ from: market.address, to: a
            .house
            .address, value: ton("0.6") });
    val resolved = market.getMarketData();
    expect(resolved.outcome).toEqual(OUTCOME_YES);
    expect(resolved.proof!.closeAttestation).toEqual(0xB2); // close-price proof committed too

    // Alice (only YES) takes the whole distributable 29.4; the loser gets nothing.
    val aliceBefore = testing.getAccountBalance(a.alice.address);
    val claim = posA.sendClaim(a.alice.address, 1, { value: ton("0.1") });
    expect(claim).toHaveTx<WinPayout>({ from: market.address, to: a
            .alice
            .address, value: ton("29.4") });
    expect(posA.getBetPositionData().claimed).toBeTrue();
    // the claim gas she attached comes back above POSITION_RESERVE: nothing stays stuck in the position
    expect(claim).toHaveTx<PositionExcess>({ from: posA.address, to: a.alice.address });
    expect(testing.getAccountBalance(posA.address) <= POSITION_RESERVE).toBeTrue();
    // (emulator treasuries are not debited for what they send: the delta is payout + residual, fees excepted)
    val residual = testing.getAccountBalance(a.alice.address) - aliceBefore - ton("29.4");
    expect(residual > ton("0.1") - ton("0.01")).toBeTrue(); // the whole claim gas but the chain's fees came back
    expect(residual < ton("0.1")).toBeTrue();

    // A second claim is refused: no double payout.
    expect(
        posA.sendClaim(a.alice.address, 2, { value: ton("0.1") }),
    ).toHaveFailedTx<Claim>({ to: posA.address, exitCode: Errors.AlreadyClaimed });

    // The loser can settle (claimed) but receives no payout.
    val posB = positionOf(market, a.bob.address);
    val loser = posB.sendClaim(a.bob.address, 1, { value: ton("0.1") });
    expect(loser).toHaveSuccessfulTx<ClaimPayout>({ from: posB.address, to: market.address });
    expect(posB.getBetPositionData().claimed).toBeTrue();
}

get fun `test predict: a lone bettor (one-sided) is refunded in full, no house fee`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    expect(
        bet(market, a.alice, true, ton("5")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    testing.setNow(RESOLVES);
    val res = market.sendResolve(
        a.oracle.address,
        1,
        200,
        RESOLVES,
        0xB2,
        { value: ton("0.1") },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // one-sided → void, and NO fee is sent to the house
    expect(res).toNotHaveTx<HousePayout>({ from: market.address });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_VOID);

    val posA = positionOf(market, a.alice.address);
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a
            .alice
            .address, value: ton("5") });                                                                                                                  // full refund
}

get fun `test predict: open == close resolves to void and refunds both sides`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    testing.setNow(RESOLVES);
    val res = market.sendResolve(
        a.oracle.address,
        1,
        100,
        RESOLVES,
        0xB2,
        { value: ton("0.1") },
    ); // close == open
    expect(res).toNotHaveTx<HousePayout>({ from: market.address });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_VOID);
    val posA = positionOf(market, a.alice.address);
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("10") });
}

get fun `test predict: betting window and oracle guards`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);

    // no bet before the open price is locked
    expect(
        bet(market, a.alice, true, ton("1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.OpenNotLocked });
    // only the oracle can lock
    expect(
        market.sendLockOpen(
            a.alice.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<LockOpen>({ to: market.address, exitCode: Errors.NotFromOracle });

    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    // locking twice is refused
    expect(
        market.sendLockOpen(
            a.oracle.address,
            2,
            111,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<LockOpen>({ to: market.address, exitCode: Errors.OpenAlreadyLocked });

    // resolving before resolvesAt is refused
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            200,
            RESOLVES,
            0xB2,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.NotYetResolvable });

    // betting closes at closesAt
    testing.setNow(CLOSES);
    expect(
        bet(market, a.alice, true, ton("1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BettingClosed });

    // only the oracle can resolve
    testing.setNow(RESOLVES);
    expect(
        market.sendResolve(
            a.alice.address,
            1,
            200,
            RESOLVES,
            0xB2,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.NotFromOracle });
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            200,
            RESOLVES,
            0xB2,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // resolving twice is refused
    expect(
        market.sendResolve(
            a.oracle.address,
            2,
            300,
            RESOLVES,
            0xB2,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.AlreadyResolved });
}

get fun `test predict: ForceVoid only after the grace, then everyone is refunded`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    // too early
    testing.setNow(RESOLVES);
    expect(
        market.sendForceVoid(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveFailedTx<ForceVoid>({ to: market.address, exitCode: Errors.VoidGraceNotElapsed });

    // after the grace anyone can void; both sides are refunded, no fee
    testing.setNow(RESOLVES + VOID_GRACE);
    val res = market.sendForceVoid(a.bob.address, 2, { value: ton("0.1") });
    expect(res).toHaveSuccessfulTx<ForceVoid>({ to: market.address });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_VOID);
    val posB = positionOf(market, a.bob.address);
    expect(
        posB.sendClaim(a.bob.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.bob.address, value: ton("10") });
}

// ---------------------------------------------------------------------------
// Price targets ("hit")
// ---------------------------------------------------------------------------

get fun `test hit: a touch before the deadline resolves YES right there and closes betting`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployHit(a, 200); // target 200, no LockOpen needed
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("30")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    // a price under the target cannot resolve early
    testing.setNow(T0 + 600);
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            199,
            T0 + 600,
            0xC1,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.TargetNotReached });
    // a stale "touch" (published long ago) is refused even if at the target
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            250,
            T0,
            0xC1,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.StaleOraclePrice });

    // the touch: price >= target, published now → YES, fee 2% of 40 = 0.8 to the house
    val res = market.sendResolve(
        a.oracle.address,
        2,
        200,
        T0 + 600,
        0xC2,
        { value: ton("0.1") },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(res).toHaveTx<HousePayout>({ from: market.address, to: a
            .house
            .address, value: ton("0.8") });
    val data = market.getMarketData();
    expect(data.outcome).toEqual(OUTCOME_YES);
    expect(data.closePrice).toEqual(200);
    expect(data.config.kind).toEqual(KIND_HIT);
    expect(data.config.threshold).toEqual(200);

    // no more bets once touched
    expect(
        bet(market, a.bob, false, ton("1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.AlreadyResolved });
    // Alice takes the whole distributable 39.2
    val posA = positionOf(market, a.alice.address);
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("39.2") });
}

get fun `test hit: no touch by the deadline resolves NO from the deadline price`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployHit(a, 200);
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    // a second target (300) used below for the "deadline price at the target" case (the clock only moves forward)
    val m2 = deployHit(a, 300);
    expect(bet(m2, a.alice, true, ton("1"))).toHaveSuccessfulTx<PlaceBet>({ to: m2.address });
    expect(bet(m2, a.bob, false, ton("1"))).toHaveSuccessfulTx<PlaceBet>({ to: m2.address });
    // betting stays open right up to the deadline
    testing.setNow(RESOLVES - 1);
    expect(
        bet(market, a.alice, true, ton("1")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    testing.setNow(RESOLVES);
    // the deadline resolve must carry a price published around the deadline
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            150,
            T0 + 600,
            0xC1,
            { value: ton("0.1") },
        ),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.StaleOraclePrice });
    val res = market.sendResolve(
        a.oracle.address,
        2,
        150,
        RESOLVES,
        0xC2,
        { value: ton("0.1") },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_NO);
    // Bob (NO, 10) takes the distributable 21 × 0.98 = 20.58
    val posB = positionOf(market, a.bob.address);
    expect(
        posB.sendClaim(a.bob.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.bob.address, value: ton("20.58") });
    // a deadline price at/above the target still says YES (the touch happened at the deadline)
    expect(
        m2.sendResolve(
            a.oracle.address,
            1,
            300,
            RESOLVES,
            0xC3,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<Resolve>({ to: m2.address });
    expect(m2.getMarketData().outcome).toEqual(OUTCOME_YES);
}

get fun `test hit: a one-sided target is void on a touch, everyone refunded, no fee`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployHit(a, 200);
    expect(
        bet(market, a.alice, true, ton("5")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    testing.setNow(T0 + 60);
    val res = market.sendResolve(
        a.oracle.address,
        1,
        210,
        T0 + 60,
        0xC1,
        { value: ton("0.1") },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(res).toNotHaveTx<HousePayout>({ from: market.address });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_VOID);
    val posA = positionOf(market, a.alice.address);
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("5") });
}

// ---------------------------------------------------------------------------
// Partner (integration) bets
// ---------------------------------------------------------------------------

get fun `test partner: 3% of a partner bet goes to the partner on the spot, the net joins the common pool`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });

    // Alice bets 10 natively; Bob bets 20 gross through the partner → 0.6 to the partner, 19.4 in the pool
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    val pb = partnerBet(market, a.bob, a.partner, false, ton("20"));
    expect(pb).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(pb).toHaveTx<PartnerPayout>({ from: market.address, to: a
            .partner
            .address, value: ton("0.6") });
    val data = market.getMarketData();
    expect(data.poolYes).toEqual(ton("10"));
    expect(data.poolNo).toEqual(ton("19.4"));
    // the position records the NET stake
    expect(positionOf(market, a.bob.address).getBetPositionData().no).toEqual(ton("19.4"));

    // neither the house, the oracle nor the market itself can pose as a partner
    expect(
        market.sendPlaceBet(a.bob.address, 1, false, a.house.address, { value: ton("1") + PARTNER_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BadPartner });
    expect(
        market.sendPlaceBet(a.bob.address, 1, false, a.oracle.address, { value: ton("1") + PARTNER_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BadPartner });
    // a refused partner bet pools nothing
    expect(market.getMarketState().poolNo).toEqual(ton("19.4"));
    // min bet applies to the net stake: 0.1 gross → 0.097 net → too small
    expect(
        market.sendPlaceBet(a.bob.address, 1, false, a.partner.address, { value: ton("0.1") + PARTNER_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BetTooSmall });

    // resolve NO: pot 29.4, house fee 2% = 0.588, Bob takes 28.812. Conservation: 10 + 20 = 0.6 + 0.588 + 28.812.
    testing.setNow(RESOLVES);
    val res = market.sendResolve(
        a.oracle.address,
        1,
        50,
        RESOLVES,
        0xB2,
        { value: ton("0.1") },
    );
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(res).toHaveTx<HousePayout>({ from: market.address, to: a
            .house
            .address, value: ton("0.588") });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_NO);
    val posB = positionOf(market, a.bob.address);
    expect(
        posB.sendClaim(a.bob.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.bob.address, value: ton("28.812") });
}

get fun `test partner: a partner bet on a price target works the same`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployHit(a, 200);
    val pb = partnerBet(market, a.alice, a.partner, true, ton("10"));
    expect(pb).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(pb).toHaveTx<PartnerPayout>({ from: market.address, to: a
            .partner
            .address, value: ton("0.3") });
    expect(
        bet(market, a.bob, false, ton("9.7")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(market.getMarketData().poolYes).toEqual(ton("9.7"));
    testing.setNow(T0 + 30);
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            200,
            T0 + 30,
            0xC1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // pot 19.4, fee 0.388, Alice takes 19.012
    val posA = positionOf(market, a.alice.address);
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("19.012") });
}

get fun `test predict: SweepHouse waits for the market's own claim window, then returns the remainder to the house`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    testing.setNow(RESOLVES);
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            200,
            RESOLVES,
            0xB2,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // before the window closes: refused
    expect(
        market.sendSweepHouse(a.house.address, 1, { value: ton("0.05") }),
    ).toHaveFailedTx<SweepHouse>({ to: market.address, exitCode: Errors.ClaimWindowOpen });
    // the winner claims in time
    val posA = positionOf(market, a.alice.address);
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("19.6") });
    // after the (7-day) window the remainder goes to the house — the deploy reserve comes back
    testing.setNow(RESOLVES + CLAIM_WINDOW);
    val sweep = market.sendSweepHouse(a.house.address, 2, { value: ton("0.05") });
    expect(sweep).toHaveSuccessfulTx<SweepHouse>({ to: market.address });
    expect(sweep).toHaveTx<HousePayout>({ from: market.address, to: a.house.address });
}

get fun `test predict: a claim before resolution bounces and can be retried`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    expect(
        market.sendLockOpen(
            a.oracle.address,
            1,
            100,
            T0,
            0xA1,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    // claim while unresolved: the market rejects ClaimPayout → it bounces, the position clears its in-flight flag
    val posA = positionOf(market, a.alice.address);
    val early = posA.sendClaim(a.alice.address, 1, { value: ton("0.1") });
    expect(early).toHaveFailedTx<ClaimPayout>({ to: market.address, exitCode: Errors.NotResolved });
    expect(posA.getBetPositionData().claiming).toBeFalse();

    // resolve, then the retry succeeds
    testing.setNow(RESOLVES);
    expect(
        market.sendResolve(
            a.oracle.address,
            1,
            200,
            RESOLVES,
            0xB2,
            { value: ton("0.1") },
        ),
    ).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(
        posA.sendClaim(a.alice.address, 2, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address });
    expect(posA.getBetPositionData().claimed).toBeTrue();
}

// ---------------------------------------------------------------------------
// Audit additions: value guards, caps, access control, rounding, late claims
// ---------------------------------------------------------------------------

get fun `test predict: value guards — gas only, below min, above max, pool cap (net stake is what counts)`() {
    val a = actors();
    testing.setNow(T0);
    // min 0.1, max 5 per bet, 8 in the whole market
    val market = deployLimited(a, ton("0.1"), ton("5"), ton("8"));
    lockOpen(market, a);

    // value == BET_GAS: nothing left to stake
    expect(
        market.sendPlaceBet(a.alice.address, 1, true, null, { value: BET_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.InsufficientValue });
    // partner route: value == BET_GAS + MARKET_GAS + PARTNER_GAS is refused the same way
    expect(
        market.sendPlaceBet(a.alice.address, 1, true, a.partner.address, { value: PARTNER_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.InsufficientValue });
    // a native-sized value (BET_GAS + MARKET_GAS) but naming a partner: also refused (kept > value)
    expect(
        market.sendPlaceBet(a.alice.address, 1, true, a.partner.address, { value: BET_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.InsufficientValue });
    // the old v1.0 native split (stake + BET_GAS only) now yields a stake short of MARKET_GAS: 0.1 - 0.005 < min 0.1
    expect(
        market.sendPlaceBet(a.alice.address, 1, true, null, { value: ton("0.1") + ton("0.02") }),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BetTooSmall });
    // stake 0.03 < min 0.1
    expect(
        bet(market, a.alice, true, ton("0.03")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BetTooSmall });
    // stake 6 > max 5
    expect(
        bet(market, a.alice, true, ton("6")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.BetTooLarge });
    // exactly max is fine
    expect(
        bet(market, a.alice, true, ton("5")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    // 5 + 4 = 9 > cap 8
    expect(
        bet(market, a.bob, false, ton("4")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.PoolCapReached });
    // 5 + 3 = 8 == cap: allowed
    expect(
        bet(market, a.bob, false, ton("3")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    // the cap is now full: even the minimum is refused
    expect(
        bet(market, a.bob, false, ton("0.1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.PoolCapReached });
    // a rejected bet leaves the pools untouched and nothing was recorded for it
    val st = market.getMarketState();
    expect(st.poolYes).toEqual(ton("5"));
    expect(st.poolNo).toEqual(ton("3"));
    // a rejected bettor's money bounced back to them: no position was ever deployed for a refused bet
    val stray = a.carol;
    expect(
        bet(market, stray, true, ton("1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.PoolCapReached });
    expect(
        testing.getAccountBalance(market.getPositionAddress(stray.address)) == 0,
    ).toBeTrue();
}

get fun `test predict: after resolution no bet is accepted; unknown opcodes bounce; empty top-ups are kept`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    lockOpen(market, a);
    expect(
        bet(market, a.alice, true, ton("1")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("1")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });

    // an unknown opcode is refused (0xFFFF) — nothing to parse, nothing to pool
    val junk = beginCell().storeUint(0x12345678, 32).storeUint(0, 64).endCell();
    expect(
        market.sendAny(a.alice.address, junk, { value: ton("0.1") }),
    ).toHaveFailedTx({ to: market.address, exitCode: 0xFFFF });
    // a plain transfer (empty body) is accepted as a reserve top-up
    val before = testing.getAccountBalance(market.address);
    expect(
        market.sendAny(a.alice.address, createEmptyCell(), { value: ton("0.5") }),
    ).toHaveTx({ to: market.address, success: true });
    expect(testing.getAccountBalance(market.address) > before + ton("0.49")).toBeTrue();

    expect(resolveAt(market, a, 200)).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // the up/down window is settled: a late bet is refused even though the clock is past closesAt anyway
    expect(
        bet(market, a.bob, false, ton("1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.AlreadyResolved });
    // and so is a partner bet
    expect(
        partnerBet(market, a.bob, a.partner, false, ton("1")),
    ).toHaveFailedTx<PlaceBet>({ to: market.address, exitCode: Errors.AlreadyResolved });
    // the oracle cannot lock the open price after the fact: a resolved market refuses LockOpen outright (v1.1)
    expect(
        market.sendLockOpen(a.oracle.address, 9, 100, T0 + 301, 0xA1, { value: ton("0.1") }),
    ).toHaveFailedTx<LockOpen>({ to: market.address, exitCode: Errors.AlreadyResolved });
}

get fun `test predict: oracle time windows — LockOpen and Resolve refuse prices published outside ±ORACLE_EPS`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    // published 301s before / after openAt: refused; exactly ±300 accepted
    expect(
        market.sendLockOpen(a.oracle.address, 1, 100, T0 - 301, 0xA1, { value: ton("0.1") }),
    ).toHaveFailedTx<LockOpen>({ to: market.address, exitCode: Errors.StaleOraclePrice });
    expect(
        market.sendLockOpen(a.oracle.address, 1, 100, T0 + 301, 0xA1, { value: ton("0.1") }),
    ).toHaveFailedTx<LockOpen>({ to: market.address, exitCode: Errors.StaleOraclePrice });
    expect(
        market.sendLockOpen(a.oracle.address, 1, 100, T0 - 300, 0xA1, { value: ton("0.1") }),
    ).toHaveSuccessfulTx<LockOpen>({ to: market.address });
    expect(market.getMarketData().proof!.openPublishTime).toEqual(T0 - 300);
    expect(
        bet(market, a.alice, true, ton("1")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("1")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    // resolve: publishTime must sit around resolvesAt, whatever the wall clock says
    testing.setNow(RESOLVES + 5000);
    expect(
        market.sendResolve(a.oracle.address, 1, 200, RESOLVES - 301, 0xB2, { value: ton("0.1") }),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.StaleOraclePrice });
    expect(
        market.sendResolve(a.oracle.address, 1, 200, RESOLVES + 301, 0xB2, { value: ton("0.1") }),
    ).toHaveFailedTx<Resolve>({ to: market.address, exitCode: Errors.StaleOraclePrice });
    expect(
        market.sendResolve(a.oracle.address, 1, 200, RESOLVES + 300, 0xB2, { value: ton("0.1") }),
    ).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(market.getMarketData().outcome).toEqual(OUTCOME_YES);
}

get fun `test predict: an up/down window whose open price was never locked resolves void; void and resolve exclude each other`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    // a second market (price target, bets placed now: the clock only moves forward) for the reverse order below
    val m2 = deployHit(a, 200);
    expect(bet(m2, a.alice, true, ton("1"))).toHaveSuccessfulTx<PlaceBet>({ to: m2.address });
    expect(bet(m2, a.bob, false, ton("1"))).toHaveSuccessfulTx<PlaceBet>({ to: m2.address });

    // no LockOpen ever: no bet could be placed, and the resolve is a void (no fee, nothing owed)
    val res = resolveAt(market, a, 200);
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(res).toNotHaveTx<HousePayout>({ from: market.address });
    val data = market.getMarketData();
    expect(data.outcome).toEqual(OUTCOME_VOID);
    expect(data.openSet).toBeFalse();
    // the close proof is still committed (open part is zero)
    expect(data.proof!.closeAttestation).toEqual(0xB2);
    expect(data.proof!.openAttestation).toEqual(0);
    // once resolved, ForceVoid is refused even after the grace
    testing.setNow(RESOLVES + VOID_GRACE);
    expect(
        market.sendForceVoid(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveFailedTx<ForceVoid>({ to: market.address, exitCode: Errors.AlreadyResolved });

    // and the other way round: a voided market cannot be resolved afterwards (the oracle is too late)
    val fv = m2.sendForceVoid(a.carol.address, 1, { value: ton("0.1") });
    expect(fv).toHaveSuccessfulTx<ForceVoid>({ to: m2.address });
    expect(fv).toNotHaveTx<HousePayout>({ from: m2.address });
    expect(m2.getMarketData().outcome).toEqual(OUTCOME_VOID);
    expect(
        m2.sendResolve(a.oracle.address, 2, 250, RESOLVES + VOID_GRACE, 0xC9, { value: ton("0.1") }),
    ).toHaveFailedTx<Resolve>({ to: m2.address, exitCode: Errors.AlreadyResolved });
    // nor can a late LockOpen land on a voided market (it never had an open price): storage stays untouched
    expect(
        m2.sendLockOpen(a.oracle.address, 3, 123, T0, 0xC8, { value: ton("0.1") }),
    ).toHaveFailedTx<LockOpen>({ to: m2.address, exitCode: Errors.AlreadyResolved });
    val voided = m2.getMarketData();
    expect(voided.openSet).toBeFalse();
    expect(voided.openPrice).toEqual(0);
    expect(voided.proof == null).toBeTrue();
    expect(voided.outcome).toEqual(OUTCOME_VOID);
    // both sides of the voided target get their stake back, to the nano
    expect(
        positionOf(m2, a.alice.address).sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: m2.address, to: a.alice.address, value: ton("1") });
    expect(
        positionOf(m2, a.bob.address).sendClaim(a.bob.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: m2.address, to: a.bob.address, value: ton("1") });
}

get fun `test predict: access control — only the owner starts a claim, only the real position is paid`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    lockOpen(market, a);
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(resolveAt(market, a, 200)).toHaveSuccessfulTx<Resolve>({ to: market.address });

    val posA = positionOf(market, a.alice.address);
    // Bob cannot trigger Alice's claim (the payout would go to Alice anyway, but the gas is hers to spend)
    expect(
        posA.sendClaim(a.bob.address, 1, { value: ton("0.1") }),
    ).toHaveFailedTx<Claim>({ to: posA.address, exitCode: Errors.NotFromOwner });
    // a claim without the gas budget is refused before anything is sent
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.02") }),
    ).toHaveFailedTx<Claim>({ to: posA.address, exitCode: Errors.InsufficientValue });
    expect(posA.getBetPositionData().claiming).toBeFalse();
    // a forged ClaimPayout sent straight to the market (inflated stakes) is refused: the sender is not the position
    expect(
        market.sendClaimPayout(a.alice.address, 1, a.alice.address, ton("1000"), 0, { value: ton("0.1") }),
    ).toHaveFailedTx<ClaimPayout>({ to: market.address, exitCode: Errors.NotFromPosition });
    // ... nor can Bob's wallet pose as Alice's position
    expect(
        market.sendClaimPayout(a.bob.address, 1, a.alice.address, ton("10"), 0, { value: ton("0.1") }),
    ).toHaveFailedTx<ClaimPayout>({ to: market.address, exitCode: Errors.NotFromPosition });
    // only the market may write a position: a stranger's RecordBet / ClaimAck are refused
    expect(
        posA.sendRecordBet(a.bob.address, 1, true, ton("1000"), { value: ton("0.05") }),
    ).toHaveFailedTx<RecordBet>({ to: posA.address, exitCode: Errors.NotFromMarket });
    expect(
        posA.sendClaimAck(a.alice.address, 1, { value: ton("0.05") }),
    ).toHaveFailedTx<ClaimAck>({ to: posA.address, exitCode: Errors.NotFromMarket });
    val pd = posA.getBetPositionData();
    expect(pd.yes).toEqual(ton("10"));
    expect(pd.claimed).toBeFalse();
    // the legitimate claim still pays the full 19.6
    expect(
        posA.sendClaim(a.alice.address, 2, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("19.6") });
}

get fun `test predict: rounding — floor per winner, fee + payouts never exceed the pot, dust stays for the sweep`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    lockOpen(market, a);
    // odd nano amounts so neither the fee nor the shares divide evenly
    val sA: coins = ton("1") + 3;
    val sC: coins = ton("2") + 1;
    val sB: coins = ton("7") + 7;
    expect(bet(market, a.alice, true, sA)).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(bet(market, a.carol, true, sC)).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(bet(market, a.bob, false, sB)).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    val poolYes: coins = sA + sC;
    val poolNo: coins = sB;
    val pot = poolYes + poolNo;
    expect(market.getMarketState().poolYes).toEqual(poolYes);

    val res = resolveAt(market, a, 200); // YES wins
    expect(res).toHaveSuccessfulTx<Resolve>({ to: market.address });
    val fee = houseFeeOf(OUTCOME_YES as uint8, 200, poolYes, poolNo);
    expect(fee).toEqual((pot * 200) / 10000);
    expect(res).toHaveTx<HousePayout>({ from: market.address, to: a.house.address, value: fee });

    val payA = payoutForPosition(OUTCOME_YES as uint8, 200, poolYes, poolNo, sA, 0);
    val payC = payoutForPosition(OUTCOME_YES as uint8, 200, poolYes, poolNo, sC, 0);
    // each share is floored: never above the exact pro-rata value
    expect(payA * poolYes <= sA * (pot - fee)).toBeTrue();
    expect(payC * poolYes <= sC * (pot - fee)).toBeTrue();
    // conservation: what leaves (fee + every payout) never exceeds the pot, dust < number of winners
    expect(payA + payC + fee <= pot).toBeTrue();
    expect(pot - (payA + payC + fee) < 2).toBeTrue();
    // a loser is owed nothing whatever the rounding
    expect(payoutForPosition(OUTCOME_YES as uint8, 200, poolYes, poolNo, 0, sB)).toEqual(0);

    // the contract pays exactly those amounts
    expect(
        positionOf(market, a.alice.address).sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: payA });
    expect(
        positionOf(market, a.carol.address).sendClaim(a.carol.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.carol.address, value: payC });
    val loser = positionOf(market, a.bob.address).sendClaim(a.bob.address, 1, { value: ton("0.1") });
    expect(loser).toNotHaveTx<WinPayout>({ from: market.address });
    expect(positionOf(market, a.bob.address).getBetPositionData().claimed).toBeTrue();
    // the dust (and the reserve) is still on the market, so it can never have paid more than it held
    expect(testing.getAccountBalance(market.address) >= pot - (payA + payC + fee)).toBeTrue();
}

get fun `test predict: a claim after the sweep bounces cleanly — the position is not locked and nothing else is lost`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    lockOpen(market, a);
    expect(
        bet(market, a.alice, true, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(
        bet(market, a.bob, false, ton("10")),
    ).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(resolveAt(market, a, 200)).toHaveSuccessfulTx<Resolve>({ to: market.address });
    // Alice (winner, owed 19.6) never claims; anyone may trigger the sweep once the window is over
    testing.setNow(RESOLVES + CLAIM_WINDOW);
    val sweep = market.sendSweepHouse(a.carol.address, 1, { value: ton("0.05") });
    expect(sweep).toHaveSuccessfulTx<SweepHouse>({ to: market.address });
    expect(sweep).toHaveTx<HousePayout>({ from: market.address, to: a.house.address });
    // MIN_STORAGE_RESERVE stays so the contract keeps answering
    val left = testing.getAccountBalance(market.address);
    expect(left <= ton("0.05")).toBeTrue();
    expect(left > 0).toBeTrue();
    // a second sweep only moves what arrived since (the caller's own value)
    expect(
        market.sendSweepHouse(a.carol.address, 2, { value: ton("0.05") }),
    ).toHaveSuccessfulTx<SweepHouse>({ to: market.address });

    // the late claim: the market cannot pay 19.6 any more → WinPayout fails, the whole tx bounces to the position
    val posA = positionOf(market, a.alice.address);
    val late = posA.sendClaim(a.alice.address, 1, { value: ton("0.1") });
    expect(late).toNotHaveTx<WinPayout>({ from: market.address });
    expect(late).toNotHaveTx<ClaimAck>({ from: market.address });
    val pd = posA.getBetPositionData();
    expect(pd.claimed).toBeFalse();
    expect(pd.claiming).toBeFalse(); // the bounce cleared the in-flight flag: no stuck position
    expect(pd.yes).toEqual(ton("10")); // and the stake record is intact
    // the loser can still settle (nothing owed, only the ack is needed)
    val posB = positionOf(market, a.bob.address);
    expect(
        posB.sendClaim(a.bob.address, 1, { value: ton("0.1") }),
    ).toHaveSuccessfulTx<ClaimPayout>({ from: posB.address, to: market.address });
    expect(posB.getBetPositionData().claimed).toBeTrue();
}

get fun `test predict: several bets by one wallet accumulate in one position; mixed YES/NO pays only the winning side`() {
    val a = actors();
    testing.setNow(T0);
    val market = deployMarket(a, 200);
    lockOpen(market, a);
    expect(bet(market, a.alice, true, ton("4"))).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(bet(market, a.alice, true, ton("6"))).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(bet(market, a.alice, false, ton("5"))).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(bet(market, a.bob, false, ton("15"))).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    val posA = positionOf(market, a.alice.address);
    val pd = posA.getBetPositionData();
    expect(pd.yes).toEqual(ton("10"));
    expect(pd.no).toEqual(ton("5"));
    expect(pd.market == market.address).toBeTrue();
    expect(pd.owner == a.alice.address).toBeTrue();
    // YES wins: pot 30, fee 0.6, Alice holds the whole YES pool → 29.4; her NO 5 is forfeited
    expect(resolveAt(market, a, 200)).toHaveSuccessfulTx<Resolve>({ to: market.address });
    expect(
        posA.sendClaim(a.alice.address, 1, { value: ton("0.1") }),
    ).toHaveTx<WinPayout>({ from: market.address, to: a.alice.address, value: ton("29.4") });
    // the position is one-shot for both sides at once
    expect(
        posA.sendClaim(a.alice.address, 2, { value: ton("0.1") }),
    ).toHaveFailedTx<Claim>({ to: posA.address, exitCode: Errors.AlreadyClaimed });
}

get fun `test partner: a disabled cut (partnerBps 0) pools the gross; self-partnering is harmless`() {
    val a = actors();
    testing.setNow(T0);
    // partnerBps is per market config: build one with 0
    val cfg = MarketConfig {
        oracle: a.oracle.address,
        house: a.house.address,
        asset: 0,
        cadence: 1,
        openAt: T0,
        closesAt: CLOSES,
        resolvesAt: RESOLVES,
        feeBps: 200,
        kind: KIND_UPDOWN,
        threshold: 0,
        partnerBps: 0,
        claimWindowSec: CLAIM_WINDOW,
        limits: MarketLimits { minBet: ton("0.1"), maxBet: 0, maxPool: 0 }.toCell(),
    };
    val market = Market.fromStorage({
        config: cfg.toCell(),
        poolYes: 0,
        poolNo: 0,
        openPrice: 0,
        closePrice: 0,
        openSet: false,
        resolved: false,
        outcome: 0,
        proof: null,
    });
    expect(
        market.deploy(a.house.address, { value: ton("1"), bounce: false }),
    ).toHaveSuccessfulDeploy({ to: market.address });
    lockOpen(market, a);
    // partner named, bps 0: no PartnerPayout, the gross joins the pool, the extra PARTNER_GAS simply stays in the market
    val pb = partnerBet(market, a.alice, a.partner, true, ton("10"));
    expect(pb).toHaveSuccessfulTx<PlaceBet>({ to: market.address });
    expect(pb).toNotHaveTx<PartnerPayout>({ from: market.address });
    expect(market.getMarketState().poolYes).toEqual(ton("10"));

    // on a 3% market, a bettor naming themself pays gas to get 3% of their own stake back: net 9.7 pooled
    val m3 = deployMarket(a, 200);
    lockOpen(m3, a);
    val selfie = partnerBet(m3, a.bob, a.bob, false, ton("10"));
    expect(selfie).toHaveSuccessfulTx<PlaceBet>({ to: m3.address });
    expect(selfie).toHaveTx<PartnerPayout>({ from: m3.address, to: a.bob.address, value: ton("0.3") });
    expect(m3.getMarketState().poolNo).toEqual(ton("9.7"));
    // the market itself is refused as a partner (the cut would never leave)
    expect(
        m3.sendPlaceBet(a.bob.address, 1, false, m3.address, { value: ton("1") + PARTNER_KEPT }),
    ).toHaveFailedTx<PlaceBet>({ to: m3.address, exitCode: Errors.BadPartner });
}
