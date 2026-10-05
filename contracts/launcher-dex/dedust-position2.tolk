import "@stdlib/exotic-cells"
import "dedust-pool"

// Fixed DeDust position address, replacing calcDedustPosition (kept byte-intact for the deployed
// contracts). The real position contract stores fixedPrefixLength = 8 (formerly split_depth) in its
// own StateInit, which changes the StateInit hash; the address then takes its first 8 bits from the
// pool so both land in the same shard.
//
// Proven on mainnet with the DESTT rehearsal (2026-10-05):
//   pool     EQAEr6SN5RJegBjlC4CnX9rlc77o6n7ueGAXJr4Yt0L8sFuc
//   owner    EQCGXYxTIB9DeFaNcaFjjrbJMSIT10zv_UUxVmJfYn6NPisS   (the curve)
//   position EQAE3uQ3TxCuOINoy2OB6oQ3kdzyb65JiuNL7Nyj-lQqVyDK
// hash(StateInit with prefix 8) = 0xACDEE437... and the on-chain address replaces its first 8 bits
// with the pool's (0x04). The old calc missed the prefix bits inside the StateInit, so the curve
// asked a position address where no contract exists and the graduation could never confirm.

const DEDUST_POSITION_PREFIX_LEN: uint5 = 8

fun calcDedustPositionV2(pool: address, owner: address): address {
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
    val hash = StateInit.calcHashPrefixCodeData(DEDUST_POSITION_PREFIX_LEN, code, data);
    val sameShardAsHash = address.fromWorkchainAndHash(BASECHAIN, hash);
    return sameShardAsHash.calculateSameAddressInAnotherShard({
        fixedPrefixLength: DEDUST_POSITION_PREFIX_LEN,
        closeTo: pool,
    });
}
