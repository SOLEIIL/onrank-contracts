import "@stdlib/exotic-cells"

// DeDust CPMM v2 wire format. The storage cell matches the library that tests load.
// baseFee is what the trader pays. creatorFeeBPS is a share of the LP bucket (80% of that
// base), not a fee added on top. 5000 is the maximum useful share: half of the 80%.

const DEDUST_POOL_V2_LIBRARY_HASH: uint256 = 0x6045e67b617e73486aac445cfcad0dbead6d315ccc8f4aede3f2e23ad14da4b0
const DEDUST_DEPOSIT_V2_LIBRARY_HASH: uint256 = 0x2cac3fddd30969d08df036067108c6e7d69780a9459d931d2eb63d95d5ff6825
const DEDUST_POSITION_V2_LIBRARY_HASH: uint256 = 0xdd82f24db614798ee7c579f8b3f07f0645d06d65cede368d80d0d74b180d2dd6

const DEDUST_BASE_FEE_BPS: uint16 = 10
/// Share of the LP bucket, in bps. The library does not add a fee on top of `baseFee`.
/// At 10 bps base, 5000 gives the creator 0.04% of volume. The trader still pays 0.1%.
const DEDUST_CREATOR_FEE_BPS: uint16 = 5000
const DEDUST_LOCKED_LP_SHARE: uint16 = 10000
/// Asset X is native. Fees are taken in that asset, so the creator fee arrives as GRAM.
const DEDUST_FEE_IN_NATIVE: uint2 = 0b01

const DEDUST_POOL_CONTROLLER: address = address("UQAzZk-YE-C_2TaxMzNi71upLfwLYBWRpWCK6M1vhbAOtJ5S")

struct (0xde8402ce) DedustInit {
    queryId: uint64
    customPayload: cell?
}

struct (0xc9a015da) DedustDepositPayload {
    amountX: coins
    amountY: coins
    minimalLiquidity: coins
    lockedLiquidityShare: uint16
}

/// Only the creator address stored in the pool may send this. `to` receives exactly creatorFeeX.
struct (0xbe3e3179) DedustClaimCreatorFees {
    queryId: uint64
    to: address
    excessesTo: address
}

struct (0xa5a7cbf8) DedustPayNative {
    queryId: uint64
    amount: coins
    paymentPayload: cell
    payoutConfig: cell
}

struct (0xce185bd7) DedustInitResult {
    queryId: uint64
    exitCode: int32
    customPayload: cell?
}

struct (0x63554160) DedustDepositNote {
    queryId: uint64
    liquidity: coins
    lockedLiquidity: coins
    payload: cell?
}

struct (0x52e659c0) DedustPositionState {
    queryId: uint64
    liquidity: coins
    lockedLiquidity: coins
    rest: RemainingBitsAndRefs
}

/// Factory -> CurveDex. Starts a DeDust deposit. Does not replace PoolV2 graduation.
struct (0x43550011) StartDedustDeposit {
    queryId: uint64
    creator: address
}

/// Factory -> CurveDex. Asks the position, after the pool has credited the deposit.
struct (0x43550012) ConfirmDedustDeposit {
    queryId: uint64
}

struct (0x9e0c2428) DedustProvidePosition {
    queryId: uint64
    includePoolAddress: bool
    includeOwnerAddress: bool
    includeFees: bool
    includeRewards: bool
}

/// Taken out of graduationFee. Liquidity GRAM is not used to pay these.
const DEDUST_INIT_GAS: coins = ton("0.5")
const DEDUST_NATIVE_GAS: coins = ton("0.15")
const DEDUST_MINT_VALUE: coins = ton("0.45")
const DEDUST_MINT_FORWARD: coins = ton("0.35")
const DEDUST_JETTON_FORWARD: coins = ton("0.2")
const DEDUST_JETTON_VALUE: coins = ton("0.3")

const CURVE_DEDUST_INIT: uint8 = 3
const CURVE_DEDUST_SENT: uint8 = 4

