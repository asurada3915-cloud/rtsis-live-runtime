#!/usr/bin/env bash
set -euo pipefail

BUILD="P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0"
GATE_BUILD="P10_PRE_WEB_GATE_V0_1_0"
WORKER_URL="${P10_WORKER_URL:-https://rtsis-p10-live-runtime-resilience-pilot-v0-1-0.asurada3915.workers.dev}"
TOKEN_FILE="${P10_READ_TOKEN_FILE:-.rtsis_p10_read_token.local}"
CONFIG="${P10_WRANGLER_CONFIG:-wrangler.jsonc}"
OUT="${P10_GATE_REPORT:-P10_PRE_WEB_GATE_REPORT.json}"

fail(){
  printf '\nFAIL_CLOSED: %s\n' "$1" >&2
  python3 - "$OUT" "$GATE_BUILD" "$BUILD" "$1" <<'PY'
import json,sys,datetime
out,gate,build,reason=sys.argv[1:]
obj={"schema":"RTSIS_P10_PRE_WEB_GATE_REPORT_V0_1_0","gate_build":gate,"runtime_build":build,
     "status":"FAIL_CLOSED","reason":reason,"checked_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
     "protected_surfaces":{"PageShare":"NO_CHANGE","Production":"NO_CHANGE","LATEST_CERTIFIED":"NO_CHANGE","Frozen":"NO_CHANGE","Historical":"NO_CHANGE"}}
open(out,'w').write(json.dumps(obj,ensure_ascii=False,indent=2)+"\n")
PY
  exit 1
}

command -v python3 >/dev/null || fail "PYTHON3_REQUIRED"
command -v curl >/dev/null || fail "CURL_REQUIRED"

printf '%s\n' "================================================================"
printf '%s\n' "RTSIS P10 PRE-WEB GATE v0.1.0"
printf '%s\n' "READ-ONLY validation only｜NO deploy｜NO PageShare change"
printf '%s\n' "================================================================"

# 1) Local contract / config checks
[ -f "$CONFIG" ] || fail "WRANGLER_CONFIG_MISSING::$CONFIG"
grep -q '"name"[[:space:]]*:[[:space:]]*"rtsis-p10-live-runtime-resilience-pilot-v0-1-0"' "$CONFIG" || fail "WORKER_NAME_MISMATCH"
grep -q '"binding"[[:space:]]*:[[:space:]]*"P10_LIVE"' "$CONFIG" || fail "KV_BINDING_MISSING"
! grep -q 'REPLACE_WITH_PILOT_KV_NAMESPACE_ID' "$CONFIG" || fail "KV_PLACEHOLDER_NOT_REPLACED"
grep -Fq '"* 1-4 * * *"' "$CONFIG" || fail "CRON_0900_1259_MISSING"
grep -Fq '"0-35 5 * * *"' "$CONFIG" || fail "CRON_1300_1335_MISSING"

