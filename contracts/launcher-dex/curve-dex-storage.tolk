import "../launcher-v2/launcher-types"

// Same fields as CurveStorage, plus the DeDust creator. Empty creator: graduation stays PoolV2.
// Live CurveV2 keeps CurveStorage and does not import this file.

struct CurveDexExtra {
    /// CreatorFee of this coin. Empty means this curve still graduates into PoolV2.
    creator: address?
}

struct CurveDexStorage {
    state: uint8
    virtualTon: coins
    virtualToken: coins
    realTon: coins
    sold: coins
    pool: address?
    roles: Cell<CurveRoles>
    params: Cell<CurveParams>
    extra: Cell<CurveDexExtra>
}

fun CurveDexStorage.load(): CurveDexStorage {
    return CurveDexStorage.fromCell(contract.getData());
}

fun CurveDexStorage.save(self) {
    contract.setData(self.toCell());
}
