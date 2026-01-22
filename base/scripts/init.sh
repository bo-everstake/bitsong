#!/usr/bin/env sh
set -euo pipefail

echo "🟡 Running Bitsong init script..."

HOME_DIR="/data"
DAEMON_HOME="${HOME_DIR}/.bitsongd"
CONFIG_DIR="${DAEMON_HOME}/config"
DATA_DIR="${DAEMON_HOME}/data"

CHAIN_ID="${CHAIN_ID:-bitsong-2b}"
MONIKER="${MONIKER:-bitsong-gke}"

# Marker to avoid re-restoring snapshot (we only create it AFTER successful restore)
MARKER_FILE="${DAEMON_HOME}/.snapshot_restored"

# Genesis should NOT be stored in ConfigMap (can be large)
GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/bitsongofficial/networks/master/bitsong-2b/genesis.json}"

# Polkachu snapshot API (latest)
SNAPSHOT_API="${SNAPSHOT_API:-https://polkachu.com/api/v2/chain_snapshots/bitsong/mainnet}"
SNAPSHOT_BASE_URL="${SNAPSHOT_BASE_URL:-https://snapshots.polkachu.com/snapshots/bitsong}"

# Require secret via env (from K8s Secret)
POLKACHU_SECRET="${POLKACHU_SECRET:?POLKACHU_SECRET env is required}"

# Optional knobs
# If set to "true", re-download genesis even if it exists
FORCE_GENESIS="${FORCE_GENESIS:-false}"
# If set to "true", enforce snapshot freshness check (<= 900s)
CHECK_SNAPSHOT_AGE="${CHECK_SNAPSHOT_AGE:-true}"
# max snapshot age seconds (default 15 min)
MAX_SNAPSHOT_AGE_SEC="${MAX_SNAPSHOT_AGE_SEC:-900}"

mkdir -p "${DAEMON_HOME}"

# ----------------------------
# Helpers
# ----------------------------
has_chain_db() {
  [ -d "${DATA_DIR}/blockstore.db" ] || [ -d "${DATA_DIR}/state.db" ]
}

download_genesis() {
  echo "⬇️  Downloading genesis from ${GENESIS_URL}"
  mkdir -p "${CONFIG_DIR}"
  wget -qO "${CONFIG_DIR}/genesis.json" "${GENESIS_URL}"
}

fetch_snapshot_meta() {
  # prints JSON to stdout
  curl -s -H "x-polkachu: ${POLKACHU_SECRET}" "${SNAPSHOT_API}"
}

snapshot_age_ok() {
  # expects $1 = snapshot_time (string)
  # returns 0 if ok / 1 if too old
  SNAPSHOT_TIME_RAW="$1"

  # If date parsing fails, better to fail safe (treat as not ok)
  SNAPSHOT_TS="$(date -d "${SNAPSHOT_TIME_RAW}" +%s 2>/dev/null || true)"
  if [ -z "${SNAPSHOT_TS}" ]; then
    echo "❌ Cannot parse snapshot time: ${SNAPSHOT_TIME_RAW}" >&2
    return 1
  fi

  NOW_TS="$(date +%s)"
  AGE="$((NOW_TS - SNAPSHOT_TS))"

  if [ "${AGE}" -le "${MAX_SNAPSHOT_AGE_SEC}" ]; then
    return 0
  fi

  echo "❌ Snapshot is too old: age=${AGE}s (limit=${MAX_SNAPSHOT_AGE_SEC}s)" >&2
  return 1
}

restore_snapshot_latest() {
  echo "📦 Restoring latest snapshot from Polkachu..."

  RESPONSE="$(fetch_snapshot_meta)"
  SNAPSHOT_NAME="$(echo "${RESPONSE}" | jq -r '.snapshot.name')"
  SNAPSHOT_TIME_RAW="$(echo "${RESPONSE}" | jq -r '.snapshot.time')"

  if [ -z "${SNAPSHOT_NAME}" ] || [ "${SNAPSHOT_NAME}" = "null" ]; then
    echo "❌ Failed to get snapshot name from API response" >&2
    echo "${RESPONSE}" >&2
    exit 1
  fi

  if [ "${CHECK_SNAPSHOT_AGE}" = "true" ]; then
    snapshot_age_ok "${SNAPSHOT_TIME_RAW}"
  fi

  SNAPSHOT_URL="${SNAPSHOT_BASE_URL}/${SNAPSHOT_NAME}"
  echo "⬇️  Snapshot: ${SNAPSHOT_NAME}"
  echo "🔗 URL: ${SNAPSHOT_URL}"

  # reset and remove old/mixed state
  bitsongd tendermint unsafe-reset-all --home "${DAEMON_HOME}" --keep-addr-book || true
  rm -rf "${DATA_DIR}" || true

  # Extract snapshot into DAEMON_HOME (should create ./data)
  wget -qO- "${SNAPSHOT_URL}" | lz4 -dc | tar -x -C "${DAEMON_HOME}"

  if ! has_chain_db; then
    echo "❌ Snapshot extracted but blockstore/state not found under ${DATA_DIR}" >&2
    echo "   Expected ${DATA_DIR}/blockstore.db or ${DATA_DIR}/state.db" >&2
    exit 1
  fi

  touch "${MARKER_FILE}"
  echo "✅ Snapshot restore completed"
}

