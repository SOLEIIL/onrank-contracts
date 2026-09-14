# ONRANK, built with Tolk and Acton — notes from a mainnet launch

*Russian version: [BUILT-WITH-ACTON.ru.md](./BUILT-WITH-ACTON.ru.md)*

ONRANK is a coin launchpad that lives inside Telegram ([@OnRankBot](https://t.me/OnRankBot)). Anyone can launch a coin
for 0.5 GRAM; every trade pays a 1% fee and 70% of it goes back to the coin's holders in USDT; 10% feeds a Vault that
buys tokenized stocks for the holders of a Rank NFT. It has been on mainnet since 2026-09-11. The whole on-chain side is
written in [Tolk](https://docs.ton.org/languages/tolk) (1.4) and built, tested, deployed and verified with
[Acton](https://ton-blockchain.github.io/acton/) (1.1.0). These are the notes we wished we had read before starting.

## What is on chain

Eight contract families are deployed and registered in the mainnet SourcesRegistry (verifier.ton.org): `Factory`,
`Curve`, the jetton master (`RewardMaster`), `Pot` (the Vault), `PotRelay`, `DeskMinter`, `DeskCollection` (Rank NFTs)
and `BuybackVault`. The Factory deploys a full set per coin: a bonding curve, the jetton master and its wallets, a fee
splitter and a reward vault, then a pool when the coin graduates. About 8,600 lines of Tolk, 23 test files, 159 tests,
all MIT: [github.com/SOLEIIL/onrank-contracts](https://github.com/SOLEIIL/onrank-contracts). Anyone can rebuild the
sources and compare the 22 code hashes with what is deployed ([how](./VERIFY.md)).

## Why Tolk + Acton

One toolchain for everything: the contracts, the tests, the deployment scripts and the verification are all Tolk, run by
one CLI. Messages are typed structs, so a test reads `expect(tr).toHaveSuccessfulTx<SettleAck>({ to: wallet.address })`
instead of decoding raw cells. The generated wrappers (`wrappers/*.gen.tolk` plus TypeScript) are what the Mini App and
the indexer use to build and parse messages — the ABI is the single source of truth between chain and app.

## The cycle that worked

1. **Start from a template.** The project was generated from Acton's `nft` template, which gave us the Rank NFT
   collection and item; the rest grew next to it in the same `Acton.toml`.
2. **Tests in Tolk, in emulation.** Fixtures use the real Factory amounts (master 0.15 GRAM, vault 0.1 + 0.04·n, curve
   0.15). After every handler the tests call an executable invariant (`supplyInvariant`, reserves ≥ liabilities).
   Interleaving tests run several messages "at once" with `testing.executeN` cursors, to pin down the races the review
   had pointed at. Gas tests pin the cost of the hot paths.
3. **Scripts are the deployment.** There is no `acton deploy`; deployment is a Tolk script. Run without `--net` it
   executes in emulation — a full dress rehearsal: deploy five contracts, wire the roles, launch the first coin, then a
   read-only `verify` script with 26 checks. Only when that is ALL GREEN do we add `--net testnet`, then `--net mainnet`.
   The mainnet deployment had no surprises because the rehearsal was the same code; the one surprise on testnet was
   ours — a Ledger derives a different key per network, so the testnet handover needs the testnet address.
4. **Hand over admin to a hardware wallet, immediately.** The hot deployer wallet is admin only during deployment;
   a `handover-admin` script rotates seven roles to a Ledger. After that every admin action is signed on the device.
5. **Verify from the CLI.** `acton verify --net mainnet --tonconnect`: the CLI shows a TON Connect QR, the Ledger pays
   the registry ticket through TON Connect, 8/8 contracts registered. `--tonconnect` also works for `acton script`, which
   means admin scripts can be signed by the same Ledger instead of a hot wallet.
6. **CI = the same four commands**: `acton build`, `acton fmt --check`, `acton check --output-format github`,
   `acton test`.

## Six rules we learned the hard way

Our first version of the reward jetton used a fixed-value send followed by a mode-64 message. During the final mainnet
rehearsal, the day before the public opening, the master's own balance ran low, the action phase failed *without a
bounce* and a wallet stayed `pending` forever. Contracts are not upgradable here (no `SetCode`, roles are one-shot), so
the fix was a v2 family with rules applied everywhere:

1. **Never a mode 64 after a fixed-value send.** One pattern only: `reserveToncoinsOnBalance(max(orig − in, MIN),
   AT_MOST)`, fixed sends in mode 1, last message `128 | 16` (bounce on action fail).
2. **Every `pending` state has an exit**: a bounceable ack *and* a timeout the owner can cancel, idempotently.
3. **Every `onBouncedMessage` checks the sender.** A legitimate bounce from another contract must not be mistaken for
   ours.
4. **Mutate optimistically on send, restore on bounce** — never "commit, then wait for the ack".
5. **Executable invariants in the tests after every handler.**
6. **No dependence on the contract's own balance**: each handler lives on the value of the incoming message.

## Where we stumbled (Acton 1.1.0)

- `acton build` compiles the contracts listed in `Acton.toml`, not `scripts/`. A deployment script sat in the repo with
  an undefined identifier and a call to a method that does not exist; `acton check` in CI caught it. In trunk, `check`
  covers `scripts/` by default — put it in CI from day one.
- `env<address>("ADMIN_FINAL")` did not accept the testnet address form (`0Q…`); `UQ…` worked. Reported fixed on master.
- `acton verify` rejected our `@contracts/...` import aliases; we rewrote 82 imports in 26 files to relative paths (every
  code hash unchanged) before verification went through. Keep imports relative if you plan to verify.
- On Windows we ran `verify` under WSL.
- Testnet faucet: 2 GRAM per request, two per day per IP; the actonscan faucet gives up to 8 per day with a GitHub account
  linked. Deploying the whole system costs ~6 GRAM, so plan a day ahead — or ask the Acton team, they offered.
- Wrappers are regenerated by hand (`acton wrapper Name`) after an ABI change; a desync warning at `acton test` is on
  their list.

## What we would do differently

Write the six rules before the first contract, not after an incident. Put invariants in the tests before the handlers.
Keep `scripts/` under `check` in CI from the first commit. Plan the hardware-wallet handover and `--tonconnect` from the
start, so admin operations never need a hot key.

---

Questions, or building something similar: [@soleil](https://t.me/soleil) on Telegram. Contracts, tests and hashes:
[github.com/SOLEIIL/onrank-contracts](https://github.com/SOLEIIL/onrank-contracts). The app: [@OnRankBot](https://t.me/OnRankBot).
