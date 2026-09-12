// Reward-bearing jetton (TEP-74 + TEP-89 compatible) with on-chain dividend indices.
//
// The master is the hub: it holds one cumulative index per reward id (up to MAX_REWARDS),
// bumps it when the RewardVault receives reward jettons, and settles wallets on demand.
// Every wallet keeps `stamps[id]` (index at last sync) and `accrued[id]` (reward already
// earned, not yet claimed). Before a transfer or a burn the wallet syncs with the master so
// that the sender's position is frozen at the current index; the recipient receives the same
// indices inside the transfer step and freezes its own position before adding the tokens.
//
// Payout for a reward id = accrued[id] + balance * (index[id] - stamps[id]) / INDEX_SCALE.

/// Fixed point scale of reward indices (reward units per token unit).
const INDEX_SCALE = 1000000000000

/// Maximum reward ids per coin (single reward = 1, cycle = 2..5).
const MAX_REWARDS = 5

// ---------------------------------------------------------------------------
// Master
// ---------------------------------------------------------------------------

struct RewardMasterRoles {
    factory: address
    /// Launch sequence number: makes the master address unique per launch.
    seq: uint64
    /// Only the Curve may mint (and it is the only party that learns of burns for selling).
    curve: address?
    /// Only the RewardVault may bump indices / receive payout orders.
    vault: address?
}

struct RewardMasterStorage {
    totalSupply: coins
    /// Coin held by the Pool (never earns rewards).
    excluded: coins
    /// True while the bonding curve accepts sells.
    curveOpen: bool
    /// Pool (set at graduation): its wallet is excluded from rewards and reports `excluded`.
    pool: address?
    roles: Cell<RewardMasterRoles>
    indices: map<uint8, uint128>
    /// rewardId -> scaled units not yet reflected in the index (`< circulating`), carried to the next bump.
    remainders: map<uint8, coins>
    metadata: cell
}

fun RewardMasterStorage.load(): RewardMasterStorage {
    return RewardMasterStorage.fromCell(contract.getData());
}

fun RewardMasterStorage.save(self) {
    contract.setData(self.toCell());
}

struct RewardMasterDataReply {
    totalSupply: coins
    excluded: coins
    curveOpen: bool
    pool: address?
    roles: RewardMasterRoles
    indices: map<uint8, uint128>
    remainders: map<uint8, coins>
}

// ---------------------------------------------------------------------------
// Wallet
// ---------------------------------------------------------------------------

/// What the wallet does once the master has answered its sync.
const ACTION_SYNC = 0
const ACTION_CLAIM = 1
const ACTION_BURN = 2

struct PendingTransfer {
    queryId: uint64
    amount: coins
    recipient: address
    sendExcessesTo: address?
    forwardTonAmount: coins
    forwardPayload: cell
}

/// Operation waiting for the master's SettleAck. Snapshots let a claim be reconciled exactly.
struct PendingOp {
    action: uint8
    amount: coins
    balanceAtSend: coins
    transfer: Cell<PendingTransfer>?
    stampsAtSend: map<uint8, uint128>
    accruedAtSend: map<uint8, coins>
}

struct RewardWalletStorage {
    balance: coins
    owner: address
    master: address
    stamps: map<uint8, uint128>
    accrued: map<uint8, coins>
    /// Operation in flight (transfer, claim or burn). Blocks any other action while set.
    pending: Cell<PendingOp>?
}

fun RewardWalletStorage.load(): RewardWalletStorage {
    return RewardWalletStorage.fromCell(contract.getData());
}

fun RewardWalletStorage.save(self) {
    contract.setData(self.toCell());
}

struct RewardWalletDataReply {
    balance: coins
    owner: address
    master: address
    stamps: map<uint8, uint128>
    accrued: map<uint8, coins>
    busy: bool
}

fun calcDeployedRewardWallet(owner: address, master: address, walletCode: cell): AutoDeployAddress {
    val init: RewardWalletStorage = {
        balance: 0,
        owner,
        master,
        stamps: createEmptyMap(),
        accrued: createEmptyMap(),
        pending: null,
    };
    return {
        workchain: BASECHAIN,
        stateInit: { code: walletCode, data: init.toCell() },
        toShard: { fixedPrefixLength: 8, closeTo: owner },
    };
}

