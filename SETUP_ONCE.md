# One-time setup sequence (when the user decides to deploy)

Do not deploy until the user is at the Cloudflare account and explicitly wants to proceed.

```bash
cd RTSIS_P10_LIVE_RUNTIME_RESILIENCE_PILOT_V0_1_0
npm install
npm test
npx wrangler kv namespace create P10_LIVE
# Copy the returned namespace id into the single placeholder in wrangler.jsonc.
npx wrangler secret put READ_TOKEN
npx wrangler deploy
```

After deployment, verify:

```bash
curl https://<worker>.workers.dev/health
curl -H "Authorization: Bearer <READ_TOKEN>" https://<worker>.workers.dev/snapshot
```

No PageShare change is part of this step.
