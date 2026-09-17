# ONRANK contracts

Smart contracts of [ONRANK](https://t.me/OnRankBot), a coin launchpad on TON where every trading fee is split on chain:
70% to the coin's holders (paid in USDT), 15% protocol, 10% to a Vault that buys tokenized stocks for Rank holders,
5% buyback of $RANK. Written in **Tolk 1.4.1**, built and tested with **Acton 1.1.0**.

This repository is the public mirror of the contract sources, published so that integrators (trading bots, wallets,
indexers) and users can read the code that runs on mainnet and check it against the deployed accounts.

- App: [t.me/OnRankBot](https://t.me/OnRankBot) · site: [onrank.lol](https://onrank.lol) · protocol docs: [onrank.lol/docs](https://onrank.lol/docs)
- Integration guide (messages, gas, quotes, API, SDK): [onrank.lol/developers](https://onrank.lol/developers) — also in [`docs/`](./docs) here
- Contact: [@soleil](https://t.me/soleil)

## What is in here

| Directory | Contents |
|---|---|
| `contracts/launcher-v2/` | the live launcher: `FactoryV2`, `CurveV2` (bonding curve), `PoolV2` (post-graduation AMM), `RewardMasterV2` / `RewardWalletV2` (the coin's jetton, TEP-74), `RewardVaultV2` (holder rewards in USDT), `FeeSplitterV2` |
| `contracts/launcher/` | the first launcher (v1) — its coins are sell-only — and `BuybackVault` |
| `contracts/pot/` | `Pot` (the Vault that buys tokenized stocks and keeps the per-Rank counters) and `PotRelay` |
| `contracts/desk/` | `DeskMinter`, `DeskCollection`, `DeskItem` — the Rank NFTs (TEP-62) |
| `contracts/predict/` | `Market` (one parimutuel market per question: Up/Down window or price target) and `BetPosition` (one per bettor and market) — ONRANK Predict v1.1 |
| `contracts/common/`, `contracts/vendor/jetton/` | shared errors, messages, TEP-74 / TEP-62 message layouts |
| `tests/`, `wrappers/` | Acton test suites and generated wrappers |
| `build/` | compiled code (`code_boc64`) and code hash of every contract — the snapshot the deployed accounts are checked against |
| `scripts/check-code-hashes.mjs` | compares the code hash of every mainnet account with `build/` (read-only) |
| `docs/` | integration guide, event layouts, verification notes, OpenAPI of the public API, the Predict audit package (`16-predict-audit-package.md`) |

## Deployed contracts (mainnet)

| Contract | Address |
|---|---|
| FactoryV2 | `EQB18IIqz56m9AAwNpX0Ai61_LNa4yquhT3QRNk4geiLwdhA` |
| Pot (Vault) | `EQCpS9EiKrk0W7pCEybeKiCbzLL1b-CSTeiHHgVGKCQD5Mc1` |
| PotRelay | `EQBv-rQifdeTG6AMWw9OEp9x9YLEBGs__tkWj5sy8ulgiOFT` |
| DeskMinter | `EQBAUS2t-elNMrkdZtv7Tl1pMZhTJrZqdogyCK-2UxmjjPzu` |
| DeskCollection | `EQBKCClSs3RhzCXqQrLf8uyUPUBuCmU4P4YGY51tJyNMYgMe` |
| BuybackVault | `EQBtLFO9DvXI6WV0uraqVWu6qH8o7gQbk6Awfxg7Kj8Z_phO` |

Per-coin contracts (master, curve, pool, splitter, vault) are created by the Factory; find them in the `LaunchCreated`
event or through `GET https://onrank.lol/api/v1/coins`. Code hashes of every family are listed in
[`docs/README.md`](./docs/README.md#2-contracts-mainnet).

**Predict** contracts are deployed on demand, not once: the oracle keeper deploys one `Market` per question and each
bettor's first bet deploys their `BetPosition`. Their code is fixed (v1.1) — a market whose code hash differs is not an
ONRANK market. Addresses: `GET https://onrank.lol/api/predict/markets/{id}` (`address`) or the partner API.

| Contract | Code hash (v1.1) |
|---|---|
| Market | `2aead32d0ef3afbd7ebe4c3c4859767dbf58add41bbefb42bbb1cd7159b531a7` |
| BetPosition | `8dad64bd903f69b972bb9d3b983f4c5af9bf54b7d13b624027aba07d3afd5d66` |

## Check the deployed code yourself

```bash
node scripts/check-code-hashes.mjs           # exit 0 = every mainnet account runs the code in build/
```

The script asks toncenter for each account's `code_hash` and compares it with `build/<Name>.json`. No key, no wallet.

## Build and test

Install [Acton](https://github.com/ton-blockchain/acton) 1.1.0 (the version is pinned in `Acton.toml`), then:

```bash
acton build      # compiles every contract into build/*.json — the hashes must match the committed snapshot
acton test       # runs tests/
```

`acton fmt --check` and `acton check` are run in CI as well.

## Reading the code

Start with `contracts/launcher-v2/CurveV2.tolk` (buy / sell / graduation), then `PoolV2.tolk` (swaps after
graduation) and `RewardMasterV2.tolk` (how a sale is routed from the holder's wallet to the live market). The event
layouts every contract emits are documented in [`docs/EVENTS.md`](./docs/EVENTS.md).

## Security

- Admin roles are parameters, not funds: fee splits and factory parameters change behind a 48-hour timelock
  (`FactoryChanged`, `SplitsChanged`, `VaultChanged` events); Vault parameters (slots, floors) are set by the admin and
  every change is an on-chain event. The exact powers are in the code — read the `Admin*` / `Set*` handlers.
- Coins are standard jettons: only the holder's wallet can move or burn them; sales are a burn signed by the holder.
- The protocol never holds a user's private key; every user action is a message signed by the user's wallet.
- Found something? Please write to [@soleil](https://t.me/soleil) before disclosing publicly.

## License

MIT — see [LICENSE](./LICENSE).
