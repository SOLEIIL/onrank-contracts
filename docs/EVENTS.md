# ONRANK on-chain events

Every ONRANK contract reports what it did with an **external out-message** ("log"): destination = a 256-bit value whose
top byte is 0 and whose low 248 bits are the topic below; body = the fields in order (TL-B, no opcode). Decode only
events emitted by accounts whose code hash is listed in [README.md § 2](./README.md#2-contracts-mainnet).

Reference decoder: `decodeTradeEvent` in `@onrank/sdk` (trading events) — the app's full decoder covers every topic below. Topics are grouped by contract family. Prediction markets (`Market` / `BetPosition`) are in their own section further down.

## Launcher (Factory, Curve, Pool, FeeSplitter, RewardMaster/Vault)

| Topic | Emitter | Name | Body |
|---|---|---|---|
| `0x4641e001` | FactoryV2 | LaunchCreated | `seq:uint64 creator:addr ^[master:addr vault:addr ^[splitter:addr curve:addr]] rewardCount:uint8 firstBuyTon:coins codeVersion:uint16 preminted:coins` |
| `0x4355e001` | CurveV2 | CurveTrade | `isBuy:bit trader:addr ton:coins coin:coins fee:coins virtualTon:coins virtualToken:coins realTon:coins` |
| `0x4355e002` | CurveV2 | CurveGraduated | `pool:addr liquidityTon:coins liquidityCoin:coins protocolFee:coins` |
| `0x504fe001` | PoolV2 | PoolSwap | `isBuy:bit trader:addr ton:coins coin:coins lpFee:coins protocolFee:coins reserveTon:coins reserveCoin:coins` |
| `0x504fe002` | PoolV2 | PoolRefund | `nonce:uint64 coin:coins ton:coins refunded:bit` |
| `0x4653e001` | FeeSplitterV2 | FeeSplit | `amount:coins holders:coins protocol:coins pot:coins buyback:coins lockedHolders:bit` |
| `0x4653e002` | FeeSplitterV2 | SplitsChanged | `holdersBps:uint16 protocolBps:uint16 potBps:uint16 buybackBps:uint16 applied:bit readyAt:uint32` |
| `0x4641e002` | FactoryV2 | FactoryChanged | `changeKind:uint8 applied:bit readyAt:uint32` |
| `0x5257e001` | RewardVaultV2 | IndexBumped | `rewardId:uint8 amount:coins circulating:coins index:uint128` |
| `0x5257e002` | RewardMasterV2 | RewardPaid | `owner:addr rewardId:uint8 amount:coins` |
| `0x5257e003` | RewardVaultV2 | RewardConverted | `rewardId:uint8 spendTon:coins received:coins minOut:coins` |
| `0x5257e005` | RewardVaultV2 | VaultChanged | `changeKind:uint8 applied:bit readyAt:uint32` |
| `0x4242e001` | BuybackVault | Buyback | `queryId:uint64 tonSpent:coins burned:coins` |

Semantics that matter for a trading integration:

- **CurveTrade.ton** is net of the fee in both directions: for a buy, what entered the curve's reserve; for a sell,
  what the seller received. The gross TON side is `ton + fee`. `coin` is the coin amount moved. `virtualTon / virtualToken / realTon` are the curve state **after** the trade, so
  a single event is enough to recompute the price: `price = virtualTon / virtualToken` (GRAM per coin).
- **CurveGraduated** is emitted once; from then on the coin trades on `pool` and the curve refuses `Buy` (478).
- **PoolSwap.reserveTon / reserveCoin** are the pool state after the swap: `price = reserveTon / reserveCoin`.
- **RewardPaid** is a USDT (or other reward jetton) payout to a holder — not a trade.

## Vault (Pot) and Ranks

| Topic | Emitter | Name | Body |
|---|---|---|---|
| `0x5054e001` | Pot | PotIn | `source:uint8 amount:coins from:addr` |
| `0x5054e002` | Pot | RoundSettled | `roundNo:uint32 slot:uint8 spendUsdt:coins received:coins liveDesks:uint32 counter:uint128` |
| `0x5054e003` | Pot | RoundRefunded | `slot:uint8 spendUsdt:coins refunded:coins` |
| `0x5054e004` | Pot | ConvertSettled | `spendTon:coins receivedUsdt:coins minUsdt:coins` |
| `0x5054e005` | Pot | SlippageBreach | `breachKind:uint8 slot:uint8 expectedMin:coins received:coins` |
| `0x5054e006` | Pot | PendingCancelled | `pendingKind:uint8 slot:uint8 spend:coins` |
| `0x5054e007` | Pot | SlotSkipped | `slot:uint8 next:uint8` |
| `0x5054e009` | Pot | DeskSwept | `serial:uint32 slot:uint8 owed:coins newStamp:uint128` |
| `0x5054e00a` | Pot | DeskWithdrawn | `serial:uint32 slot:uint8 amount:coins to:addr` |
| `0x4443e001` | DeskCollection | DeskDeployed | `serial:uint32 owner:addr item:addr isNew:bit` |

## Predict (Market, BetPosition — parimutuel prediction markets)

One `Market` per question (address derived from its `MarketConfig`: oracle, house, asset, cadence, window, fee, kind,
threshold, partner bps, claim window, limits), one `BetPosition` per (market, bettor). Prices are `uint128 × 1e8` (USD
for coins, GRAM for a gift floor); `attestation` is the sha256 of the published price proof
(`GET /api/predict/proof/<hex>` returns it, re-hash it yourself). The order matters: a `HousePaid` always follows the
`MarketResolved` of the same transaction; `Claimed` is emitted by the **BetPosition** when the market has paid it.

| Topic | Emitter | Name | Body |
|---|---|---|---|
| `0x5044e001` | Market | BetPlaced | `owner:addr isYes:bit amount:coins poolYes:coins poolNo:coins partner:(Maybe ^[partner:addr fee:coins])` — `amount` is the **net** stake pooled (gross minus the partner cut); `partner` null = native bet |
| `0x5044e002` | Market | MarketOpened | `openPrice:uint128 publishTime:uint32 attestation:uint256` |
| `0x5044e003` | Market | MarketResolved | `outcome:uint8 openPrice:uint128 closePrice:uint128 poolYes:coins poolNo:coins fee:coins publishTime:uint32 attestation:uint256` — outcome 1 YES, 2 NO, 3 VOID (`fee = 0`, `attestation = 0` on a void without a price) |
| `0x5044e004` | Market | HousePaid | `amount:coins to:addr` |
| `0x5044e005` | BetPosition | Claimed | `owner:addr payout:coins` |

Semantics: `poolYes + poolNo` after resolution is the pot; winners share `pot − fee` pro-rata to their net stake; a
one-sided or void market refunds every net stake and `fee = 0` (the partner cut paid at `BetPlaced` is never refunded).
Opcodes of the messages the wallet signs: `PlaceBet 0x50440001` (`queryId:uint64 isYes:bit partner:(Maybe addr)`, value =
gross stake + 0.025 TON, + 0.005 with a partner; the BetPosition keeps 0.01 TON and refunds the rest of the gas to the bettor as `0xd53276db`)
and `Claim 0x50440012` (`queryId:uint64`, value ≥ 0.03 TON — the app attaches 0.05, the excess is refunded — sent to the
BetPosition — `get_position_address(owner)` on the market). Oracle-only: `LockOpen 0x50440002`, `Resolve 0x50440003`,
`ForceVoid 0x50440004` (anyone, one hour after the resolve time without a resolution), `SweepHouse 0x50440006` (after the
claim window).

## Reading them

With toncenter v3: `GET /api/v3/transactions?account=<curve>&limit=…` → for each transaction, `out_msgs` whose
`destination` is null/external carry the log; the topic is the 248-bit value in the message's `destination` field
(`opcode` is not set on these). With `@ton/core`: `msg.info.type === "external-out"`, topic from `info.dest.value`.

We are happy to help port these layouts to a ton-etl-style parser: [@soleil](https://t.me/soleil).