# =========================================================
# 1) INIT HOME (ONE-TIME)
# =========================================================
INIT_DONE="false"
if [ ! -f "${CONFIG_DIR}/config.toml" ]; then
  echo "🔧 bitsongd init (first time) ..."
  bitsongd init "${MONIKER}" --chain-id "${CHAIN_ID}" --home "${DAEMON_HOME}"
  INIT_DONE="true"
else
  echo "✅ Home already initialized, skipping bitsongd init"
fi

# =========================================================
# 2) GENESIS (ONE-TIME, or forced)
# =========================================================
if [ "${FORCE_GENESIS}" = "true" ]; then
  echo "⚠️  FORCE_GENESIS=true, re-downloading genesis"
  download_genesis
else
  if [ ! -f "${CONFIG_DIR}/genesis.json" ]; then
    download_genesis
  else
    echo "✅ Genesis already present"
  fi
fi

# =========================================================
# 3) FIRST-TIME CONFIG TUNING (sed) ONLY
#    Only when INIT_DONE=true so we don't override existing tuned configs.
# =========================================================
if [ "${INIT_DONE}" = "true" ]; then
  echo "🛠  Applying initial config tuning (peers/rest/rpc/prom)..."

  # 3.1 Persistent peers
  PEERS="ff89f8ed0b53c5ac094c7e0c5b090855e3a40994@65.109.115.100:26989,2c7c42ed5e67343b5b09b8d4dcc933af3c807dd4@65.108.6.54:31656,c2192dc5056252bee8621ed86ea4e1a9d1d17615@65.108.98.235:26256,b150ba00b37bdd90b8d991c10b9c65506f8171cd@65.108.77.220:3000,171b6e944c314485c8ab2a5a70fcb8bbd11538d7@157.90.255.143:26656,7860c9dea7ee0dd902b10c57c790243b51c7c054@42.200.77.5:11256,bca36344413fbfe8374111f6f77b4861f29f00d3@37.27.59.245:56656,cd4a8164f9f0657ec7a765f19ad017fb5016cd4a@65.109.92.241:21036,7053a0374e06e7b6e0479002d1a05f53afb67790@62.109.12.16:26656,50503012f492693342dd3a0aa938c3df292f5556@217.182.198.128:26256,58ca294709d0d770c6ce92a6ad8f7ca9d89beebf@57.128.22.214:16056,79ec0d17fc4d7b2e26a614f30fc308a77733e821@88.99.184.249:26656,230506dc5d654c2f8f6d210448e1fa0671bec84d@138.201.250.242:31656,9c9f030298bdda9ca69de7db8e9a3aef33972fba@142.132.131.249:31656,fa932748b327fdde6d235b28a9850f8b8bd3326a@178.63.93.41:31656,250e24ae5d53e8f3034b1b99d96b31a0cf40999d@144.76.30.36:15631,..."  # (залиш як є повний рядок, я скоротив тут для читабельності)

  sed -i.bak -e "s/^persistent_peers *=.*/persistent_peers = \"${PEERS}\"/" \
    "${CONFIG_DIR}/config.toml" || true

  # 3.2 Enable REST + bind to 0.0.0.0
  sed -i.bak -E 's|^enable *= *false|enable = true|g' "${CONFIG_DIR}/app.toml" || true
  sed -i.bak -E 's|^address *= *"tcp://127.0.0.1:1317"|address = "tcp://0.0.0.0:1317"|g' "${CONFIG_DIR}/app.toml" || true

  # 3.3 RPC bind to 0.0.0.0
  sed -i.bak -E 's|^laddr *= *"tcp://127\.0\.0\.1:26657"|laddr = "tcp://0.0.0.0:26657"|' \
    "${CONFIG_DIR}/config.toml" || true

  grep -q '^laddr = "tcp://0.0.0.0:26657"' "${CONFIG_DIR}/config.toml" || \
    sed -i -E '0,/^laddr *=/{s|^laddr *=.*|laddr = "tcp://0.0.0.0:26657"|}' "${CONFIG_DIR}/config.toml"

  # 3.4 Prometheus enable + bind
  sed -i.bak -E 's|^prometheus *= *false|prometheus = true|g' "${CONFIG_DIR}/config.toml" || true
  sed -i.bak -E 's|^prometheus_listen_addr *= *".*"|prometheus_listen_addr = "0.0.0.0:26660"|g' \
    "${CONFIG_DIR}/config.toml" || true

  echo "✅ Initial config tuning done"
else
  echo "✅ Skipping sed tuning (home already existed)"
fi

# =========================================================
# 4) SNAPSHOT RESTORE (when chain DB is missing)
# =========================================================

# self-heal: marker exists but chain DB missing => remove marker
if [ -f "${MARKER_FILE}" ] && ! has_chain_db; then
  echo "⚠️  Marker exists but chain DB not found. Removing marker and restoring snapshot."
  rm -f "${MARKER_FILE}" || true
fi

if has_chain_db; then
  echo "✅ Chain DB present (blockstore/state found), skipping snapshot restore"
else
  # If no chain DB yet -> restore snapshot
  restore_snapshot_latest
fi

# =========================================================
# 5) PERMISSIONS
# =========================================================
echo "🔐 Fixing permissions..."
chown -R 1000:1000 "${HOME_DIR}"
chmod -R g+rwX "${HOME_DIR}"

echo "✅ Init completed."
