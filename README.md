# RTSIS P10 Live Runtime Resilience Pilot v0.1.0

## Purpose
This pilot removes Colab as the *required always-on runtime* for the intraday feed, without changing RTSIS strategy semantics.

It does **not** migrate the P10 event engine yet. It only proves:
- Cloudflare scheduled runtime remains available through the session.
- TWSE MIS can be read once per minute for the same 112 Certified front cards.
- Same-day quote gating and >=90% coverage fail-closed behavior work.
- State can be persisted to isolated Workers KV.
- No Production / LATEST_CERTIFIED / Frozen / Historical writes occur.

## Why this is staged
Existing P10 v0.1.1 FREE already has an audited event contract: trigger-zone edges, insurance latch, first-objective latch, no invented cooldown. Reimplementing that contract in a new runtime before proving the runtime itself would mix two risks. v0.1.0 therefore tests transport/resilience only. If it passes, v0.2 can port the event engine line-for-line/semantics-for-semantics.

## Runtime schedule
Cloudflare Cron is UTC. These two triggers cover Taiwan 09:00-13:35 every calendar day:
- `* 1-4 * * *`
- `0-35 5 * * *`

The Worker itself determines phase. It does not use Monday-Friday as a trading-day truth source. A quote must carry today's Taiwan date; prior-day rows cannot become valid live observations.

## Free-tier resource model
Normal session 09:00-13:30 is 270 one-minute ticks. Each successful tick writes two KV keys: snapshot + health, approximately 540 writes/day. Finalize adds a small number of health writes. This remains below the currently documented 1,000 KV writes/day free limit, but real runtime CPU and transport behavior still require evidence.

## Security in pilot
- `/health` contains only health metadata.
- `/snapshot` requires a Worker secret `READ_TOKEN`.
- Do **not** embed `READ_TOKEN` into the PageShare HTML. This pilot is not yet the final browser-auth design.

## Deployment is intentionally not performed by this package
Required before deployment:
1. Create a dedicated Cloudflare KV namespace for this pilot.
2. Replace only the `REPLACE_WITH_PILOT_KV_NAMESPACE_ID` placeholder in `wrangler.jsonc` via the setup process.
3. Set `READ_TOKEN` as a Worker secret.
4. Run local tests.
5. Deploy the pilot Worker only; do not touch PageShare.
6. Observe a real session and collect runtime evidence.

## PASS gate
Do not call this production or final P10 PASS. Pilot PASS requires:
- scheduled ticks across the target session,
- no unexplained runtime gaps,
- 112-channel contract intact,
- >=90% transport gate behavior correct,
- prior-day rows rejected,
- stale/failure behavior visible,
- Free-tier CPU/KV limits not exceeded,
- zero protected RTSIS mutations.
