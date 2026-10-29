#!/usr/bin/env bash
# Runs the end-to-end test (examples/e2e_regtest.rs) on a throwaway local
# regtest network: starts bitcoind and the backend, runs the test, then
# stops both. Needs bitcoind on PATH and a local Postgres.
#
#   scripts/e2e-regtest.sh            # Postgres at postgres://$USER@localhost:5432
#   PGPORT=5433 scripts/e2e-regtest.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PGPORT="${PGPORT:-5432}"
WORK="$(mktemp -d)"
RPC_PORT=18443
DB=scorchepay_e2e
export ADMIN_TOKEN="e2e-admin-$(openssl rand -hex 8)"

cleanup() {
  [[ -n "${BACKEND_PID:-}" ]] && kill "$BACKEND_PID" 2>/dev/null && wait "$BACKEND_PID" 2>/dev/null || true
  bitcoin-cli -regtest -rpcport=$RPC_PORT -rpcuser=scorche -rpcpassword=scorche stop >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "• bitcoind (regtest) in $WORK"
bitcoind -regtest -daemon -datadir="$WORK" -rpcport=$RPC_PORT -rpcuser=scorche -rpcpassword=scorche \
  -fallbackfee=0.0002 -txindex=1 -listen=0 >/dev/null
until bitcoin-cli -regtest -rpcport=$RPC_PORT -rpcuser=scorche -rpcpassword=scorche getblockchaininfo >/dev/null 2>&1; do sleep 0.5; done

echo "• fresh database $DB"
dropdb -h localhost -p "$PGPORT" --if-exists "$DB"
createdb -h localhost -p "$PGPORT" "$DB"

echo "• building"
cargo build --quiet --example e2e_regtest
cargo build --quiet

echo "• backend on :8181 (regtest, fake providers)"
# FALLBACK_NGN_PER_BTC below only keeps this test working without internet;
# with a connection the live price is used.
PORT=8181 \
DATABASE_URL="postgres://$USER@localhost:$PGPORT/$DB" \
JWT_SECRET="$(openssl rand -hex 32)" \
OTP_DEV_CODE=123456 \
BITCOIN_NETWORK=regtest \
BITCOIND_RPC="scorche:scorche@127.0.0.1:$RPC_PORT" \
LDK_STORAGE_DIR="$WORK/ldk" \
LDK_LISTEN_PORT=9737 \
RGS_URL= \
FALLBACK_NGN_PER_BTC=165000000 \
VTU_PROVIDER=fake BILLS_PROVIDER=fake KYC_PROVIDER=fake \
RUST_LOG=info,ldk_node=warn \
  ./target/debug/scorchepay-backend >"$WORK/backend.log" 2>&1 &
BACKEND_PID=$!
until curl -sf http://127.0.0.1:8181/health >/dev/null; do
  kill -0 "$BACKEND_PID" 2>/dev/null || { cat "$WORK/backend.log"; exit 1; }
  sleep 0.5
done

echo
if ! ./target/debug/examples/e2e_regtest; then
  echo; echo "Backend log:"; tail -40 "$WORK/backend.log"; exit 1
fi
