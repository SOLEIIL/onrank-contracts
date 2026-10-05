// Gas station for future FactoryDex coins. The live factory still pays the Ledger directly.

struct GasStationRoles {
    ledger: address
    keeper: address
    admin: address
}

struct GasStationParams {
    floatMax: coins
    pullAmount: coins
    factory: address?
}

struct GasRaise {
    floatMax: coins
    pullAmount: coins
    readyAt: uint32
}

struct GasStationStorage {
    roles: Cell<GasStationRoles>
    params: Cell<GasStationParams>
    paused: bool
    lastPullAt: uint32
    proposal: Cell<GasRaise>?
    creators: map<address, uint32>
}

struct GasStationData {
    ledger: address
    keeper: address
    admin: address
    factory: address?
    floatMax: coins
    pullAmount: coins
    paused: bool
    lastPullAt: uint32
}

const GAS_FLOAT_MAX = ton("30")
const GAS_PULL = ton("10")
const GAS_RESERVE = ton("0.05")
const GAS_MIN_SEND = ton("0.1")
const GAS_REFILL = ton("0.05")
const GAS_DAY = 86400
const GAS_DELAY = 172800

const OP_PULL_GAS = 0x43550040
const OP_REFILL_CREATOR = 0x43550041
const OP_SET_GAS_PAUSED = 0x43550042
const OP_SET_GAS_KEEPER = 0x43550043
const OP_SET_GAS_FACTORY = 0x43550044
const OP_PROPOSE_GAS_CAPS = 0x43550045
const OP_APPLY_GAS_CAPS = 0x43550046
const OP_LOWER_GAS_FLOAT = 0x43550047
const OP_LOWER_GAS_PULL = 0x43550048
const OP_REGISTER_CREATOR = 0x43550049

struct (0x43550040) PullGas {
    queryId: uint64
}

struct (0x43550041) RefillCreator {
    queryId: uint64
    creator: address
}

struct (0x43550042) SetGasPaused {
    queryId: uint64
    paused: bool
}

struct (0x43550043) SetGasKeeper {
    queryId: uint64
    keeper: address
}

struct (0x43550044) SetGasFactory {
    queryId: uint64
    factory: address
}

struct (0x43550045) ProposeGasCaps {
    queryId: uint64
    floatMax: coins
    pullAmount: coins
}

struct (0x43550046) ApplyGasCaps {
    queryId: uint64
}

struct (0x43550047) LowerGasFloat {
    queryId: uint64
    floatMax: coins
}

struct (0x43550048) LowerGasPull {
    queryId: uint64
    pullAmount: coins
}

struct (0x43550049) RegisterCreator {
    queryId: uint64
    creator: address
}
