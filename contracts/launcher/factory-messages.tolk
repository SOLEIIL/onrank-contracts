import "factory-types"
import "fee-splitter-types"

/// Creator -> Factory. `rewards` lists the reward jetton masters (0 = pending, 1 = single,
/// 2..5 = cycle). `firstBuyTon` is spent on the curve for the creator before anyone else can trade.
/// Value must cover launchFee + firstBuyTon + LAUNCH_GAS.
struct (0x46410001) CreateLaunch {
    queryId: uint64
    metadata: cell
    rewards: map<uint8, address>
    firstBuyTon: coins
    /// Admin only: fee split of this launch (used for $DESK: `{pot 5000, protocol 5000}`). Null = factory default.
    splits: FeeSplits?
}

struct (0x46410010) SetFactoryPaused {
    queryId: uint64
    paused: bool
}

struct (0x46410011) SetFactoryConfig {
    queryId: uint64
    config: Cell<FactoryConfig>
}

struct (0x46410012) SetFactoryRoles {
    queryId: uint64
    roles: Cell<FactoryRoles>
    routes: Cell<FactoryRoutes>
}

const EVENT_TOPIC_LAUNCH_CREATED = 0x4641E001

struct LaunchCreatedEvent {
    seq: uint64
    creator: address
    addresses: Cell<LaunchAddresses>
    rewardCount: uint8
    firstBuyTon: coins
}
