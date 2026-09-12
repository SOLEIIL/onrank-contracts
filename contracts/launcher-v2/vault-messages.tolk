// RewardVault v2 operations (keeper / admin). Opcodes shared with v1 keep their layouts.

/// Keeper -> Vault. Swap `spend` TON for reward `rewardId` through a whitelisted DeDust pool.
/// The swap body is built by the vault (receiver = vault, limit = `minOut`).
struct (0x52570020) ConvertReward {
    queryId: uint64
    rewardId: uint8
    pool: address
    spend: coins
    minOut: coins
}

struct (0x52570021) CancelVaultPending {
    queryId: uint64
}

/// Admin -> Vault. The vault discovers its own wallet for that jetton (TEP-89).
struct (0x52570022) AddReward {
    queryId: uint64
    rewardId: uint8
    rewardMaster: address
}

/// Admin -> Vault. Propose a change, applicable after VAULT_DELAY (48 h): the TON waiting in a vault can only be routed
/// through whitelisted pools by the keeper, so both the whitelist and the roles sit behind the same delay as the
/// Factory's (audit 3, SEC-202). `kind` = VAULT_PROPOSAL_DEX (payload: VaultDexChange) or VAULT_PROPOSAL_ROLES
/// (payload: VaultRolesChange). A new proposal replaces the pending one (its delay restarts).
struct (0x52570023) ProposeVaultChange {
    queryId: uint64
    kind: uint8
    payload: cell
}

/// Admin -> Vault. Apply the pending proposal once its delay has passed.
struct (0x52570024) ApplyVaultChange {
    queryId: uint64
}

struct VaultDexChange {
    pool: address
    allowed: bool
}

/// The master is not part of a roles change: a vault serves one coin for life.
struct VaultRolesChange {
    admin: address
    keeper: address
}

/// Admin or keeper -> Vault. Ask again for the wallets not discovered yet (value covers each request).
struct (0x52570025) Rediscover {
    queryId: uint64
}

/// Governance of one vault: proposal (applied = false) and application (applied = true).
const EVENT_TOPIC_VAULT_CHANGED = 0x5257E005

struct VaultChangedEvent {
    kind: uint8
    applied: bool
    readyAt: uint32
}
