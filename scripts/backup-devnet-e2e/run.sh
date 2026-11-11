#!/usr/bin/env bash
# End-to-end check of the one-payment backup (backup.rs publish_backup +
# backuppay.rs) against a REAL local Autonomi network: in-process nodes
# from ant-core's `devnet` feature plus an Anvil chain, with a signer
# that counts signatures.
#
# The devnet feature pulls ant-node into the dependency graph, which the
# shipped crate must not carry — so this runs on a scratch COPY of the
# crate and leaves the repo (and its Cargo.lock) untouched.
#
#   scripts/backup-devnet-e2e/run.sh          # ~15 min cold, ~3 min warm
#
# Needs anvil on PATH (~/tools/foundry/x). Results: $SCRATCH/*.log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CRATE="$HERE/../../native/watchit_core"
SCRATCH="${SCRATCH:-/tmp/watchit-backup-e2e}"
export PATH="$HOME/.cargo/bin:$HOME/tools/foundry/x:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE/target}"

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
rsync -a --exclude target "$CRATE/" "$SCRATCH/watchit_core/"
cd "$SCRATCH/watchit_core"
sed -i 's|^\(ant-core = { git = .*tag = "[^"]*"\) }|\1, features = ["devnet"] }|' Cargo.toml
grep -q 'features = \["devnet"\]' Cargo.toml || { echo "could not enable the devnet feature"; exit 1; }
NODE_VERSION="$(grep -A1 '^name = "ant-node"' Cargo.lock | grep version | cut -d'"' -f2 || true)"
sed -i "s|^\[dev-dependencies\]|[dev-dependencies]\nant-node = \"${NODE_VERSION:-0.24.0}\"|" Cargo.toml
cp "$HERE/devnet_e2e.rs" src/devnet_e2e.rs
echo '#[cfg(test)] mod devnet_e2e;' >> src/lib.rs

cargo test --release --lib devnet_e2e::one_payment -- --nocapture --test-threads=1 2>&1 | tee "$SCRATCH/one.log" | tail -5
cargo test --release --lib devnet_e2e::big_backup -- --nocapture --test-threads=1 2>&1 | tee "$SCRATCH/big.log" | tail -5
