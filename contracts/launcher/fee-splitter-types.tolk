// FeeSplitter(coin): immutable split of every TON fee earned by a launched coin.
// Shares are basis points and must sum to 10000. Dust from integer division goes to the protocol.

struct FeeSplits {
    holdersBps: uint16
    protocolBps: uint16
    potBps: uint16
    buybackBps: uint16
}

/// Fixed destinations (sub-cell: addresses do not fit the root cell).
struct FeeRoutes {
    protocol: address
    pot: address
    buyback: address
}

/// Holders destination + shares (sub-cell, rewritten on activation).
struct RewardRoute {
    /// RewardVault receiving the holders share. Null until wired.
    vault: address?
    splits: FeeSplits
}

struct FeeSplitterStorage {
    /// Factory (or protocol admin) allowed to wire the vault / activate the reward.
    admin: address
    /// While false the holders share is kept here (`locked`) — "Locked for pre-stocks".
    active: bool
    /// Holders TON kept until the reward is activated.
    locked: coins
    /// Fee TON received and not yet split (below `minSplit`).
    accrued: coins
    /// Lifetime fee TON received.
    totalIn: coins
    /// Minimum accrued TON before a split is executed (keeps 4 outgoing messages worth it).
    minSplit: coins
    routes: Cell<FeeRoutes>
    reward: Cell<RewardRoute>
}

fun FeeSplitterStorage.load(): FeeSplitterStorage {
    return FeeSplitterStorage.fromCell(contract.getData());
}

fun FeeSplitterStorage.save(self) {
    contract.setData(self.toCell());
}

struct FeeSplitterDataReply {
    admin: address
    active: bool
    locked: coins
    accrued: coins
    totalIn: coins
    minSplit: coins
    routes: FeeRoutes
    reward: RewardRoute
}
