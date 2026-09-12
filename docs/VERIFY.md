# Verifying the ONRANK contracts

Two levels, from cheapest to strongest.

## 1. Code hashes (anyone, one command)

`contracts/build/<Name>.json` holds the compiled code of every contract (`code_boc64`, `hash`). The script
`contracts/scripts/check-code-hashes.mjs` (shipped with the sources) asks toncenter for the code hash of each deployed
account and compares. Without the sources you can do the same by hand: toncenter v3
`accountStates?address=<addr>` returns `code_hash`; compare it with the table in [README.md § 2](./README.md#2-contracts-mainnet).

```bash
node contracts/scripts/check-code-hashes.mjs          # exit 0 = every deployed contract runs the published build
POT_RELAY=EQBv-rQifdeTG6AMWw9OEp9x9YLEBGs__tkWj5sy8ulgiOFT node contracts/scripts/check-code-hashes.mjs --json
```

Result on 2026-09-12 (mainnet): FactoryV2, Pot, DeskMinter, DeskCollection, BuybackVault, RewardMasterV2 ($RANK),
CurveV2 ($RANK), PotRelay — **8/8 match**. PoolV2, RewardWalletV2, RewardVaultV2, FeeSplitterV2 and DeskItem are
deployed by those contracts with the code embedded in the build artifacts of the same name; their hashes are in
[README.md § 2](./README.md#2-contracts-mainnet).

## 2. Reproducing the build (Tolk 1.4.1 / Acton 1.1.0)

The sources compile deterministically: the same sources and compiler give the same `hash`.

```bash
cd contracts
acton build                  # Acton 1.1.0 (Acton.toml [toolchain]) → Tolk 1.4.1; writes contracts/build/*.json
node scripts/check-code-hashes.mjs
```

`build/` is a build output (git-ignored in the main repository); the public mirror ships a snapshot of it next to the
sources so the hashes can be checked without installing the toolchain.

Entry points (each is one contract): `contracts/contracts/launcher-v2/{FactoryV2,CurveV2,PoolV2,RewardMasterV2,
RewardWalletV2,RewardVaultV2,FeeSplitterV2}.tolk`, `contracts/contracts/pot/{Pot,PotRelay}.tolk`,
`contracts/contracts/desk/{DeskMinter,DeskCollection,DeskItem}.tolk`, `contracts/contracts/launcher/BuybackVault.tolk`.
Shared code: `contracts/contracts/common/*` and `contracts/contracts/vendor/jetton/*` (TEP-74/TEP-62 messages).

## 3. Source verification on explorers (verifier.ton.org)

Publishing the sources through the TON verifier makes Tonviewer / Tonscan show "verified" with the code inline. It is
a signed, public action performed by the deployer; the steps are:

1. Publish the `contracts/` tree of this repository (the public mirror `onrank-contracts` carries exactly these files).
2. On [verifier.ton.org](https://verifier.ton.org): language **Tolk**, compiler **1.4.1**, add the entry file and every
   file it includes (same relative paths), target the deployed address, submit. Repeat per contract in the table above.
3. Check that the explorer shows the same hash as `check-code-hashes.mjs`.

Not yet submitted (2026-09-12): the owner triggers each submission. Until then, level 1 gives an integrator the same
guarantee from the command line.
