#!/usr/bin/env bash
set -euo pipefail

BUILD="P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0"
CONFIG="wrangler.jsonc"
PLACEHOLDER="REPLACE_WITH_PILOT_KV_NAMESPACE_ID"
TOKEN_FILE=".rtsis_p10_read_token.local"

echo "================================================================"
echo "RTSIS P10 Live Runtime Resilience Pilot v0.1.0"
echo "DEPLOY-ONCE｜Cloudflare Worker only｜NO PageShare / Production write"
echo "================================================================"

command -v node >/dev/null || { echo "ERROR: node is required"; exit 1; }
command -v npm >/dev/null || { echo "ERROR: npm is required"; exit 1; }

echo "[1/8] Install dependencies"
npm install

echo "[2/8] Static checks"
npm run check
npm test

echo "[3/8] Cloudflare authentication"
if ! npx wrangler whoami >/dev/null 2>&1; then
  echo "Cloudflare login is required. Your browser will open."
  npx wrangler login
fi
npx wrangler whoami

echo "[4/8] Create isolated pilot KV namespace"
if grep -q "$PLACEHOLDER" "$CONFIG"; then
  set +e
  KV_OUT="$(npx wrangler kv namespace create P10_LIVE 2>&1)"
  KV_RC=$?
  set -e
  printf '%s\n' "$KV_OUT"
  if [ "$KV_RC" -ne 0 ]; then
    echo "ERROR: KV namespace creation failed."
    exit "$KV_RC"
  fi

  KV_ID="$(printf '%s\n' "$KV_OUT" | grep -Eo '[0-9a-fA-F]{32}' | tail -n 1 || true)"
  if [ -z "$KV_ID" ]; then
    echo
    echo "Could not parse the namespace ID automatically."
    read -r -p "Paste only the 32-character KV namespace ID: " KV_ID
  fi

  if ! printf '%s' "$KV_ID" | grep -Eq '^[0-9a-fA-F]{32}$'; then
    echo "ERROR: invalid KV namespace ID format."
    exit 1
  fi

  python3 - "$CONFIG" "$PLACEHOLDER" "$KV_ID" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1])
old=sys.argv[2]
new=sys.argv[3]
s=p.read_text()
if s.count(old)!=1:
    raise SystemExit(f"ERROR: expected exactly one KV placeholder, found {s.count(old)}")
p.write_text(s.replace(old,new,1))
print("Patched wrangler.jsonc with pilot KV namespace ID.")
PY
else
  echo "KV placeholder already replaced; preserving existing binding."
fi

echo "[5/8] Wrangler dry-run"
npx wrangler deploy --dry-run

echo "[6/8] Deploy isolated Worker"
DEPLOY_OUT="$(npx wrangler deploy 2>&1 | tee /dev/stderr)"
WORKER_URL="$(printf '%s\n' "$DEPLOY_OUT" | grep -Eo 'https://[A-Za-z0-9._-]+\.workers\.dev' | tail -n 1 || true)"
if [ -z "$WORKER_URL" ]; then
  echo
  read -r -p "Paste the deployed workers.dev URL shown by Wrangler: " WORKER_URL
fi

echo "[7/8] Set READ_TOKEN secret"
if [ ! -f "$TOKEN_FILE" ]; then
  umask 077
  if command -v openssl >/dev/null; then
    openssl rand -hex 32 > "$TOKEN_FILE"
  else
    python3 - <<'PY' > "$TOKEN_FILE"
import secrets
print(secrets.token_hex(32))
PY
  fi
  chmod 600 "$TOKEN_FILE"
fi
READ_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
printf '%s\n' "$READ_TOKEN" | npx wrangler secret put READ_TOKEN >/dev/null
echo "READ_TOKEN stored as Worker secret."
echo "Local operator copy: $TOKEN_FILE (mode 600). Do not publish or embed in PageShare."

echo "[8/8] Read-only verification"
echo "Health:"
curl -fsS "$WORKER_URL/health" || true
echo
echo "Snapshot (may be 404 before first valid session tick):"
curl -fsS -H "Authorization: Bearer $READ_TOKEN" "$WORKER_URL/snapshot" || true
echo

cat <<EOF

================================================================
DEPLOY COMPLETE — PILOT ONLY
Build: $BUILD
Worker: $WORKER_URL
Protected RTSIS surfaces touched: NONE by this script
PageShare touched: NO
LATEST_CERTIFIED touched: NO
Production/Frozen/Historical touched: NO

Keep this URL for runtime evidence:
$WORKER_URL

Do not copy $TOKEN_FILE into chat, Git, PageShare, or any public file.
================================================================
EOF
