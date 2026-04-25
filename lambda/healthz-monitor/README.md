# healthz-monitor (AWS Lambda)

External health pinger for the live bot-node container.

The internal alerts (inference gRPC / Coinbase REST / DB ping) in
`crypto-bot-node` cannot fire when the Node process, Docker, or the
whole EC2 is down — they run *inside* the container. This Lambda lives
outside: EventBridge fires it every 2 minutes, it checks the live EC2
state and HTTP-probes `/healthz`, and it routes the result to PagerDuty
via the shared `live-bot-health` dedup key.

## State machine

| EC2 state | HTTP probe | Action |
|---|---|---|
| `running` | 200 | resolve |
| `running` | fail 3× (15 s apart) | **trigger** (container down) |
| `running` | no public IP | **trigger** (networking broken) |
| `stopped` / `stopping` | — | resolve (deliberate shutdown) |
| `pending` | — | no-op (booting) |
| `terminated` / `shutting-down` | — | **trigger** (infra gone) |

PagerDuty dedups triggers and silently ignores resolves with no open
incident, so every tick safely posts the current truth. No DynamoDB.

## Env vars

| Name | Required | Default |
|---|---|---|
| `LIVE_EC2_INSTANCE_ID` | yes | — |
| `PAGERDUTY_SSM_PARAM` | no | `/crypto-bot/pagerduty/integration_key` |
| `PAGERDUTY_EVENTS_URL` | no | EU endpoint |
| `PAGERDUTY_DEDUP_KEY` | no | `live-bot-health` |
| `HEALTHZ_PORT` | no | `3000` |
| `HEALTHZ_PATH` | no | `/healthz` |
| `PROBE_TIMEOUT_MS` | no | `5000` |
| `PROBE_RETRIES` | no | `3` |
| `PROBE_GAP_MS` | no | `15000` |

## Local

```bash
npm test         # node:test — no deps
./build.sh       # → dist/healthz-monitor.zip
```

## Deploy (first time)

Prereqs (all one-shot, created out-of-band because we don't have
Terraform for Lambda yet):

1. SSM SecureString `/crypto-bot/pagerduty/integration_key` (region
   `eu-north-1`).
2. IAM role `crypto-bot-health-monitor-role` with inline policy for
   `logs:CreateLogGroup/CreateLogStream/PutLogEvents`, `ssm:GetParameter`
   on the param, `kms:Decrypt` on the SSM default key, and
   `ec2:DescribeInstances`.
3. Lambda function `crypto-bot-health-monitor`, Node.js 22.x arm64,
   128 MB, 90 s timeout, handler `index.handler`, env vars set.
4. EventBridge rule `crypto-bot-health-monitor-schedule` with
   `rate(2 minutes)`, target = the Lambda, invoke permission.

Re-deploy code only:

```bash
./build.sh
aws lambda update-function-code \
  --function-name crypto-bot-health-monitor \
  --zip-file fileb://dist/healthz-monitor.zip \
  --region eu-north-1
```
