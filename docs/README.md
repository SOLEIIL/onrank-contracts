# ONRANK — integration guide for trading bots, wallets and indexers

ONRANK is a coin launchpad on TON. Every coin starts on a bonding curve and graduates to its own on-chain pool.
Every trade pays a 1% fee that the contracts split in the same transaction: 70% to the coin's holders (paid in USDT),
15% protocol, 10% to the Vault (buys tokenized stocks for Rank holders), 5% buyback of $RANK.

This guide is everything an integrator needs to **quote, buy and sell any ONRANK coin from their own product**
without going through the ONRANK app. Nothing here requires an API key, and nothing here ever needs a private key on a
server: you build a message, the user signs it in their wallet.

- Contracts: Tolk 1.4.1, sources at [github.com/SOLEIIL/onrank-contracts](https://github.com/SOLEIIL/onrank-contracts) (MIT, with the compiled
  snapshot; CI rebuilds and requires identical code hashes). Hashes below match mainnet (see [VERIFY.md](./VERIFY.md)).
- SDK: [`@onrank/sdk`](https://github.com/SOLEIIL/onrank-sdk) — pure TypeScript builders and quote formulas, tested bit-for-bit against the app
  (npm publication pending: clone the repository; every message it builds is also specified in § 4).
- REST API: [openapi.yaml](./openapi.yaml) — `GET /api/v1/coins`, `/coins/{seq}`, `/coins/{seq}/quote`, `/coins/{seq}/tx`,
  `/trades`, plus a [DexScreener adapter](#dexscreener-adapter).
- Events: [EVENTS.md](./EVENTS.md) — how to detect trades and graduations from the chain.
- Contact: [@soleil](https://t.me/soleil) · app: [t.me/OnRankBot](https://t.me/OnRankBot) · [onrank.lol/docs](https://onrank.lol/docs)

**Vocabulary.** GRAM is what the app calls TON. A coin is identified by its `seq` (a number, e.g. `10001` for $RANK)
and by its **master** (the TEP-74 jetton master). Its **curve** and later its **pool** are the contracts you trade
with. A holder's coins sit in their **RewardWallet** (their jetton wallet for that coin). Amounts are decimal strings
in smallest units: nanoTON for TON, 9-decimal units for coins.

---

## 0. Quick start — three requests, no key

The fastest integration uses the public API and lets the user's wallet do the signing.

**1. List the coins** — which exist and where each one trades.

```
GET https://onrank.lol/api/v1/coins
→ { "items": [ { "seq": "10001", "symbol": "RANK", "market": "curve", "sellOnly": false, "master": "EQ…", "curve": "EQ…", "pool": null, … } ] }
```

**2. Quote** — the exact number the contract will deliver.

```
GET https://onrank.lol/api/v1/coins/10001/quote?side=buy&amount=5000000000        (5 TON, in nanoTON)
→ { "amountOut": "1785969077031385", "fee": "50000000", "attachTon": "5150000000", "priceNano": "2799", … }
```

**3. Build the message** — and hand it to the wallet.

```
GET https://onrank.lol/api/v1/coins/10001/tx?side=buy&amount=5000000000&slippageBps=200&from=<user wallet>
→ { "minOut": "1750249695490757",
    "message": { "address": "EQ…curve…", "amount": "5150000000", "payload": "te6cc…" },
    "validUntil": 1789236407, … }
```

```ts
// TON Connect, in your app or bot
await tonConnectUI.sendTransaction({ validUntil: tx.validUntil, messages: [tx.message] });
```

Selling is the same call with `side=sell&amount=<coin units>`: the message goes to the user's own RewardWallet and
the master pays them in TON. That is the whole integration. Everything below explains what those messages are, so you
can also build them yourself (SDK or by hand), quote from your own RPC, and index trades from the chain.

Errors come back as `{ "error": "sell_only" | "curve_closed" | "bad_amount" | …, "message": "…" }` with a 4xx status;
`curve_closed` (409) means the coin just graduated — fetch it again, it now has a `pool`.

---

## 1. Lifecycle of a coin

| Phase | Where trades happen | How to tell |
|---|---|---|
| Curve | `Curve` contract (one per coin) | `get_curve_data().pool == null` — or `/api/v1/coins/{seq}.pool == null` |
| Pool | `Pool` contract (one per coin, deployed by the curve at graduation) | `pool != null` |

Numbers (mainnet Factory v2, read live from `GET /api/config` → `launch`):

- total supply 1 000 000 000 coins; 800 000 000 sold on the curve; 200 000 000 seed the pool;
- virtual reserves at launch: 510 GRAM / 1 073 000 000 coins (constant product);
- fee 1% (`feeBps 100`) on the GRAM side of every curve trade; pool: 1% LP fee (stays in the pool reserve) + 1% protocol fee;
- min buy 0.1 GRAM; launch fee 0.5 GRAM;
- graduation when the curve has sold its 800 M coins (≈ 1 494.5 GRAM collected) or collected 3 000 GRAM, whichever
  comes first (today: always the sell-out). At graduation the price is continuous (no jump); 26 GRAM of the collected
  amount pay pool deployment + protocol, the rest becomes pool liquidity.

**v1 coins are sell-only.** Coins created before the v2 launcher (`version: 1`, `sellOnly: true` in the API) can be
sold and claimed but not bought; do not route buys to them. The current $RANK is v2 (`seq 10001`).

---

## 2. Contracts (mainnet)

| Contract | Address | Code hash (base64) |
|---|---|---|
| FactoryV2 | `EQB18IIqz56m9AAwNpX0Ai61_LNa4yquhT3QRNk4geiLwdhA` | `UhyECvtffP/+4hoszJv5w2jH21HAO81k0g4e78RWqBk=` |
| CurveV2 (one per coin) | from `LaunchCreated` / API | `x1+u3TP0Q7h7k/X9GByNy6WqOCvnJ4KVL1hR7t2tWcM=` |
| PoolV2 (one per graduated coin) | from `CurveGraduated` / API | `4yPKye3U58+n21m6EC5vdwvii5A10umUOjjR2elP9t8=` |
| RewardMasterV2 (the coin's jetton master) | from `LaunchCreated` / API | `XSZIxXypgXYGEwADqjEcTRTu9mXqu1xb+z7Vu/3fjBw=` |
| RewardWalletV2 (the holder's jetton wallet) | `get_wallet_address(owner)` on the master | `qahjc6e276BatQUKZ9wJ4iuKe6Crnv0FbCXcSR+Kr+A=` |
| FeeSplitterV2 (one per coin) | from `LaunchCreated` | `5cXxuRBVXd5tEU3TKojemQ9zzEEwo1hpLnkjnCiDSO4=` |
| RewardVaultV2 (one per coin) | from `LaunchCreated` | `vzEyUk5gEDQxHIfokjDqvgmuwFsOQnnKwpyBrIVRE/A=` |
| Pot (the Vault) | `EQCpS9EiKrk0W7pCEybeKiCbzLL1b-CSTeiHHgVGKCQD5Mc1` | `lxv0tCBCh1oQk0f5oBU0KCTmebivPtMicSoSp5h4Phw=` |
| PotRelay | `EQBv-rQifdeTG6AMWw9OEp9x9YLEBGs__tkWj5sy8ulgiOFT` | `h7MamCDtM7iPXwEquvm5JaSgCAHLgf3EkVq8Y7Zz2tY=` |
| DeskMinter (Rank minter) | `EQBAUS2t-elNMrkdZtv7Tl1pMZhTJrZqdogyCK-2UxmjjPzu` | `QdIxvaBs/3OE7xHOPy4bPP5SzHtMBriVW+TywiLifxA=` |
| DeskCollection (Rank NFTs) | `EQBKCClSs3RhzCXqQrLf8uyUPUBuCmU4P4YGY51tJyNMYgMe` | `LHhgnY0QJjXpBWNkpYjjCJK1elxludK0gBHdLq4IYeU=` |
| BuybackVault | `EQBtLFO9DvXI6WV0uraqVWu6qH8o7gQbk6Awfxg7Kj8Z_phO` | `WXP9MVAA2AT/dITksu2ewZGJo9hdBlV7LAeG/s6C9Xo=` |

[VERIFY.md](./VERIFY.md) explains how to re-check every deployed hash yourself.
**Never take a curve or pool address from user input**: resolve it from the Factory's `LaunchCreated` event, from the
master's `get_reward_master_data`, or from `GET /api/v1/coins/{seq}` — and check its code hash against this table.

---

## 3. Quoting

All quotes are available on-chain (no dependency on ONRANK servers) and mirrored by `/api/v1/coins/{seq}/quote`.

### Curve

`get_curve_data()` → `(state uint8, virtualTon coins, virtualToken coins, realTon coins, sold coins, pool address?, roles, params)`.
`state == 1` means open.

```
amountIn   = attached − BUY_GAS                 BUY_GAS = 0.15 TON
fee        = amountIn × 100 / 10000
net        = amountIn − fee
out        = virtualToken × net / (virtualTon + net)          // integer division
remaining  = curveSupply − sold
if out > remaining:                                            // last lot: pay exactly what is left
    out = remaining
    net = ceil(virtualTon × out / (virtualToken − out))
    fee = min(net × 100 / 9900, amountIn − net)
```

Sell (`coinIn` coins): `gross = virtualTon × coinIn / (virtualToken + coinIn)`, `fee = gross × 100 / 10000`, you receive
`gross − fee`. The contract also requires `gross ≤ realTon`.

Get-methods: `get_buy_quote(tonAttached) → (amountOut, fee)` (deducts BUY_GAS itself) and `get_sell_quote(coinIn)`.

### Pool

`get_pool_data()` → `(reserveTon, reserveCoin, lpFeeBps, protocolFeeBps, volumeTon, nonce, master, splitter)`.

```
amountIn    = attached − SWAP_GAS                SWAP_GAS = 0.15 TON (v2)
lpFee       = amountIn × lpFeeBps / 10000        (100 bps today)
protocolFee = amountIn × protocolFeeBps / 10000  (100 bps today)
net         = amountIn − lpFee − protocolFee
out         = reserveCoin × net / (reserveTon + net)
```

Sell: `gross = reserveTon × coinIn / (reserveCoin + coinIn)`, minus both fees on `gross`. Get-methods:
`get_buy_quote(tonIn)` (here `tonIn` is **after** gas) and `get_sell_quote(coinIn)`.

### Slippage

Always pass a `minOut` (buy) / `minTon` (sell). The contracts refuse the trade when the outcome is below it
(exit code 479 `SlippageExceeded`) and refund; nothing is partially executed. A typical client applies 1–3% to the quote.

---

## 4. Messages

Every message below is an **internal message signed by the user's wallet** (TON Connect `sendTransaction`, or any
wallet SDK). `queryId` is any 64-bit value you choose. Payloads are base64 BoC of the body cell.

### 4.1 Buy on the curve

Send to the **Curve** address, value = `tonIn + 0.15 TON`:

```
Buy#43550002  queryId:uint64  minOut:coins  recipient:(Maybe Address)
```

- The whole attached value minus `BUY_GAS` (0.15) is swapped. Excess gas is refunded.
- `recipient = null` credits the sender. **Do not set `recipient` to a wallet that is not the signer** unless you are
  intentionally buying for someone else — a bot that buys with its own wallet and forwards coins is custodial.
- Refusals bounce with: 478 `CurveNotOpen` (graduated — use the pool), 479 `SlippageExceeded`, 480 `BelowMinTrade`
  (< 0.1 TON), 410 `InsufficientValue` (attached ≤ BUY_GAS).

### 4.2 Buy on the pool

Send to the **Pool** address, value = `tonIn + 0.15 TON`:

```
SwapTonForCoin#504f0001  queryId:uint64  minOut:coins
```

Refusals: 479 `SlippageExceeded`, 491 `PoolEmpty`, 410 `InsufficientValue`.

### 4.3 Sell (curve or pool — same message)

Selling is a **burn of the coin on the user's own RewardWallet** carrying a `SellIntent`; the master then routes the
sale to the curve or to the pool, whichever is live, and pays the user in TON. Send to the user's **RewardWallet**
(`get_wallet_address(owner)` on the master), value = **0.19 TON** (0.16 required + margin, excess refunded):

```
AskToBurn#595f07bc  queryId:uint64  jettonAmount:coins  sendExcessesTo:(Maybe Address)  customPayload:(Maybe ^Cell)
  customPayload = SellIntent#52570018  minTon:coins
```

- `sendExcessesTo` = the owner. `minTon` = your quote after slippage.
- A refused sale (slippage, curve not open, budget) **re-mints the coins to the owner**: nothing is lost, the user only
  pays gas. Wallet-side refusals: 402 `NotFromOwner`, 410 `InsufficientValue`, 476 `SettleInFlight` (a previous sale or
  claim still settling — retry after a few seconds).
- v1 coins on a pool used a TEP-74 transfer to the pool instead; use the SDK (`version: 1`) or the `/tx` endpoint,
  which handle both.

### 4.4 Example (TypeScript, `@ton/core`)

```ts
import { Address, beginCell } from "@ton/core";

const BUY = 0x43550002, BUY_GAS = 150_000_000n;
export function buyOnCurve(curve: Address, tonIn: bigint, minOut: bigint, queryId = BigInt(Date.now())) {
  const body = beginCell().storeUint(BUY, 32).storeUint(queryId, 64).storeCoins(minOut).storeAddress(null).endCell();
  return { address: curve.toString(), amount: (tonIn + BUY_GAS).toString(), payload: body.toBoc().toString("base64") };
}

const ASK_TO_BURN = 0x595f07bc, SELL_INTENT = 0x52570018, SELL_VALUE = 190_000_000n;
export function sell(rewardWallet: Address, owner: Address, coinAmount: bigint, minTon: bigint, queryId = BigInt(Date.now())) {
  const intent = beginCell().storeUint(SELL_INTENT, 32).storeCoins(minTon).endCell();
  const body = beginCell().storeUint(ASK_TO_BURN, 32).storeUint(queryId, 64).storeCoins(coinAmount).storeAddress(owner).storeMaybeRef(intent).endCell();
  return { address: rewardWallet.toString(), amount: SELL_VALUE.toString(), payload: body.toBoc().toString("base64") };
}
// → pass the object to TON Connect: tonConnectUI.sendTransaction({ validUntil, messages: [msg] })
```

Or let the API build it: `GET /api/v1/coins/10001/tx?side=buy&amount=5000000000&slippageBps=200&from=<wallet>`
returns the same `{ address, amount, payload }` plus the quote it was built from.

---

## 5. Detecting trades and graduations

Curves and pools emit **external out-messages** (TON "logs") whose destination is a 256-bit topic. See
[EVENTS.md](./EVENTS.md) for layouts. The three you need:

- `CurveTrade` topic `0x4355e001`: `isBuy:bit trader:addr ton:coins coin:coins fee:coins virtualTon virtualToken realTon` (`ton` net of the fee in both directions)
- `PoolSwap` topic `0x504fe001`: `isBuy:bit trader:addr ton:coins coin:coins lpFee protocolFee reserveTon reserveCoin`
- `CurveGraduated` topic `0x4355e002`: `pool:addr liquidityTon liquidityCoin protocolFee`

Only trust events emitted by accounts whose code hash is in the table above. `GET /api/v1/trades?since=<unix>` returns
the same trades from our indexer if you prefer polling.

---

## 6. Security for integrators

1. **No keys on servers.** Every trade is a message the user signs. ONRANK's own API never signs anything either.
2. **`minOut` / `minTon` are mandatory.** Quote first, apply slippage, send. Never send `0`.
3. **Resolve addresses from the chain or from `/api/v1`, never from a user-supplied string**, and compare code hashes.
   A fake "curve" address is the classic drain.
4. **Watch bounces.** A bounced `Buy` refunds the value; a refused sale re-mints the coins. Show the user what
   happened instead of "success".
5. **Gas**: attach exactly what this document says; the contracts refund the excess. Under-funded messages bounce.
6. **v1 coins are sell-only.** Refuse buys when `sellOnly` is true.
7. **No auto-approve, no unlimited allowances** — there are none on TON, and a bot should never hold the user's coins.
8. **Rate limits**: the public API allows a modest per-IP rate; cache `/coins` for a few seconds, use on-chain
   get-methods for latency-sensitive quotes.

---

## 7. Attribution and referrals

Users reach the app through `https://t.me/OnRankBot?startapp=coin_<seq>-ref_<code>`; a `ref_<code>` earns the referrer
10% of the protocol's share of that user's fees (paid out by the team). **Trades sent directly on-chain by a bot carry
no referral code** — attribution only exists inside the app. If you route users to the app for a coin page, use the
deep link above.

---

## DexScreener adapter

`GET /api/dexscreener/latest-block`, `/asset?id=`, `/pair?id=`, `/events?fromBlock=&toBlock=` implement the
DexScreener adapter spec over the indexed trades (pair id = asset0 id = the coin's master address, asset1 = TON,
block = unix time). Read-only, cached 10 s. The `asset1Id` label is agreed with DexScreener at listing time.