fun dedustGasFromFee(): coins {
    return DEDUST_INIT_GAS + DEDUST_NATIVE_GAS + DEDUST_MINT_VALUE;
}

fun dedustPayout(excessesTo: address): cell {
    return beginCell()
        .storeUint(0, 2)
        .storeCoins(0)
        .storeMaybeRef(null)
        .storeBool(false)
        .storeUint(0, 2)
        .storeCoins(0)
        .storeMaybeRef(null)
        .storeBool(false)
        .storeAddress(excessesTo)
        .endCell();
}

fun dedustDeposit(amountX: coins, amountY: coins): Cell<DedustDepositPayload> {
    return DedustDepositPayload {
        amountX,
        amountY,
        minimalLiquidity: 1,
        lockedLiquidityShare: DEDUST_LOCKED_LP_SHARE,
    }.toCell();
}

fun dedustPayJettonPayload(amountX: coins, amountY: coins, excessesTo: address): cell {
    return beginCell()
        .storeUint(0xcbc33949, 32)
        .storeRef(dedustDeposit(amountX, amountY))
        .storeRef(dedustPayout(excessesTo))
        .endCell();
}

fun isqrt(n: int): int {
    if (n <= 0) {
        return 0;
    }
    var x = n;
    var y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (n / x + x) / 2;
    }
    return x;
}

fun calcDedustPosition(pool: address, owner: address): address {
    val code = beginCell()
        .storeInt(ExoticCellType.LibraryReference, 8)
        .storeUint(DEDUST_POSITION_V2_LIBRARY_HASH, 256)
        .endCellSpecial();
    val fees = beginCell().storeUint(0, 26).endCell();
    val data = beginCell()
        .storeAddress(pool)
        .storeAddress(owner)
        .storeCoins(0)
        .storeCoins(0)
        .storeRef(fees)
        .storeMaybeRef(null)
        .endCell();
    val position: AutoDeployAddress = {
        workchain: 0,
        stateInit: { code, data },
        toShard: { fixedPrefixLength: 8, closeTo: pool },
    };
    return position.calculateAddress();
}

fun buildDedustPoolCode(): cell {
    return beginCell()
        .storeInt(ExoticCellType.LibraryReference, 8)
        .storeUint(DEDUST_POOL_V2_LIBRARY_HASH, 256)
        .endCellSpecial();
}

fun buildDedustPoolConfig(jettonMinter: address, creator: address): cell {
    return beginCell()
        .storeUint(0, 2)
        .storeAddress(jettonMinter)
        .storeAddress(creator)
        .storeUint(DEDUST_BASE_FEE_BPS, 16)
        .storeUint(DEDUST_CREATOR_FEE_BPS, 16)
        .storeBool(false)
        .storeBool(false)
        .storeUint(DEDUST_FEE_IN_NATIVE, 2)
        .storeBool(false)
        .storeBool(false)
        .endCell();
}

fun buildDedustPoolStorage(jettonMinter: address, creator: address): cell {
    val fees = beginCell()
        .storeCoins(0)
        .storeCoins(0)
        .storeCoins(0)
        .storeCoins(0)
        .storeUint(0, 5)
        .storeUint(0, 5)
        .endCell();
    val extra = beginCell()
        .storeAddress(DEDUST_POOL_CONTROLLER)
        .storeBool(false)
        .storeBool(false)
        .storeBool(false)
        .endCell();
    return beginCell()
        .storeRef(buildDedustPoolConfig(jettonMinter, creator))
        .storeRef(fees)
        .storeRef(extra)
        .storeBool(false)
        .storeUint(0, 2)
        .storeBool(false)
        .storeBool(false)
        .storeCoins(0)
        .storeCoins(0)
        .storeCoins(0)
        .endCell();
}

fun calcDedustPool(jettonMinter: address, creator: address): AutoDeployAddress {
    return {
        workchain: 0,
        stateInit: {
            code: buildDedustPoolCode(),
            data: buildDedustPoolStorage(jettonMinter, creator),
        },
    };
}
