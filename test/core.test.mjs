import test from 'node:test';
import assert from 'node:assert/strict';
import channels from '../src/channels.json' with { type:'json' };
import {EXPECTED_FRONT_CARDS,chunks,finitePos,parseMisRow,normalizeQuotes,healthClass,sessionPhase,sessionDateCompact} from '../src/core.mjs';

const epochTPE=(isoWithOffset)=>Date.parse(isoWithOffset);

test('channel contract is exactly 112',()=>assert.equal(Object.keys(channels).length,EXPECTED_FRONT_CARDS));
test('112 channels split into exactly 2 poll requests',()=>assert.equal(chunks(Object.values(channels),80).length,2));
test('finitePos rejects MIS sentinel',()=>{assert.equal(finitePos('-'),null);assert.equal(finitePos('0'),null);assert.equal(finitePos('123.5'),123.5)});
test('parse TSE row',()=>{const q=parseMisRow({c:'2330',ex:'tse',d:'20260907',t:'10:00:00',z:'1234'});assert.equal(q.channel,'tse_2330.tw');assert.equal(q.last_price,1234)});
test('TPE phase boundaries',()=>{
  assert.equal(sessionPhase(epochTPE('2026-09-07T08:59:59+08:00')),'PREOPEN');
  assert.equal(sessionPhase(epochTPE('2026-09-07T09:00:00+08:00')),'POLL');
  assert.equal(sessionPhase(epochTPE('2026-09-07T13:29:59+08:00')),'POLL');
  assert.equal(sessionPhase(epochTPE('2026-09-07T13:30:00+08:00')),'FINALIZE');
  assert.equal(sessionPhase(epochTPE('2026-09-07T13:36:00+08:00')),'CLOSED');
});
test('session date is Taipei date',()=>assert.equal(sessionDateCompact(epochTPE('2026-09-07T10:00:00+08:00')),'20260907'));
test('prior-day quotes do not count as same-day',()=>{
  const sid=Object.keys(channels)[0]; const market=channels[sid].startsWith('tse_')?'tse':'otc';
  const q=normalizeQuotes([{c:sid,ex:market,d:'20260906',t:'13:30:00',z:'10'}],channels,'20260907');
  assert.equal(q.sameDayValid.length,0);
});
test('health gate is fail-closed below 90%',()=>{const h=healthClass({allRequestsOk:true,returnedUnique:100,sameDayValid:100});assert.notEqual(h.state,'HEALTHY')});
test('health gate passes at 112/112 same-day valid',()=>{const h=healthClass({allRequestsOk:true,returnedUnique:112,sameDayValid:112});assert.equal(h.state,'HEALTHY')});
