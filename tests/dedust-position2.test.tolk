// calcDedustPositionV2 must reproduce the position DeDust really deployed for DESTT (mainnet,
// 2026-10-05). These three addresses are chain facts, not fixtures: the pool and curve exist, and
// the position is the contract that credited the deposit and answered only with Excesses.
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/launcher-dex/dedust-pool"
import "@contracts/launcher-dex/dedust-position2"

const DESTT_POOL: address = address("EQAEr6SN5RJegBjlC4CnX9rlc77o6n7ueGAXJr4Yt0L8sFuc")
const DESTT_CURVE: address = address("EQCGXYxTIB9DeFaNcaFjjrbJMSIT10zv_UUxVmJfYn6NPisS")
const DESTT_POSITION: address = address("EQAE3uQ3TxCuOINoy2OB6oQ3kdzyb65JiuNL7Nyj-lQqVyDK")

get fun `test dedust position2: the fixed calc lands on the real DESTT position`() {
    expect(calcDedustPositionV2(DESTT_POOL, DESTT_CURVE)).toEqual(DESTT_POSITION);
}

// Established while fixing DESTT: under acton 1.2.0 the old calc (AutoDeployAddress + toShard)
// already produced the right address, so the deployed DESTT curve pointed at the real position all
// along. The freeze had a single cause: no contract could send it ConfirmDedustDeposit. V2 keeps
// the explicit construction because it is proven against the chain fact rather than a stdlib detail.
get fun `test dedust position2: old and new calc agree (the freeze was only the missing relay)`() {
    expect(calcDedustPosition(DESTT_POOL, DESTT_CURVE)).toEqual(DESTT_POSITION);
    expect(calcDedustPosition(DESTT_POOL, DESTT_CURVE)).toEqual(
        calcDedustPositionV2(DESTT_POOL, DESTT_CURVE),
    );
}

get fun `test dedust position2: the first 8 bits come from the pool`() {
    val owner = testing.treasury("position2-owner");
    val position = calcDedustPositionV2(DESTT_POOL, owner.address);
    val (wc, hash) = position.getWorkchainAndHash();
    val (poolWc, poolHash) = DESTT_POOL.getWorkchainAndHash();
    expect(wc).toEqual(poolWc);
    expect(hash >> 248).toEqual(poolHash >> 248);
}
