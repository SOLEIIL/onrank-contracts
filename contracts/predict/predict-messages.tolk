
// ---------------------------------------------------------------------------
// Market — public / bettor
// ---------------------------------------------------------------------------

/// Place a bet. The attached value minus BET_GAS + MARKET_GAS (+ PARTNER_GAS) is the gross stake; `isYes` picks the
/// side. Accepted only while the
/// betting window is open (now < closesAt) and, for up/down windows, once the open price is locked.
/// `partner` (an integration's wallet) makes it a partner bet: `partnerBps` of the gross stake is paid to that
/// address on the spot and only the net stake enters the pool. Null = native bet, no surcharge.
struct (0x50440001) PlaceBet {
    queryId: uint64
    isYes: bool
    partner: address?
}

// ---------------------------------------------------------------------------
// Market — oracle
// ---------------------------------------------------------------------------

/// Lock the reference (open) price. Only the oracle; only once; publishTime must sit around openAt. `attestation` is
/// the hash of the published price proof, committed so anyone can verify the number against a signed source.
struct (0x50440002) LockOpen {
    queryId: uint64
    price: uint128
    publishTime: uint32
    attestation: uint256
}

/// Resolve with a price. Up/down: only after resolvesAt, publishTime around resolvesAt; the contract derives the
/// outcome (strict up/down; equal → void). Hit target: accepted BEFORE resolvesAt only when price >= threshold (a
/// touch, publishTime around now) → YES; at/after resolvesAt: YES if price >= threshold, else NO. One-sided pools
/// are refunded either way. `attestation` is the hash of the published price proof.
struct (0x50440003) Resolve {
    queryId: uint64
    price: uint128
    publishTime: uint32
    attestation: uint256
}

/// Permissionless safety net: if the oracle never resolves, anyone can void the market (full refunds) after a grace.
struct (0x50440004) ForceVoid {
    queryId: uint64
}

/// Sweep leftover balance (rounding dust, unclaimed after the claim window) to the house wallet only.
struct (0x50440006) SweepHouse {
    queryId: uint64
}

// ---------------------------------------------------------------------------
// Market <-> BetPosition
// ---------------------------------------------------------------------------

/// Market -> position: record a bet (deploys the position on first use). Only the market sends this.
struct (0x50440010) RecordBet {
    queryId: uint64
    isYes: bool
    amount: coins
}

/// Position -> market: request the payout for (yes, no). The market authenticates by recomputing the position's
/// deterministic address from `owner`, so the reported stakes cannot be forged.
struct (0x50440005) ClaimPayout {
    queryId: uint64
    owner: address
    yes: coins
    no: coins
}

/// Market -> position: claim settled, mark it claimed (idempotent, one-shot).
struct (0x50440011) ClaimAck {
    queryId: uint64
}

/// Market -> house wallet (the Ledger): the house fee at resolution, and the dust sweep after the claim window.
struct (0x50440020) HousePayout {
    queryId: uint64
    amount: coins
}

/// Market -> winner: their parimutuel payout (or refund).
struct (0x50440021) WinPayout {
    queryId: uint64
    amount: coins
}

/// Market -> partner wallet: the integration's cut of a bet placed through it (paid at bet time).
struct (0x50440022) PartnerPayout {
    queryId: uint64
    amount: coins
}

/// Owner -> position: start a claim.
struct (0x50440012) Claim {
    queryId: uint64
}

/// Position -> owner: whatever exceeds POSITION_RESERVE after a RecordBet / ClaimAck (TEP-74 "excesses" opcode).
struct (0xd53276db) PositionExcess {
    queryId: uint64
}

// ---------------------------------------------------------------------------
// Events (external out messages; topic in destination)
// ---------------------------------------------------------------------------

const EVENT_TOPIC_BET_PLACED = 0x5044E001
const EVENT_TOPIC_MARKET_OPENED = 0x5044E002
const EVENT_TOPIC_MARKET_RESOLVED = 0x5044E003
const EVENT_TOPIC_HOUSE_PAID = 0x5044E004
const EVENT_TOPIC_CLAIMED = 0x5044E005

struct BetPlacedEvent {
    owner: address
    isYes: bool
    /// Net stake recorded in the pool (gross minus the partner cut).
    amount: coins
    poolYes: coins
    poolNo: coins
    /// Integration the bet came through and what it was paid (ref: keeps the root under 1023 bits). Null = native.
    partner: Cell<PartnerCut>?
}

struct PartnerCut {
    partner: address
    fee: coins
}

struct MarketOpenedEvent {
    openPrice: uint128
    publishTime: uint32
    attestation: uint256
}

struct MarketResolvedEvent {
    outcome: uint8
    openPrice: uint128
    closePrice: uint128
    poolYes: coins
    poolNo: coins
    fee: coins
    publishTime: uint32
    attestation: uint256
}

struct HousePaidEvent {
    amount: coins
    to: address
}

struct ClaimedEvent {
    owner: address
    payout: coins
}
