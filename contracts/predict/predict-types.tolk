// Predict (parimutuel) storage + shared helpers. Mirrors the audited TS core in app/src/lib/predict/parimutuel.ts
// bit-for-bit: same fee, same pro-rata split, same refund rules, same rounding. A Market holds the two pools (the
// funds) and the outcome; a BetPosition is a deterministic child per (market, bettor) that authorises a trustless,
// single-use claim. No unbounded map anywhere (positions are separate contracts), so no gas/DoS growth.

// ---------------------------------------------------------------------------
// Outcome codes (root-cell scalar)
// ---------------------------------------------------------------------------
const OUTCOME_UNSET = 0
const OUTCOME_YES = 1
const OUTCOME_NO = 2
const OUTCOME_VOID = 3 // void OR one-sided (no counterparty): everyone refunded, house fee = 0

// ---------------------------------------------------------------------------
// Market kinds
// ---------------------------------------------------------------------------
/// Up/Down window: YES if close > open, NO if close < open, equal → void.
const KIND_UPDOWN = 0
/// Price target ("Will X hit $Y by D?"): YES the moment an attested price touches or crosses `threshold` (early
/// resolution allowed), NO if the deadline passes without a touch. No tie case.
const KIND_HIT = 1

// ---------------------------------------------------------------------------
// Market
// ---------------------------------------------------------------------------

/// Per-bet and per-market bounds (nanoGRAM). 0 = unlimited for maxBet / maxPool. Kept in a ref to keep MarketConfig
/// under the 1023-bit cell limit (two addresses already take ~534 bits).
struct MarketLimits {
    minBet: coins
    maxBet: coins
    maxPool: coins
}

/// Immutable market configuration, set once at deploy and never changed (kept in a ref cell). `house` is the owner's
/// payout wallet (the Ledger) — it cannot be redirected after creation.
struct MarketConfig {
    /// Only this address may lock the open price and resolve (keeper oracle relay, or a Pyth relay later).
    oracle: address
    /// Where the house fee (the only money the app earns) is sent at resolution. Immutable.
    house: address
    /// Identity/telemetry only (btc/eth/sol/gram, 1h/24h): the contract logic never branches on these.
    asset: uint8
    cadence: uint8
    /// Unix seconds. Bets accepted only while now < closesAt; resolution only once now >= resolvesAt.
    openAt: uint32
    closesAt: uint32
    resolvesAt: uint32
    /// House fee in basis points of the whole pot (200 = 2%).
    feeBps: uint16
    /// KIND_UPDOWN or KIND_HIT — the only config the resolution logic branches on.
    kind: uint8
    /// KIND_HIT: the price to touch (oracle scale, same as the prices posted). 0 for up/down.
    threshold: uint128
    /// Partner cut, bps of a bet placed through an integration (300 = 3%), taken off the stake on entry and paid
    /// to the partner right away; the net stake joins the common pool. 0 disables partner bets' surcharge.
    partnerBps: uint16
    /// Seconds after resolvesAt during which winners can claim; afterwards SweepHouse returns the remainder (dust,
    /// unclaimed payouts, the deploy reserve) to the house. Short windows for short markets keep the float small.
    claimWindowSec: uint32
    limits: Cell<MarketLimits>
}

/// Public audit trail of the oracle, committed on chain so anyone can verify the resolution against a signed source.
/// `attestation` = hash of the published price proof (e.g. the Pyth/Hermes signed update, or the multi-feed snapshot):
/// fetch the proof off chain, hash it, and it must equal this — the oracle cannot post a price it cannot prove.
struct MarketProof {
    openPublishTime: uint32
    closePublishTime: uint32
    openAttestation: uint256
    closeAttestation: uint256
}

struct MarketStorage {
    config: Cell<MarketConfig>
    poolYes: coins
    poolNo: coins
    /// Reference price locked at openAt (scale is the oracle's; only compared to closePrice, same scale).
    openPrice: uint128
    closePrice: uint128
    openSet: bool
    resolved: bool
    outcome: uint8
    /// Oracle audit trail (times + attestation hashes). Null until the open price is locked.
    proof: Cell<MarketProof>?
}

fun MarketStorage.load(): MarketStorage {
    return MarketStorage.fromCell(contract.getData());
}

