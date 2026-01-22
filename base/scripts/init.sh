#!/bin/bash
set -euxo pipefail

echo "🟡 Running Bitsong init script..."

# === PARAMETERS ===
SNAPSHOT_TMP="/data/snapshot.tar.lz4"
SNAPSHOT_DIR="/data/.bitsongd/data"
SNAPSHOT_API="https://polkachu.com/api/v2/chain_snapshots/bitsong/mainnet"
SNAPSHOT_BASE_URL="https://snapshots.polkachu.com/snapshots/bitsong"

# === CHECK EXISTING CHAIN DATA ===
if [ -d "$SNAPSHOT_DIR" ] && [ "$(ls -A $SNAPSHOT_DIR)" ]; then
  echo "✅ Snapshot already exists, skipping download."
else
  echo "🌐 Fetching latest snapshot name..."
  SNAPSHOT_NAME=$(curl -s "$SNAPSHOT_API" | jq -r '.snapshot.name')
  SNAPSHOT_URL="${SNAPSHOT_BASE_URL}/${SNAPSHOT_NAME}"

  echo "⬇️  Downloading snapshot from $SNAPSHOT_URL ..."
  curl -L "$SNAPSHOT_URL" -o "$SNAPSHOT_TMP"

  echo "📦 Extracting snapshot..."
  lz4 -d "$SNAPSHOT_TMP" | tar -x -C /data/.bitsongd

  echo "🧹 Cleaning up..."
  rm -f "$SNAPSHOT_TMP"
fi

# === FIX PERMISSIONS ===
echo "🔐 Fixing permissions..."
chown -R 1000:1000 /data
chmod -R g+rwX /data

echo "✅ Init script complete."

