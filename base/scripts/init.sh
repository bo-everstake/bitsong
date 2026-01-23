#!/usr/bin/env sh
set -euo pipefail

echo "🟡 Running Bitsong init script..."

HOME_DIR="/data"
DAEMON_HOME="${HOME_DIR}/.bitsongd"
CONFIG_DIR="${DAEMON_HOME}/config"
DATA_DIR="${DAEMON_HOME}/data"

CHAIN_ID="${CHAIN_ID:-bitsong-2b}"
MONIKER="${MONIKER:-bitsong-gke}"

# Marker is created ONLY after successful snapshot restore
MARKER_FILE="${DAEMON_HOME}/.snapshot_restored"

# Genesis is large → never store in ConfigMap
GENESIS_URL="${GENESIS_URL:-https://raw.githubusercontent.com/bitsongofficial/networks/master/bitsong-2b/genesis.json}"

# Polkachu snapshot
SNAPSHOT_API="${SNAPSHOT_API:-https://polkachu.com/api/v2/chain_snapshots/bitsong/mainnet}"
SNAPSHOT_BASE_URL="${SNAPSHOT_BASE_URL:-https://snapshots.polkachu.com/snapshots/bitsong}"

# Secret (required)
POLKACHU_SECRET="${POLKACHU_SECRET:?POLKACHU_SECRET env is required}"

mkdir -p "${DAEMON_HOME}"

# -------------------------------------------------
# Helpers
# -------------------------------------------------
has_chain_db() {
  [ -d "${DATA_DIR}/blockstore.db" ] || [ -d "${DATA_DIR}/state.db" ]
}

download_genesis() {
  echo "⬇️  Downloading genesis"
  mkdir -p "${CONFIG_DIR}"
  wget -qO "${CONFIG_DIR}/genesis.json" "${GENESIS_URL}"
}

fetch_snapshot_name() {
  curl -s -H "x-polkachu: ${POLKACHU_SECRET}" "${SNAPSHOT_API}" | jq -r '.snapshot.name'
}

restore_snapshot_latest() {
  echo "📦 Restoring latest snapshot from Polkachu..."

  SNAPSHOT_NAME="$(fetch_snapshot_name)"

  if [ -z "${SNAPSHOT_NAME}" ] || [ "${SNAPSHOT_NAME}" = "null" ]; then
    echo "❌ Failed to get snapshot name"
    exit 1
  fi

  SNAPSHOT_URL="${SNAPSHOT_BASE_URL}/${SNAPSHOT_NAME}"
  echo "⬇️  Snapshot: ${SNAPSHOT_NAME}"
  echo "🔗 ${SNAPSHOT_URL}"

  bitsongd tendermint unsafe-reset-all \
    --home "${DAEMON_HOME}" \
    --keep-addr-book || true

  rm -rf "${DATA_DIR}" || true

  wget -qO- "${SNAPSHOT_URL}" | lz4 -dc | tar -x -C "${DAEMON_HOME}"

  if ! has_chain_db; then
    echo "❌ Snapshot extracted but chain DB not found"
    exit 1
  fi

  touch "${MARKER_FILE}"
  echo "✅ Snapshot restore completed"
}

# =================================================
# 1) INIT HOME (ONE TIME)
# =================================================
INIT_DONE="false"

if [ ! -f "${CONFIG_DIR}/config.toml" ]; then
  echo "🔧 bitsongd init (first run)"
  bitsongd init "${MONIKER}" \
    --chain-id "${CHAIN_ID}" \
    --home "${DAEMON_HOME}"
  INIT_DONE="true"
else
  echo "✅ Home already initialized"
fi

# =================================================
# 2) GENESIS (ONE TIME)
# =================================================
if [ ! -f "${CONFIG_DIR}/genesis.json" ]; then
  download_genesis
else
  echo "✅ Genesis already present"
fi

