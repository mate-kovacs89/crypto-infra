/**
 * External health monitor for the live bot-node container.
 *
 * EventBridge fires this Lambda every 2 minutes. The handler:
 *   1. Calls DescribeInstances on the live EC2 to learn its state +
 *      current public IP (the instance has no Elastic IP, so the IP
 *      rotates on every restart).
 *   2. Interprets the state:
 *        - ``running``        → HTTP probe the /healthz endpoint
 *        - ``stopped``/``stopping`` → POST PagerDuty resolve (user
 *          deliberately shut the VM; close any open incident)
 *        - ``pending``        → no-op (booting)
 *        - ``terminated``/``shutting-down`` → POST PagerDuty trigger
 *          (infra is gone, a human needs to look)
 *   3. HTTP probe (if state=running): up to 3 attempts, 15 s gap, 5 s
 *      timeout. First 200 → resolve. All fail → trigger. The gap+timeout
 *      total stays well inside the Lambda 90 s timeout budget.
 *
 * State is NOT persisted anywhere (DynamoDB, env var). PagerDuty de-dups
 * triggers by ``incident_key`` and ignores resolves when no incident is
 * open, so "fire trigger/resolve every tick" is safe and idempotent.
 */

import { DescribeInstancesCommand, EC2Client } from "@aws-sdk/client-ec2";
import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

// ── Config (env-driven) ─────────────────────────────────────────────
const INSTANCE_ID = process.env.LIVE_EC2_INSTANCE_ID;
const HEALTHZ_PORT = process.env.HEALTHZ_PORT ?? "3000";
const HEALTHZ_PATH = process.env.HEALTHZ_PATH ?? "/healthz";
const PROBE_TIMEOUT_MS = Number(process.env.PROBE_TIMEOUT_MS ?? "5000");
const PROBE_RETRIES = Number(process.env.PROBE_RETRIES ?? "3");
const PROBE_GAP_MS = Number(process.env.PROBE_GAP_MS ?? "15000");
const DEDUP_KEY = process.env.PAGERDUTY_DEDUP_KEY ?? "live-bot-health";
const PAGERDUTY_SSM_PARAM =
  process.env.PAGERDUTY_SSM_PARAM ?? "/crypto-bot/pagerduty/integration_key";
const PAGERDUTY_EVENTS_URL =
  process.env.PAGERDUTY_EVENTS_URL ??
  "https://events.eu.pagerduty.com/generic/2010-04-15/create_event.json";
const AWS_REGION = process.env.AWS_REGION ?? "eu-north-1";

// ── AWS clients (reused across warm invocations) ────────────────────
const defaultClients = {
  ec2: new EC2Client({ region: AWS_REGION }),
  ssm: new SSMClient({ region: AWS_REGION }),
};

// ── Cached integration key (TTL = Lambda container lifetime) ────────
let cachedIntegrationKey = null;

async function getIntegrationKey(ssm) {
  if (cachedIntegrationKey) return cachedIntegrationKey;
  const res = await ssm.send(
    new GetParameterCommand({ Name: PAGERDUTY_SSM_PARAM, WithDecryption: true })
  );
  const value = res.Parameter?.Value;
  if (!value) throw new Error(`SSM parameter ${PAGERDUTY_SSM_PARAM} empty`);
  cachedIntegrationKey = value;
  return value;
}

// Reset helper — used only by tests to prevent caching across cases.
export function __resetCacheForTest() {
  cachedIntegrationKey = null;
}

async function describeInstance(ec2) {
  const res = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [INSTANCE_ID] }));
  const inst = res.Reservations?.[0]?.Instances?.[0];
  return {
    state: inst?.State?.Name ?? "unknown",
    publicIp: inst?.PublicIpAddress ?? null,
    stateReason: inst?.StateTransitionReason ?? "",
  };
}

