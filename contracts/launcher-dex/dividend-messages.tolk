// Future factory only. Live v2 contracts do not accept these messages.

/// Factory -> Curve. The curve tells the master that `owner` earns no dividends.
struct (0x43550010) ExcludeFromDividends {
    queryId: uint64
    owner: address
}

/// Curve -> Master. This owner earns nothing. Only the curve may send it, and only once.
struct (0x52570041) SetDividendExcluded {
    queryId: uint64
    owner: address
}

/// Excluded wallet -> Master. Its balance after the movement that just landed.
struct (0x52570040) ExcludedBalance {
    queryId: uint64
    owner: address
    balance: coins
}

/// Master -> excluded wallet. Stamps jump to the current indices and accrued is cleared.
struct (0x52570042) MarkExcluded {
    queryId: uint64
    indices: map<uint8, uint128>
}
