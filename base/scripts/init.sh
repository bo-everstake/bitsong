#!/usr/bin/env sh
set -euo pipefail

echo "🟡 Running Bitsong init script..."

HOME_DIR="${HOME_DIR:-/data}"
DAEMON_HOME="${DAEMON_HOME:-${HOME_DIR}/.bitsongd}"
CONFIG_DIR="${DAEMON_HOME}/config"
DATA_DIR="${DAEMON_HOME}/data"

CHAIN_ID="${CHAIN_ID:-bitsong-2b}"
MONIKER="${MONIKER:-bitsong-gke}"

# Repo-provided TOML config dir (ConfigMap mount)
REPO_CONFIG_DIR="${REPO_CONFIG_DIR:-/repo-config}"

# Marker to avoid re-restoring snapshot (we only create it AFTER successful restore)
MARKER_FILE="${DAEMON_HOME}/.snapshot_restored"

# Used to detect TOML changes from repo
REPO_CFG_HASH_FILE="${DAEMON_HOME}/.repo_config.sha256"

# Genesis should NOT be stored in ConfigMap (can be large)
GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/bitsongofficial/networks/master/bitsong-2b/genesis.json}"

# Polkachu snapshot API (latest)
SNAPSHOT_API="${SNAPSHOT_API:-https://polkachu.com/api/v2/chain_snapshots/bitsong/mainnet}"
SNAPSHOT_BASE_URL="${SNAPSHOT_BASE_URL:-https://snapshots.polkachu.com/snapshots/bitsong}"

# Require secret via env (from K8s Secret)
POLKACHU_SECRET="${POLKACHU_SECRET:?POLKACHU_SECRET env is required}"

# Optional knobs
FORCE_GENESIS="${FORCE_GENESIS:-false}"

mkdir -p "${DAEMON_HOME}" "${CONFIG_DIR}"

has_chain_db() {
  [ -d "${DATA_DIR}/blockstore.db" ] || [ -d "${DATA_DIR}/state.db" ]
}

is_dir_empty() {
  # returns 0 if empty or missing
  d="$1"
  [ ! -d "$d" ] || [ -z "$(ls -A "$d" 2>/dev/null || true)" ]
}

download_genesis() {
  echo "⬇️  Downloading genesis from ${GENESIS_URL}"
  wget -qO "${CONFIG_DIR}/genesis.json" "${GENESIS_URL}"
}

fetch_snapshot_meta() {
  curl -s -H "x-polkachu: ${POLKACHU_SECRET}" "${SNAPSHOT_API}"
}

restore_snapshot_latest() {
  echo "📦 Restoring latest snapshot from Polkachu..."

  RESPONSE="$(fetch_snapshot_meta)"
  SNAPSHOT_NAME="$(echo "${RESPONSE}" | jq -r '.snapshot.name')"

  if [ -z "${SNAPSHOT_NAME}" ] || [ "${SNAPSHOT_NAME}" = "null" ]; then
    echo "❌ Failed to get snapshot.name from API response" >&2
    echo "${RESPONSE}" >&2
    exit 1
  fi

  SNAPSHOT_URL="${SNAPSHOT_BASE_URL}/${SNAPSHOT_NAME}"
  echo "⬇️  Snapshot: ${SNAPSHOT_NAME}"
  echo "🔗 URL: ${SNAPSHOT_URL}"

  bitsongd tendermint unsafe-reset-all --home "${DAEMON_HOME}" --keep-addr-book || true
  rm -rf "${DATA_DIR}" || true

  wget -qO- "${SNAPSHOT_URL}" | lz4 -dc | tar -x -C "${DAEMON_HOME}"

  if ! has_chain_db; then
    echo "❌ Snapshot extracted but blockstore/state not found under ${DATA_DIR}" >&2
    exit 1
  fi

  touch "${MARKER_FILE}"
  echo "✅ Snapshot restore completed"
}

sync_repo_tomls_if_changed() {
  # We only manage these files:
  #   app.toml, config.toml, client.toml
  # Repo provides them, we copy into PVC config dir if changed.

  for f in app.toml config.toml client.toml; do
    if [ ! -f "${REPO_CONFIG_DIR}/${f}" ]; then
      echo "❌ Missing ${REPO_CONFIG_DIR}/${f} (expected from ConfigMap bitsong-config)" >&2
      exit 1
    fi
  done

  NEW_HASH="$(sha256sum \
    "${REPO_CONFIG_DIR}/app.toml" \
    "${REPO_CONFIG_DIR}/config.toml" \
    "${REPO_CONFIG_DIR}/client.toml" | sha256sum | awk '{print $1}')"

  OLD_HASH=""
  if [ -f "${REPO_CFG_HASH_FILE}" ]; then
    OLD_HASH="$(cat "${REPO_CFG_HASH_FILE}" 2>/dev/null || true)"
  fi

  if [ "${NEW_HASH}" = "${OLD_HASH}" ]; then
    echo "✅ Repo TOML configs unchanged, skipping copy"
    return 0
  fi

  echo "🛠  Repo TOML changed (or first sync). Copying into ${CONFIG_DIR} ..."
  cp -f "${REPO_CONFIG_DIR}/app.toml" "${CONFIG_DIR}/app.toml"
  cp -f "${REPO_CONFIG_DIR}/config.toml" "${CONFIG_DIR}/config.toml"
  cp -f "${REPO_CONFIG_DIR}/client.toml" "${CONFIG_DIR}/client.toml"
  echo "${NEW_HASH}" > "${REPO_CFG_HASH_FILE}"
  echo "✅ Repo TOML sync completed"
}

echo "🔎 Home/Config/Data status:"
echo "  - DAEMON_HOME=${DAEMON_HOME}"
echo "  - CONFIG_DIR=${CONFIG_DIR}"
echo "  - DATA_DIR=${DATA_DIR}"

########################################
# 1) INIT HOME (ONE-TIME)
########################################
INIT_DONE="false"
if [ ! -f "${CONFIG_DIR}/config.toml" ] && is_dir_empty "${CONFIG_DIR}"; then
  echo "🔧 bitsongd init (first time) ..."
  bitsongd init "${MONIKER}" --chain-id "${CHAIN_ID}" --home "${DAEMON_HOME}"
  INIT_DONE="true"
else
  echo "✅ Home already initialized (config exists), skipping bitsongd init"
fi

########################################
# 2) GENESIS (ONE-TIME, or forced)
########################################
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

########################################
# 3) TOML FROM REPO → PVC (ONLY IF CHANGED)
########################################
# This is your GitOps control point.
sync_repo_tomls_if_changed

########################################
# 4) SNAPSHOT RESTORE (when chain DB is missing)
########################################
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

########################################
# 5) PERMISSIONS (PVC)
########################################
echo "🔐 Fixing permissions..."
chown -R 1000:1000 "${HOME_DIR}" || true
chmod -R g+rwX "${HOME_DIR}" || true

echo "✅ Init completed."