async function httpProbe(url, timeoutMs, fetchImpl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { signal: controller.signal });
    return { ok: res.ok, status: res.status };
  } catch (err) {
    return { ok: false, status: 0, error: String(err) };
  } finally {
    clearTimeout(timer);
  }
}

async function probeWithRetry(url, fetchImpl, sleep) {
  const attempts = [];
  for (let i = 0; i < PROBE_RETRIES; i++) {
    if (i > 0) await sleep(PROBE_GAP_MS);
    const result = await httpProbe(url, PROBE_TIMEOUT_MS, fetchImpl);
    attempts.push(result);
    if (result.ok) break;
  }
  return attempts;
}

async function postPagerDuty(eventType, { summary, severity, customDetails } = {}, deps) {
  const key = await getIntegrationKey(deps.ssm);
  const payload = { service_key: key, event_type: eventType, incident_key: DEDUP_KEY };
  if (eventType === "trigger") {
    payload.description = `[${(severity ?? "critical").toUpperCase()}] ${summary}`;
    payload.client = "aws-lambda/crypto-bot-health-monitor";
    payload.details = customDetails ?? {};
  }

  const res = await deps.fetch(PAGERDUTY_EVENTS_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "<unreadable>");
    console.error(`[healthz] PagerDuty ${eventType} HTTP ${res.status}: ${body}`);
  }
}

export async function handleTick(deps) {
  if (!INSTANCE_ID) throw new Error("LIVE_EC2_INSTANCE_ID not set");

  const { state, publicIp, stateReason } = await describeInstance(deps.ec2);
  console.log(`[healthz] state=${state} ip=${publicIp ?? "null"} reason="${stateReason}"`);

  if (state === "running") {
    if (!publicIp) {
      await postPagerDuty(
        "trigger",
        {
          summary: "Live EC2 running but has no public IP",
          severity: "critical",
          customDetails: { instance_id: INSTANCE_ID, state },
        },
        deps
      );
      return { status: "triggered_no_ip", state };
    }
    const url = `http://${publicIp}:${HEALTHZ_PORT}${HEALTHZ_PATH}`;
    const attempts = await probeWithRetry(url, deps.fetch, deps.sleep);
    const anyOk = attempts.some((a) => a.ok);
    if (anyOk) {
      await postPagerDuty("resolve", {}, deps);
      return { status: "healthy", attempts };
    }
    await postPagerDuty(
      "trigger",
      {
        summary: `Live bot container unreachable (/healthz failed ${attempts.length}×)`,
        severity: "critical",
        customDetails: {
          state,
          public_ip: publicIp,
          url,
          attempts,
          instance_id: INSTANCE_ID,
        },
      },
      deps
    );
    return { status: "unhealthy", attempts };
  }

  if (state === "stopped" || state === "stopping") {
    await postPagerDuty("resolve", {}, deps);
    return { status: "stopped", state };
  }

  if (state === "pending") {
    return { status: "pending", state };
  }

  if (state === "terminated" || state === "shutting-down") {
    await postPagerDuty(
      "trigger",
      {
        summary: `Live EC2 ${state} — infrastructure gone`,
        severity: "critical",
        customDetails: { state, state_transition_reason: stateReason, instance_id: INSTANCE_ID },
      },
      deps
    );
    return { status: "infra_gone", state };
  }

  // Unknown / transient state we haven't modelled — log + no-op so
  // we don't page and don't resolve.
  console.warn(`[healthz] unhandled state: ${state}`);
  return { status: "unknown", state };
}

export async function handler() {
  try {
    return await handleTick({
      ec2: defaultClients.ec2,
      ssm: defaultClients.ssm,
      fetch: globalThis.fetch,
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    });
  } catch (err) {
    // Never throw out of the handler — EventBridge async invocations
    // retry on error, which would double-page on every tick. Log and
    // swallow; CloudWatch alarms can watch Lambda Errors metric if we
    // want a meta-monitor later.
    console.error("[healthz] handler error:", err);
    return { status: "error", error: String(err) };
  }
}
