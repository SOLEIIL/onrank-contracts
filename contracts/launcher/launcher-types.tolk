// Curve (bonding curve) and Pool (constant-product AMM) storage.

// ---------------------------------------------------------------------------
// Pool
// ---------------------------------------------------------------------------

struct PoolRoles {
    master: address
    splitter: address
    /// RewardWallet code: lets the pool derive its own coin wallet address.
    walletCode: cell
}

struct PoolStorage {
    reserveTon: coins
    reserveCoin: coins
    /// Share of every trade kept in the pool (locked liquidity grows forever).
    lpFeeBps: uint16
    /// Share of every trade sent to the FeeSplitter (perpetual creator fee).
    protocolFeeBps: uint16
    volumeTon: coins
    roles: Cell<PoolRoles>
}

fun PoolStorage.load(): PoolStorage {
    return PoolStorage.fromCell(contract.getData());
}

fun PoolStorage.save(self) {
    contract.setData(self.toCell());
}

struct PoolDataReply {
    reserveTon: coins
    reserveCoin: coins
    lpFeeBps: int
    protocolFeeBps: int
    volumeTon: coins
    master: address
    splitter: address
    coinWallet: address
}

struct Quote {
    amountOut: coins
    fee: coins
}

// ---------------------------------------------------------------------------
// Curve
// ---------------------------------------------------------------------------

const CURVE_INIT = 0
const CURVE_OPEN = 1
const CURVE_GRADUATED = 2

struct CurveRoles {
    factory: address
    master: address
    splitter: address
}

struct CurveParams {
    /// Receives the graduation fee (minus gas).
    protocol: address
    /// Trade fee (bps of the TON side) sent to the FeeSplitter.
    feeBps: uint16
    /// Coins sold through the curve before graduation.
    curveSupply: coins
    /// Coins minted to the Pool at graduation.
    poolSupply: coins
    /// Real TON collected that triggers graduation (the curve also graduates when sold out).
    graduationTon: coins
    /// Taken from the collected TON at graduation: covers pool deployment gas, rest to protocol.
    graduationFee: coins
    /// Smallest TON amount accepted for a buy.
    minBuy: coins
    /// Pool fee parameters passed at deployment.
    poolLpFeeBps: uint16
    poolProtocolFeeBps: uint16
    walletCode: cell
}

struct CurveStorage {
    state: uint8
    /// Virtual reserves (x·y = k). Real TON is a subset of `virtualTon`.
    virtualTon: coins
    virtualToken: coins
    realTon: coins
    sold: coins
    pool: address?
    roles: Cell<CurveRoles>
    params: Cell<CurveParams>
}

fun CurveStorage.load(): CurveStorage {
    return CurveStorage.fromCell(contract.getData());
}

fun CurveStorage.save(self) {
    contract.setData(self.toCell());
}

struct CurveDataReply {
    state: int
    virtualTon: coins
    virtualToken: coins
    realTon: coins
    sold: coins
    pool: address?
    roles: CurveRoles
    params: CurveParams
}