# 2) Auth presence checks WITHOUT printing secrets
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || fail "CLOUDFLARE_API_TOKEN_MISSING"
[ -f "$TOKEN_FILE" ] || fail "LOCAL_READ_TOKEN_FILE_MISSING::$TOKEN_FILE"
[ "$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%Lp' "$TOKEN_FILE")" = "600" ] || fail "LOCAL_READ_TOKEN_FILE_MODE_NOT_600"
READ_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
[ ${#READ_TOKEN} -ge 32 ] || fail "LOCAL_READ_TOKEN_TOO_SHORT"

# 3) Public root contract
ROOT_FILE="$(mktemp)"; HEALTH_FILE="$(mktemp)"; SNAP_FILE="$(mktemp)"
trap 'rm -f "$ROOT_FILE" "$HEALTH_FILE" "$SNAP_FILE"' EXIT
ROOT_CODE="$(curl -sS -o "$ROOT_FILE" -w '%{http_code}' "$WORKER_URL/" || true)"
[ "$ROOT_CODE" = "200" ] || fail "WORKER_ROOT_HTTP_$ROOT_CODE"
python3 - "$ROOT_FILE" <<'PY' || exit $?
import json,sys
x=json.load(open(sys.argv[1]))
assert x.get('build_id')=='P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0', 'ROOT_BUILD_ID_MISMATCH'
assert x.get('scope')=='TRANSPORT_AND_RUNTIME_RESILIENCE_ONLY', 'ROOT_SCOPE_MISMATCH'
assert x.get('production') is False, 'ROOT_PRODUCTION_FLAG_BAD'
assert x.get('decision_effect')=='NONE', 'ROOT_DECISION_EFFECT_BAD'
PY

# 4) Auth gate must reject missing token
UNAUTH_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$WORKER_URL/snapshot" || true)"
[ "$UNAUTH_CODE" = "401" ] || fail "SNAPSHOT_UNAUTH_GATE_BAD_HTTP_$UNAUTH_CODE"

# 5) Read health + authorized snapshot
HEALTH_CODE="$(curl -sS -o "$HEALTH_FILE" -w '%{http_code}' "$WORKER_URL/health" || true)"
SNAP_CODE="$(curl -sS -H "Authorization: Bearer $READ_TOKEN" -o "$SNAP_FILE" -w '%{http_code}' "$WORKER_URL/snapshot" || true)"

python3 - "$HEALTH_FILE" "$HEALTH_CODE" "$SNAP_FILE" "$SNAP_CODE" "$OUT" "$WORKER_URL" <<'PY'
import json,sys,datetime,re
hf,hc,sf,sc,out,url=sys.argv[1:]
now=datetime.datetime.now(datetime.timezone.utc)
tpe=now+datetime.timedelta(hours=8)
report={
 "schema":"RTSIS_P10_PRE_WEB_GATE_REPORT_V0_1_0",
 "gate_build":"P10_PRE_WEB_GATE_V0_1_0",
 "runtime_build":"P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0",
 "worker_url":url,
 "checked_at_utc":now.isoformat(),
 "checked_at_tpe":tpe.isoformat(),
 "checks":{
   "config_contract":"PASS","cloudflare_api_token_present":"PASS","read_token_local_present":"PASS",
   "worker_root_contract":"PASS","snapshot_auth_gate":"PASS"
 },
 "protected_surfaces":{"PageShare":"NO_CHANGE","Production":"NO_CHANGE","LATEST_CERTIFIED":"NO_CHANGE","Frozen":"NO_CHANGE","Historical":"NO_CHANGE"},
 "web_integration_authorized":False,
}

def load_if(path):
    try:return json.load(open(path))
    except:return None
health=load_if(hf) if hc=='200' else None
snap=load_if(sf) if sc=='200' else None
report['http']={'health':int(hc or 0),'snapshot_authorized':int(sc or 0)}
report['health']=health

# Before the first real scheduled tick, 404/404 is an expected waiting state.
if hc=='404' and sc=='404':
    report['status']='PASS_PRE_WEB_INFRA_READY__WAITING_REAL_SESSION'
    report['reason']='NO_RUNTIME_SNAPSHOT_YET__EXPECTED_BEFORE_FIRST_REAL_SESSION_TICK'
    report['next_gate']='RUN_DURING_OR_AFTER_FIRST_REAL_SESSION'
    open(out,'w').write(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('PASS_PRE_WEB_INFRA_READY__WAITING_REAL_SESSION')
    print('No snapshot yet. This is expected before the first real scheduled session tick.')
    sys.exit(0)

if sc!='200':
    report['status']='FAIL_CLOSED'
    report['reason']=f'AUTHORIZED_SNAPSHOT_HTTP_{sc}'
    open(out,'w').write(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('FAIL_CLOSED: '+report['reason'])
    sys.exit(2)

# Snapshot semantic validation.
errors=[]
exp={
 'schema':'RTSIS_P10_LIVE_RUNTIME_RESILIENCE_SNAPSHOT_V0_1_0',
 'build_id':'P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0',
 'base_analysis_asof':'2026-09-04',
 'base_generation_id':'2026-09-04_da74c1422be6',
 'expected_front_cards':112,
 'decision_effect':'NONE',
 'ranking_recompute':False,'model_fit':False,'threshold_retune':False,
 'production_write':False,'latest_pointer_move':False,'auto_order':False,
}
for k,v in exp.items():
    if snap.get(k)!=v: errors.append(f'{k}={snap.get(k)!r} expected {v!r}')
if snap.get('phase') not in ('POLL','FINALIZE'): errors.append(f"phase={snap.get('phase')}")
if snap.get('session_date') is None: errors.append('session_date_missing')
quotes=snap.get('quotes') or {}
if not isinstance(quotes,dict): errors.append('quotes_not_object'); quotes={}
if len(quotes)!=int(snap.get('same_day_valid_last_price') or 0): errors.append('quotes_count_mismatch')
for sid,q in list(quotes.items())[:112]:
    if not re.fullmatch(r'\d{4,6}',str(sid)): errors.append(f'bad_stock_id::{sid}')
    try:
        if float(q.get('p',0))<=0: errors.append(f'bad_price::{sid}')
    except: errors.append(f'bad_price::{sid}')

report['snapshot_summary']={k:snap.get(k) for k in ['observed_at','session_date','phase','feed_state','feed_reason','expected_front_cards','returned_unique','same_day_rows','same_day_valid_last_price','transport_coverage','same_day_coverage','base_generation_id']}
report['snapshot_quote_count']=len(quotes)

# A real-session PASS requires healthy >=90% coverage and same-day prices.
healthy=(snap.get('feed_state')=='HEALTHY' and float(snap.get('transport_coverage') or 0)>=0.90 and float(snap.get('same_day_coverage') or 0)>=0.90 and int(snap.get('returned_unique') or 0)>=101 and int(snap.get('same_day_valid_last_price') or 0)>=101)
if errors:
    report['status']='FAIL_CLOSED'
    report['reason']='SNAPSHOT_CONTRACT_VIOLATION'
    report['errors']=errors
    open(out,'w').write(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('FAIL_CLOSED: SNAPSHOT_CONTRACT_VIOLATION')
    for e in errors: print(' -',e)
    sys.exit(3)
if not healthy:
    report['status']='WAITING_REAL_SESSION_HEALTHY_GATE'
    report['reason']='SNAPSHOT_EXISTS_BUT_HEALTH_GATE_NOT_YET_PASS'
    open(out,'w').write(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print('WAITING_REAL_SESSION_HEALTHY_GATE')
    print(json.dumps(report['snapshot_summary'],ensure_ascii=False,indent=2))
    sys.exit(0)

report['status']='PASS_REAL_SESSION__READY_FOR_WEB_INTEGRATION'
report['reason']='HEALTHY_SAME_DAY_SNAPSHOT_AND_CONTRACT_PASS'
report['web_integration_authorized']=True
open(out,'w').write(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('PASS_REAL_SESSION__READY_FOR_WEB_INTEGRATION')
print(json.dumps(report['snapshot_summary'],ensure_ascii=False,indent=2))
PY

echo
echo "Report: $OUT"
echo "No deploy performed. No PageShare change performed."