# =================================================
# 3) CONFIG TUNING (ONLY AFTER INIT)
# =================================================
if [ "${INIT_DONE}" = "true" ]; then
  echo "🛠  Applying initial config tuning"

  PEERS="ff89f8ed0b53c5ac094c7e0c5b090855e3a40994@65.109.115.100:26989,2c7c42ed5e67343b5b09b8d4dcc933af3c807dd4@65.108.6.54:31656,c2192dc5056252bee8621ed86ea4e1a9d1d17615@65.108.98.235:26256,b150ba00b37bdd90b8d991c10b9c65506f8171cd@65.108.77.220:3000,171b6e944c314485c8ab2a5a70fcb8bbd11538d7@157.90.255.143:26656,7860c9dea7ee0dd902b10c57c790243b51c7c054@42.200.77.5:11256,bca36344413fbfe8374111f6f77b4861f29f00d3@37.27.59.245:56656,cd4a8164f9f0657ec7a765f19ad017fb5016cd4a@65.109.92.241:21036,7053a0374e06e7b6e0479002d1a05f53afb67790@62.109.12.16:26656,50503012f492693342dd3a0aa938c3df292f5556@217.182.198.128:26256,58ca294709d0d770c6ce92a6ad8f7ca9d89beebf@57.128.22.214:16056,79ec0d17fc4d7b2e26a614f30fc308a77733e821@88.99.184.249:26656,230506dc5d654c2f8f6d210448e1fa0671bec84d@138.201.250.242:31656,9c9f030298bdda9ca69de7db8e9a3aef33972fba@142.132.131.249:31656,fa932748b327fdde6d235b28a9850f8b8bd3326a@178.63.93.41:31656,250e24ae5d53e8f3034b1b99d96b31a0cf40999d@144.76.30.36:15631,f6436007fba6e9dfd22772bfdbff613f83b84491@142.132.205.94:15631,77daae739f2e8d630001a689c1ea29502b7366cd@23.88.71.195:26656,8ec4254a63c314ac307ed94d151c0272285e3c7c@136.243.153.138:26656,8786dc9305ff0799de09f2ddff795bfbda7636dd@128.140.92.64:26656,5962d87803ec85f29362d94f665a3455ac04a50d@142.132.193.150:15631,b81a1426992538f4ded93c1623b4a2b9d1d0a4e7@194.164.164.165:26656,d223f96c92632b3050300a98bf47b8e013c45de0@65.108.126.22:26706,0887905c957bc3120c007098e7fe880a5966c637@75.119.144.133:26656,5a8ea109bc202a6ad129144e263c37478bda3ad9@165.232.122.168:26656,32e7fc17e090cc3a4bf06ef1ab798162c69740c0@5.10.19.45:26656,346408bfc1c0b62bc995a516a5eb28e0677610ef@65.109.32.148:26626,32cfde4fa7e88a80c00c012117278c3cfbd3810a@65.108.131.190:24956,d4454c53b6c3ca970e38cb506de76a1598a619d8@65.108.121.190:2040,09134a5dae333d1f77d74255a5c495374632ecbd@76.120.145.23:28656,898ba0709b059594339c57e507f630ba15a18286@152.53.109.178:26626,6e93a30587671e2cecacbcbb27092809bb20249f@65.108.201.32:31656,32d28670e98d74b98e6ce53d08f360eec5c97ed9@172.110.97.189:26656,2c975162b1d06ef5e222253f728ce3b6984e69e6@65.108.238.166:16056,469ec27f5bf779b520d7562ab445bee7ea9fbab6@103.180.28.106:26656,56d594e6f6b3e0ace36e92254d2d8593e6fc142e@149.202.72.226:26656,ecf0eb57e12fa733a506c5bb39166336f8b855ac@37.187.93.206:26667,8d64d170815d2f6a07a8e297d104a53f9d7ec66d@135.181.140.213:26652,819b6299c69a473d92b42280cc2f3bd1020c9c5a@204.216.222.165:26656,2a6e496fba463af869445be228b7ff00f805241c@104.193.254.115:28656,559dc39ef605ba3f5d22bc65c85e67c58f91afed@187.85.19.21:26656,ddc282c8b4b71c686da3ec64eab253a2674ba0cb@135.181.176.161:27856,5a0f0e94d5c2009c54fbecff178a636bc1d3b4b1@142.132.252.143:26676,744b449e2dfcc5fd0a9b85c33d7363f005bed932@94.130.53.52:26636,a5ca61340cba363f99eed283ecd7fb38a9b4337f@107.155.67.202:26626,7ff8169a4edb74f736d86bc585ab35bad3d5f2d0@77.74.195.248:26656,72aa0f746e527ad84c5376c2e83d3a97332acd40@65.108.120.161:28656,de672703184c56e643a48b9466f3d45692d2b49d@185.194.239.130:26656,614c4718eec5263dfcbe537d88b885cdb70ffe27@95.217.198.248:26666,e0ffbf9c725ad11637c19f8c49491d44f4006d1f@185.144.83.158:26656,a369636384b7700e524988f55320ba52b17a2c06@65.109.97.249:16056,963cb2dc8eedad867488d4a0afff21a34847942a@65.109.88.251:27656,ec7a1d9d304638d5af45d21e9d3756deec66f3ee@93.44.144.46:51656,b968669d3c5b75dd809268301a6648dbe8ec0685@171.224.178.224:12656,6e2843fd3d49b3319cc2d377027d0827b66f88bf@103.19.25.132:26656,e5b9490d6d32c16d8e597510790e26b32bf808a2@65.21.136.219:26656"
  sed -i.bak "s/^persistent_peers *=.*/persistent_peers = \"${PEERS}\"/" \
    "${CONFIG_DIR}/config.toml" || true

  sed -i.bak -E 's|^enable *= *false|enable = true|' \
    "${CONFIG_DIR}/app.toml" || true

  sed -i.bak -E 's|127.0.0.1:1317|0.0.0.0:1317|' \
    "${CONFIG_DIR}/app.toml" || true

  sed -i.bak -E 's|127.0.0.1:26657|0.0.0.0:26657|' \
    "${CONFIG_DIR}/config.toml" || true

  sed -i.bak -E 's|^prometheus *= *false|prometheus = true|' \
    "${CONFIG_DIR}/config.toml" || true

  sed -i.bak -E 's|^prometheus_listen_addr *=.*|prometheus_listen_addr = "0.0.0.0:26660"|' \
    "${CONFIG_DIR}/config.toml" || true

  echo "✅ Initial config tuning done"
else
  echo "✅ Skipping config tuning"
fi

# =================================================
# 4) SNAPSHOT LOGIC (KEY PART)
# =================================================

# If marker exists but DB missing → fix
if [ -f "${MARKER_FILE}" ] && ! has_chain_db; then
  echo "⚠️  Marker exists but DB missing → removing marker"
  rm -f "${MARKER_FILE}"
fi

if [ "${INIT_DONE}" = "true" ]; then
  echo "🆕 Fresh init → snapshot is mandatory"
  restore_snapshot_latest
else
  if has_chain_db; then
    echo "✅ Chain DB exists → no snapshot needed"
  else
    echo "📦 Chain DB missing → restoring snapshot"
    restore_snapshot_latest
  fi
fi

# =================================================
# 5) PERMISSIONS
# =================================================
echo "🔐 Fixing permissions"
chown -R 1000:1000 "${HOME_DIR}"
chmod -R g+rwX "${HOME_DIR}"

echo "✅ Init completed"
