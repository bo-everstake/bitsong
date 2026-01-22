#!/bin/bash
set -euxo pipefail

echo "🟡 Running Bitsong init script..."

# === CONFIG ===
SNAPSHOT_TMP="/data/snapshot.tar.lz4"
SNAPSHOT_DIR="/data/.bitsongd/data"
SNAPSHOT_API="https://polkachu.com/api/v2/chain_snapshots/bitsong/mainnet"
SNAPSHOT_BASE_URL="https://snapshots.polkachu.com/snapshots/bitsong"
: "${POLKACHU_SECRET:?Environment variable POLKACHU_SECRET not set}"

# === CHECK EXISTING CHAIN DATA ===
if [ -d "$SNAPSHOT_DIR" ] && [ "$(ls -A "$SNAPSHOT_DIR")" ]; then
  echo "✅ Snapshot already exists, skipping download."
  exit 0
fi

# === FETCH SNAPSHOT METADATA ===
echo "🌐 Fetching latest snapshot metadata..."
RESPONSE=$(curl -s --header "x-polkachu: $POLKACHU_SECRET" "$SNAPSHOT_API")
SNAPSHOT_NAME=$(echo "$RESPONSE" | jq -r '.snapshot.name')
SNAPSHOT_TIME_RAW=$(echo "$RESPONSE" | jq -r '.snapshot.time')

# === CHECK SNAPSHOT AGE ===
SNAPSHOT_TIMESTAMP=$(date -d "$SNAPSHOT_TIME_RAW" +%s)
CURRENT_TIMESTAMP=$(date +%s)

if (( CURRENT_TIMESTAMP - SNAPSHOT_TIMESTAMP > 900 )); then
  echo "❌ Snapshot is older than 15 minutes, aborting."
  exit 1
fi

# === DOWNLOAD SNAPSHOT ===
SNAPSHOT_URL="${SNAPSHOT_BASE_URL}/${SNAPSHOT_NAME}"
echo "⬇️  Downloading snapshot from $SNAPSHOT_URL ..."
wget "$SNAPSHOT_URL" -O "$SNAPSHOT_TMP"

# === EXTRACT SNAPSHOT ===
echo "📦 Extracting snapshot..."
lz4 -d "$SNAPSHOT_TMP" -c | tar -x -C /data/.bitsongd

# === CLEAN UP ===
echo "🧹 Cleaning up archive..."
rm -f "$SNAPSHOT_TMP"

# === FIX PERMISSIONS ===
echo "🔐 Fixing permissions..."
chown -R 1000:1000 /data
chmod -R g+rwX /data

echo "✅ Init script complete."

