import channels from './channels.json' with { type: 'json' };
import {
  EXPECTED_FRONT_CARDS, MAX_CHANNELS_PER_REQUEST, BASE_GENERATION_ID,
  chunks, normalizeQuotes, healthClass, buildSnapshot, sessionPhase, sessionDateCompact,
} from './core.mjs';

const MIS_HOME='https://mis.twse.com.tw/stock/index.jsp';
const MIS_API='https://mis.twse.com.tw/stock/api/getStockInfo.jsp';
const KEY_SNAPSHOT='p10:runtime:snapshot:v0_1_0';
const KEY_HEALTH='p10:runtime:health:v0_1_0';

if(Object.keys(channels).length!==EXPECTED_FRONT_CARDS){
  throw new Error(`CHANNEL_COUNT_MISMATCH::${Object.keys(channels).length}`);
}

function jsonResponse(obj,status=200,extra={}){
  return new Response(JSON.stringify(obj),{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store',...extra}});
}

function cors(req){
  const origin=req.headers.get('origin');
  const allowed=(origin && origin===req.cf?.host)?origin:null;
  return allowed?{'access-control-allow-origin':allowed}:{};
}

function bearerOk(req,env){
  const token=env.READ_TOKEN;
  if(!token) return false;
  return req.headers.get('authorization')===`Bearer ${token}`;
}

async function fetchMisGroup(group,cookie){
  const u=new URL(MIS_API);
  u.searchParams.set('ex_ch',group.join('|'));
  u.searchParams.set('json','1');
  u.searchParams.set('delay','0');
  u.searchParams.set('_',String(Date.now()));
  const h={
    'accept':'application/json,text/plain,*/*',
    'accept-language':'zh-TW,zh;q=0.9,en;q=0.7',
    'referer':MIS_HOME,
    'cache-control':'no-cache',
    'pragma':'no-cache',
  };
  if(cookie) h.cookie=cookie;
  const t0=Date.now();
  try{
    const r=await fetch(u,{headers:h});
    const txt=await r.text();
    let payload=null;
    try{payload=JSON.parse(txt)}catch{}
    const rows=Array.isArray(payload?.msgArray)?payload.msgArray:[];
    const rtcode=String(payload?.rtcode??'');
    const ok=r.status===200 && Array.isArray(payload?.msgArray) && (rtcode===''||rtcode==='0000');
    return {ok,rows,meta:{http_status:r.status,rtcode,requested_channels:group.length,returned_rows:rows.length,elapsed_ms:Date.now()-t0,error:payload?null:'NON_JSON_RESPONSE'}};
  }catch(e){
    return {ok:false,rows:[],meta:{http_status:0,requested_channels:group.length,returned_rows:0,elapsed_ms:Date.now()-t0,error:`FETCH_EXCEPTION::${e?.name||'Error'}`}};
  }
}

async function collectOnce(nowMs){
  let cookie='';
  try{
    const home=await fetch(MIS_HOME,{headers:{'accept':'text/html,*/*'}});
    cookie=home.headers.get('set-cookie')||'';
  }catch{}
  const groups=chunks(Object.values(channels),MAX_CHANNELS_PER_REQUEST);
  const results=await Promise.all(groups.map(g=>fetchMisGroup(g,cookie)));
  const rows=results.flatMap(r=>r.rows);
  const quotes=normalizeQuotes(rows,channels,sessionDateCompact(nowMs));
  const allRequestsOk=results.every(r=>r.ok);
  const health=healthClass({allRequestsOk,returnedUnique:Object.keys(quotes.byId).length,sameDayValid:quotes.sameDayValid.length});
  const snapshot=buildSnapshot({nowMs,quotes,health,requestMeta:results.map(r=>r.meta)});
  return {health,snapshot};
}

async function scheduledTick(env,nowMs){
  const phase=sessionPhase(nowMs);
  if(phase==='PREOPEN'||phase==='CLOSED') return {status:'NOOP',phase};
  if(phase==='FINALIZE'){
    const prior=await env.P10_LIVE.get(KEY_SNAPSHOT,{type:'json'});
    const final={schema:'RTSIS_P10_LIVE_RUNTIME_RESILIENCE_FINALIZE_V0_1_0',build_id:'P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0',phase:'FINALIZE',observed_at:new Date(nowMs).toISOString(),base_generation_id:BASE_GENERATION_ID,last_snapshot_at:prior?.observed_at??null,decision_effect:'NONE'};
    await env.P10_LIVE.put(KEY_HEALTH,JSON.stringify(final));
    return {status:'FINALIZE',phase,last_snapshot_at:prior?.observed_at??null};
  }
  const {health,snapshot}=await collectOnce(nowMs);
  // Two KV writes per minute during normal session: ~540/day, below current Free 1,000 writes/day.
  await Promise.all([
    env.P10_LIVE.put(KEY_SNAPSHOT,JSON.stringify(snapshot)),
    env.P10_LIVE.put(KEY_HEALTH,JSON.stringify({schema:'RTSIS_P10_LIVE_RUNTIME_HEALTH_V0_1_0',build_id:snapshot.build_id,observed_at:snapshot.observed_at,session_date:snapshot.session_date,phase:snapshot.phase,feed_state:snapshot.feed_state,feed_reason:snapshot.feed_reason,returned_unique:snapshot.returned_unique,same_day_valid_last_price:snapshot.same_day_valid_last_price,base_generation_id:BASE_GENERATION_ID,decision_effect:'NONE'})),
  ]);
  return {status:'POLL',phase,feed_state:health.state,returned_unique:snapshot.returned_unique,same_day_valid_last_price:snapshot.same_day_valid_last_price};
}

export default {
  async scheduled(controller,env,ctx){
    ctx.waitUntil(scheduledTick(env,controller.scheduledTime));
  },
  async fetch(req,env){
    const u=new URL(req.url);
    if(u.pathname==='/health'){
      const obj=await env.P10_LIVE.get(KEY_HEALTH,{type:'json'});
      return jsonResponse(obj??{status:'NO_HEALTH_YET'},obj?200:404);
    }
    if(u.pathname==='/snapshot'){
      if(!bearerOk(req,env)) return jsonResponse({error:'UNAUTHORIZED'},401);
      const obj=await env.P10_LIVE.get(KEY_SNAPSHOT,{type:'json'});
      return jsonResponse(obj??{status:'NO_SNAPSHOT_YET'},obj?200:404,cors(req));
    }
    return jsonResponse({service:'RTSIS P10 Live Runtime Resilience Pilot',build_id:'P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0',scope:'TRANSPORT_AND_RUNTIME_RESILIENCE_ONLY',production:false,decision_effect:'NONE'});
  },
};

export { scheduledTick };
