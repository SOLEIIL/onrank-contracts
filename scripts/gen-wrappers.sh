#!/usr/bin/env bash
# Regenerate Tolk wrappers for every contract declared in Acton.toml.
set -euo pipefail
cd "$(dirname "$0")/.."
for c in DeskCollection DeskItem DeskMinter Pot JettonMinter JettonWallet FeeSplitter RewardWallet RewardMaster RewardVault Pool Curve Factory BuybackVault; do
  acton wrapper "$c" | tail -1
done
