struct CreatorFeeStorage {
    splitter: address
    /// DeDust payouts kept here until they reach `CREATOR_FEE_MIN`.
    accrued: coins
    /// Jetton master. The pool address is calcDedustPool(master, this contract).
    master: address
    /// The only address allowed to ask for a claim. Excess gas from the pool returns here.
    keeper: address
}

fun CreatorFeeStorage.load(): CreatorFeeStorage {
    return CreatorFeeStorage.fromCell(contract.getData());
}

fun CreatorFeeStorage.save(self) {
    contract.setData(self.toCell());
}
