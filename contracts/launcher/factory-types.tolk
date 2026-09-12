// Factory: deploys one coin (RewardMaster + RewardVault + FeeSplitter + Curve) per launch.
import "fee-splitter-types"

struct FactoryRoles {
    admin: address
    /// Keeper of every RewardVault created (bounded conversions).
    keeper: address
    /// Protocol treasury: launch fees, graduation fees, 15 % of coin fees.
    protocol: address
}

struct FactoryRoutes {
    pot: address
    buyback: address
}

struct CurveDefaults {
    feeBps: uint16
    curveSupply: coins
    poolSupply: coins
    graduationTon: coins
    graduationFee: coins
    minBuy: coins
    poolLpFeeBps: uint16
    poolProtocolFeeBps: uint16
    virtualTon0: coins
    virtualToken0: coins
}

struct FactoryConfig {
    /// Fixed fee paid to the protocol per launch.
    launchFee: coins
    /// TON kept by each RewardVault (storage + gas headroom).
    vaultReserve: coins
    vaultPendingTimeout: uint32
    /// Minimum accrued fee before a FeeSplitter splits.
    minSplit: coins
    splits: FeeSplits
    curve: Cell<CurveDefaults>
    /// DeDust native vault + pools whitelisted for every RewardVault (swap bodies are built on-chain).
    dexVault: address
    dexPools: map<address, bool>
}

/// Codes of the deployed contracts (4 refs) + the RewardWallet code the Curve hands to the Pool.
struct FactoryCodes {
    master: cell
    vault: cell
    splitter: cell
    more: Cell<FactoryCodesMore>
}

struct FactoryCodesMore {
    curve: cell
    wallet: cell
}

struct FactoryStorage {
    seq: uint64
    paused: bool
    roles: Cell<FactoryRoles>
    routes: Cell<FactoryRoutes>
    config: Cell<FactoryConfig>
    codes: Cell<FactoryCodes>
}

fun FactoryStorage.load(): FactoryStorage {
    return FactoryStorage.fromCell(contract.getData());
}

fun FactoryStorage.save(self) {
    contract.setData(self.toCell());
}

struct FactoryDataReply {
    seq: int
    paused: bool
    roles: FactoryRoles
    routes: FactoryRoutes
    config: FactoryConfig
}

/// Addresses of the four contracts of launch `seq`.
struct LaunchAddresses {
    master: address
    vault: address
    more: Cell<LaunchAddressesMore>
}

struct LaunchAddressesMore {
    splitter: address
    curve: address
}
