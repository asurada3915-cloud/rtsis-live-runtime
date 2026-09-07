export const EXPECTED_FRONT_CARDS = 112;
export const MAX_CHANNELS_PER_REQUEST = 80;
export const MIN_TRANSPORT_COVERAGE = 0.90;
export const BASE_ANALYSIS_ASOF = '2026-09-04';
export const BASE_GENERATION_ID = '2026-09-04_da74c1422be6';
export const TRANSPORT_CLASSIFICATION = 'RESEARCH_ONLY_PUBLIC_MIS_TRANSPORT';

export function tpeParts(epochMs) {
  const d = new Date(epochMs + 8 * 60 * 60 * 1000);
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    second: d.getUTCSeconds(),
  };
}

export function sessionDateCompact(epochMs) {
  const p=tpeParts(epochMs);
  return `${p.year}${String(p.month).padStart(2,'0')}${String(p.day).padStart(2,'0')}`;
}

export function sessionDateISO(epochMs) {
  const p=tpeParts(epochMs);
  return `${p.year}-${String(p.month).padStart(2,'0')}-${String(p.day).padStart(2,'0')}`;
}

export function sessionPhase(epochMs) {
  const p=tpeParts(epochMs);
  const sec=p.hour*3600+p.minute*60+p.second;
  const start=9*3600;
  const marketEnd=13*3600+30*60;
  const finalizeEnd=13*3600+35*60+59;
  if (sec < start) return 'PREOPEN';
  if (sec < marketEnd) return 'POLL';
  if (sec <= finalizeEnd) return 'FINALIZE';
  return 'CLOSED';
}

export function chunks(arr,n=MAX_CHANNELS_PER_REQUEST){
  const out=[];
  for(let i=0;i<arr.length;i+=n) out.push(arr.slice(i,i+n));
  return out;
}

export function finitePos(v){
  if(v===null||v===undefined||v===''||v==='-') return null;
  const x=Number(v);
  return Number.isFinite(x)&&x>0?x:null;
}

export function parseMisRow(row){
  const stock_id=String(row?.c??'').trim();
  const market=String(row?.ex??'').trim().toLowerCase();
  if(!stock_id || !['tse','otc'].includes(market)) return null;
  return {
    stock_id,
    stock_name: row?.n ?? null,
    market,
    channel: `${market}_${stock_id}.tw`,
    date: String(row?.d??'').trim(),
    trade_time: String(row?.t??'').trim(),
    source_timestamp_raw: row?.tlong ?? null,
    last_price: finitePos(row?.z),
    open: finitePos(row?.o),
    high: finitePos(row?.h),
    low: finitePos(row?.l),
    prev_close: finitePos(row?.y),
    cum_volume: finitePos(row?.v),
  };
}

export function normalizeQuotes(rawRows, channelMap, sessionCompact){
  const byId={};
  for(const raw of rawRows){
    const q=parseMisRow(raw);
    if(!q) continue;
    const expected=channelMap[q.stock_id];
    if(expected && q.channel===expected) byId[q.stock_id]=q;
  }
  const values=Object.values(byId);
  const sameDay=values.filter(q=>q.date===sessionCompact);
  const sameDayValid=sameDay.filter(q=>q.last_price!==null);
  return {byId, sameDay, sameDayValid};
}

export function healthClass({allRequestsOk, returnedUnique, expected=EXPECTED_FRONT_CARDS, sameDayValid}){
  const transportCoverage=returnedUnique/expected;
  const sameDayCoverage=sameDayValid/expected;
  if(!allRequestsOk || transportCoverage < MIN_TRANSPORT_COVERAGE){
    return {state:'STALE',transportCoverage,sameDayCoverage,reason:'TRANSPORT_BELOW_GATE'};
  }
  if(sameDayCoverage < MIN_TRANSPORT_COVERAGE){
    return {state:'WAITING_OR_STALE',transportCoverage,sameDayCoverage,reason:'SAME_DAY_BELOW_GATE'};
  }
  return {state:'HEALTHY',transportCoverage,sameDayCoverage,reason:'PASS'};
}

export function buildSnapshot({nowMs, quotes, health, requestMeta}){
  return {
    schema:'RTSIS_P10_LIVE_RUNTIME_RESILIENCE_SNAPSHOT_V0_1_0',
    build_id:'P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0',
    pilot_scope:'TRANSPORT_AND_RUNTIME_RESILIENCE_ONLY__NO_EVENT_ENGINE_MIGRATION_YET',
    base_analysis_asof:BASE_ANALYSIS_ASOF,
    base_generation_id:BASE_GENERATION_ID,
    transport_classification:TRANSPORT_CLASSIFICATION,
    observed_at:new Date(nowMs).toISOString(),
    session_date:sessionDateISO(nowMs),
    phase:sessionPhase(nowMs),
    feed_state:health.state,
    feed_reason:health.reason,
    expected_front_cards:EXPECTED_FRONT_CARDS,
    returned_unique:Object.keys(quotes.byId).length,
    same_day_rows:quotes.sameDay.length,
    same_day_valid_last_price:quotes.sameDayValid.length,
    transport_coverage:Number(health.transportCoverage.toFixed(6)),
    same_day_coverage:Number(health.sameDayCoverage.toFixed(6)),
    quotes:Object.fromEntries(quotes.sameDayValid.map(q=>[q.stock_id,{p:q.last_price,t:q.trade_time,d:q.date,m:q.market}])),
    request_meta:requestMeta,
    decision_effect:'NONE',
    ranking_recompute:false,
    model_fit:false,
    threshold_retune:false,
    production_write:false,
    latest_pointer_move:false,
    auto_order:false,
  };
}