fun calcRewardWalletAddress(owner: address, master: address, walletCode: cell): address {
    return calcDeployedRewardWallet(owner, master, walletCode).calculateAddress();
}

fun indexOf(m: map<uint8, uint128>, id: uint8): int {
    val found = m.get(id);
    return found.isFound ? (found.loadValue() as int) : 0;
}

fun amountOf(m: map<uint8, coins>, id: uint8): int {
    val found = m.get(id);
    return found.isFound ? (found.loadValue() as int) : 0;
}

/// Reward owed for one id given a position (balance, stamp, accrued) and the current index.
fun owedFor(balance: coins, index: int, stamp: int, accrued: int): int {
    return index > stamp ? accrued + (balance * (index - stamp)) / INDEX_SCALE : accrued;
}

/// Freezes the wallet position at `indices`: earned rewards move into `accrued`, stamps advance.
fun RewardWalletStorage.freezeAt(mutate self, indices: map<uint8, uint128>) {
    var r = indices.findFirst();
    while (r.isFound) {
        val id = r.getKey();
        val index = r.loadValue() as int;
        val stamp = indexOf(self.stamps, id);
        if (index > stamp) {
            if (self.balance > 0) {
                val earned = (self.balance * (index - stamp)) / INDEX_SCALE;
                self.accrued.set(id, (amountOf(self.accrued, id) + earned) as coins);
            }
            self.stamps.set(id, index as uint128);
        }
        r = indices.iterateNext(r);
    }
}

/// Merges an incoming lot of `amount` coins whose position was frozen at `indices` (the sender's
/// settle snapshot). Two cases per reward: the snapshot is ahead of us -> freeze our balance up to
/// it; we are ahead of the snapshot (an index bump landed while the lot was in flight) -> the lot
/// earned `amount * (stamp - snapshot)` that nobody else holds, credit it here.
fun RewardWalletStorage.receiveLot(mutate self, amount: coins, indices: map<uint8, uint128>) {
    self.freezeAt(indices);
    var r = indices.findFirst();
    while (r.isFound) {
        val id = r.getKey();
        val snapshot = r.loadValue() as int;
        val stamp = indexOf(self.stamps, id);
        if (stamp > snapshot) {
            val earned = (amount * (stamp - snapshot)) / INDEX_SCALE;
            self.accrued.set(id, (amountOf(self.accrued, id) + earned) as coins);
        }
        r = indices.iterateNext(r);
    }
    self.balance += amount;
}

// ---------------------------------------------------------------------------
// Vault
// ---------------------------------------------------------------------------

struct RewardVaultRoles {
    admin: address
    keeper: address
    master: address
}

struct RewardSlot {
    /// Jetton master of the reward asset.
    rewardMaster: address
    /// The vault's own wallet for that asset, discovered through TEP-89 (null until answered).
    vaultWallet: address?
    /// Reward received while nobody could earn it (circulating == 0); folded into the next bump.
    carry: coins
    /// Reward paid out so far.
    paid: coins
}

struct VaultPending {
    rewardId: uint8
    spend: coins
    minOut: coins
    startedAt: uint32
}

struct RewardVaultStorage {
    rewardCount: uint8
    cycleNext: uint8
    totalTonIn: coins
    totalTonSpent: coins
    reserve: coins
    pendingTimeout: uint32
    roles: Cell<RewardVaultRoles>
    rewards: map<uint8, RewardSlot>
    /// DeDust native vault (only TON destination) and pools a ConvertReward may route through.
    dexVault: address
    dexPools: map<address, bool>
    pending: Cell<VaultPending>?
}

fun RewardVaultStorage.load(): RewardVaultStorage {
    return RewardVaultStorage.fromCell(contract.getData());
}

fun RewardVaultStorage.save(self) {
    contract.setData(self.toCell());
}

struct RewardVaultDataReply {
    rewardCount: int
    cycleNext: int
    totalTonIn: coins
    totalTonSpent: coins
    reserve: coins
    roles: RewardVaultRoles
    rewards: map<uint8, RewardSlot>
    pending: VaultPending?
}