fun MarketStorage.save(self) {
    contract.setData(self.toCell());
}

struct MarketDataReply {
    poolYes: coins
    poolNo: coins
    openPrice: uint128
    closePrice: uint128
    openSet: bool
    resolved: bool
    outcome: uint8
    config: MarketConfig
    proof: MarketProof?
}

/// Flat subset of the market data for RPC polling (every field a stack scalar).
struct MarketStateReply {
    poolYes: coins
    poolNo: coins
    openSet: bool
    resolved: bool
    outcome: uint8
}

/// True when one side has no stake: a lone bettor or an all-one-side market — no counterparty, so a full refund.
fun oneSided(poolYes: coins, poolNo: coins): bool {
    return poolYes == 0 || poolNo == 0;
}

/// Payout for a position holding (yes, no) on a resolved market. Refund (void/one-sided) returns everything staked;
/// otherwise the winning side is paid pro-rata of `distributable` and the losing side is forfeited. Floor division;
/// the tiny remainder stays in the pot and is swept to the house — the contract can never owe more than it holds.
fun payoutForPosition(
    outcome: uint8,
    feeBps: int,
    poolYes: coins,
    poolNo: coins,
    posYes: coins,
    posNo: coins,
): coins {
    if (outcome == OUTCOME_VOID || oneSided(poolYes, poolNo)) {
        return (posYes + posNo) as coins;
    }
    val winnerAmount = outcome == OUTCOME_YES ? posYes : posNo;
    if (winnerAmount == 0) {
        return 0;
    }
    val pot = poolYes + poolNo;
    // The fee is floored once on the whole pot, then each winner gets floor(share) of the remainder: the two divisions
    // are deliberate (the dust stays for the house sweep) and mirrored bit for bit by lib/predict/parimutuel.ts.
    val fee = (pot * feeBps) / 10000;
    val distributable = pot - fee;
    val winnerPool = outcome == OUTCOME_YES ? poolYes : poolNo;
    return ((winnerAmount * distributable) / winnerPool) as coins;
}

/// Partner cut on a gross stake placed through an integration: floor(gross * bps / 10000).
fun partnerFeeOf(gross: coins, partnerBps: int): coins {
    return ((gross * partnerBps) / 10000) as coins;
}

/// House fee sent to the Ledger at resolution: floor(pot*bps) on a decisive two-sided market, else 0.
fun houseFeeOf(outcome: uint8, feeBps: int, poolYes: coins, poolNo: coins): coins {
    if (outcome == OUTCOME_VOID || oneSided(poolYes, poolNo)) {
        return 0;
    }
    val pot = poolYes + poolNo;
    return ((pot * feeBps) / 10000) as coins;
}

// ---------------------------------------------------------------------------
// BetPosition (deterministic child per market + owner)
// ---------------------------------------------------------------------------

struct BetPositionStorage {
    market: address
    owner: address
    yes: coins
    no: coins
    claimed: bool
    /// A claim is waiting for the market's ClaimAck; blocks a second claim until settled or bounced.
    claiming: bool
}

fun BetPositionStorage.load(): BetPositionStorage {
    return BetPositionStorage.fromCell(contract.getData());
}

fun BetPositionStorage.save(self) {
    contract.setData(self.toCell());
}

struct BetPositionDataReply {
    market: address
    owner: address
    yes: coins
    no: coins
    claimed: bool
    claiming: bool
}

/// Deterministic address of a bettor's position. Init data is (market, owner) only — pools/flags start at zero — so
/// the address is fixed for the life of the position and the market can authenticate a claim by recomputing it.
fun calcDeployedBetPosition(market: address, owner: address, code: cell): AutoDeployAddress {
    val init: BetPositionStorage = {
        market,
        owner,
        yes: 0,
        no: 0,
        claimed: false,
        claiming: false,
    };
    return {
        workchain: BASECHAIN,
        stateInit: { code, data: init.toCell() },
        toShard: { fixedPrefixLength: 8, closeTo: owner },
    };
}

fun calcBetPositionAddress(market: address, owner: address, code: cell): address {
    return calcDeployedBetPosition(market, owner, code).calculateAddress();
}
