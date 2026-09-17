// Predict — end-to-end rehearsal in emulation (no --net): deploys one up/down window and one price target with the
// keeper wallet as oracle and the protocol wallet as house, then runs the whole life of both: native and partner bets,
// a touch on the target (early YES), the window's resolve, the house fee and partner cut landing, winners claiming.
// Prints every address so the TypeScript side (chain-config.ts / onchain.ts) can be checked against the same config.
//
//   acton run predict-emul
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/emulation/testing"

import "@wrappers/BetPosition.gen"
import "@wrappers/Market.gen"
import "@contracts/predict/predict-messages"
import "@contracts/predict/predict-types"
import "deploy-config"

const OPEN: uint32 = 1800000000
const HOUR: uint32 = 3600
/// Mirror of Market.BET_GAS + MARKET_GAS (+ PARTNER_GAS): what a bet leaves in the market on top of the gross stake.
const NATIVE_KEPT = ton("0.025")
const PARTNER_KEPT = ton("0.03")

fun ok(name: string, r: SendResultList) {
    val trace = r.waitForTrace();
    assert (trace != null) throw 3001;
    println("ok  {}", name);
}

fun marketOf(
    oracle: address,
    house: address,
    kind: uint8,
    threshold: uint128,
    openAt: uint32,
    closesAt: uint32,
    resolvesAt: uint32,
): Market {
    val cfg = MarketConfig {
        oracle,
        house,
        asset: kind == KIND_HIT ? 3 : 0, // gram / btc (telemetry)
        cadence: kind == KIND_HIT ? 255 : 0,
        openAt,
        closesAt,
        resolvesAt,
        feeBps: 200,
        kind,
        threshold,
        partnerBps: 300,
        claimWindowSec: 7 * 86400,
        limits: MarketLimits {
            minBet: ton("0.1"),
            maxBet: 0,
            maxPool: 0,
        }.toCell(),
    };
    return Market.fromStorage({
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
}

fun main() {
    assert (
        !net.isBroadcasting()
    ) throw 3000;                              // emulation only: real markets are deployed by the app keeper
    val oracle = scripts.wallet(WALLET_KEEPER);
    val house = scripts.wallet(WALLET_PROTOCOL);
    val alice = testing.treasury("alice");
    val bob = testing.treasury("bob");
    val partner = testing.treasury("partner-app");
    testing.setNow(OPEN);

    // --- up/down: deploy + LockOpen in one message (the keeper's predict_open) -------------------------------
    val window = marketOf(
        oracle.address,
        house.address,
        KIND_UPDOWN,
        0,
        OPEN,
        OPEN + HOUR,
        OPEN + HOUR,
    );
    ok(
        "window deploy+lock",
        net.send(
            oracle.address,
            createMessage({
                bounce: false,
                value: ton("1.1"),
                dest: { stateInit: window.stateInit! },
                body: LockOpen {
                    queryId: 1,
                    price: 6500000000000,
                    publishTime: OPEN,
                    attestation: 0xA1,
                },
            }),
        ),
    );
    println("window market {} (oracle {} house {})", window.address, oracle.address, house.address);
    ok(
        "alice UP 10 (native)",
        window.sendPlaceBet(alice.address, 1, true, null, { value: ton("10") + NATIVE_KEPT }),
    );
    ok(
        "bob DOWN 20 (via partner)",
        window.sendPlaceBet(bob.address, 1, false, partner.address, { value: ton("20") + PARTNER_KEPT }),
    );
    val ws = window.getMarketState();
    println("window pools yes={} no={} (partner cut 0.6 already paid)", ws.poolYes, ws.poolNo);
    assert (ws.poolNo == ton("19.4")) throw 3010;

    // --- price target: deploy bare, bets, then a touch resolves it early ------------------------------------
    val target = marketOf(
        oracle.address,
        house.address,
        KIND_HIT,
        200000000,
        OPEN,
        OPEN + 30 * 86400,
        OPEN + 30 * 86400,
    );
    ok("target deploy", target.deploy(oracle.address, { value: ton("1"), bounce: false }));
    println("target market {}", target.address);
    ok(
        "alice YES 5 (via partner)",
        target.sendPlaceBet(alice.address, 2, true, partner.address, { value: ton("5") + PARTNER_KEPT }),
    );
    ok(
        "bob NO 5 (native)",
        target.sendPlaceBet(bob.address, 2, false, null, { value: ton("5") + NATIVE_KEPT }),
    );
    testing.setNow(OPEN + 600);
    val early = target.sendResolve(
        oracle.address,
        3,
        199000000,
        OPEN + 600,
        0xC0,
        { value: ton("0.1") },
    );
    assert (early.waitForTrace() != null) throw 3011;
    assert (
        !target.getMarketState().resolved
    ) throw 3012;                                          // under the target: refused (TargetNotReached)
    ok(
        "touch → YES",
        target.sendResolve(
            oracle.address,
            4,
            200000000,
            OPEN + 600,
            0xC1,
            { value: ton("0.1") },
        ),
    );
    assert (target.getMarketState().outcome == OUTCOME_YES) throw 3013;
    val posAliceT = BetPosition.fromAddress(target.getPositionAddress(alice.address));
    ok("alice claims target", posAliceT.sendClaim(alice.address, 1, { value: ton("0.1") }));
    assert (posAliceT.getBetPositionData().claimed) throw 3014;

    // --- window resolves at its hour ----------------------------------------------------------------------
    testing.setNow(OPEN + HOUR);
    ok(
        "window resolve DOWN",
        window.sendResolve(
            oracle.address,
            5,
            6400000000000,
            OPEN + HOUR,
            0xB2,
            { value: ton("0.1") },
        ),
    );
    assert (window.getMarketState().outcome == OUTCOME_NO) throw 3020;
    val posBob = BetPosition.fromAddress(window.getPositionAddress(bob.address));
    ok("bob claims window", posBob.sendClaim(bob.address, 1, { value: ton("0.1") }));
    assert (posBob.getBetPositionData().claimed) throw 3021;
    println("predict emulation complete");
}
