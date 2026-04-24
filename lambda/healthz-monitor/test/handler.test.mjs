import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";

process.env.LIVE_EC2_INSTANCE_ID = "i-test";
process.env.PROBE_GAP_MS = "0"; // no delay between probes in tests
process.env.PROBE_TIMEOUT_MS = "50";

const mod = await import("../index.mjs");

function makeDeps({ state, publicIp, fetchImpl, ssmValue } = {}) {
  mod.__resetCacheForTest();
  const postedEvents = [];

  const ec2 = {
    send: mock.fn(async () => ({
      Reservations: [
        {
          Instances: [
            {
              State: { Name: state ?? "running" },
              PublicIpAddress: publicIp ?? null,
              StateTransitionReason: "test",
            },
          ],
        },
      ],
    })),
  };
  const ssm = {
    send: mock.fn(async () => ({
      Parameter: { Value: ssmValue ?? "test-pager-key" },
    })),
  };

  const defaultFetch = mock.fn(async (url, init) => {
    if (typeof url === "string" && url.includes("pagerduty")) {
      postedEvents.push(JSON.parse(init.body));
      return { ok: true, status: 200, text: async () => "OK" };
    }
    return { ok: true, status: 200, text: async () => "OK" };
  });
  const fetchFn = fetchImpl ?? defaultFetch;

  const sleep = mock.fn(async () => {});

  return { ec2, ssm, fetch: fetchFn, sleep, postedEvents };
}

describe("handleTick — state machine", () => {
  afterEach(() => {
    mod.__resetCacheForTest();
  });

  it("running + healthz 200 → resolve", async () => {
    const deps = makeDeps({ state: "running", publicIp: "1.2.3.4" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "healthy");
    assert.equal(deps.postedEvents.length, 1);
    assert.equal(deps.postedEvents[0].event_type, "resolve");
    assert.equal(deps.postedEvents[0].incident_key, "live-bot-health");
  });

  it("running + healthz fail 3× → trigger", async () => {
    const failFetch = mock.fn(async (url, init) => {
      if (typeof url === "string" && url.includes("pagerduty")) {
        return { ok: true, status: 200, text: async () => "OK" };
      }
      return { ok: false, status: 503, text: async () => "bad" };
    });
    const deps = makeDeps({ state: "running", publicIp: "1.2.3.4", fetchImpl: failFetch });
    // Inject a post-event capture for the PagerDuty call
    const postedEvents = [];
    deps.fetch = mock.fn(async (url, init) => {
      if (typeof url === "string" && url.includes("pagerduty")) {
        postedEvents.push(JSON.parse(init.body));
        return { ok: true, status: 200, text: async () => "OK" };
      }
      return { ok: false, status: 503, text: async () => "bad" };
    });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "unhealthy");
    assert.equal(out.attempts.length, 3); // all 3 retries consumed
    assert.equal(postedEvents.length, 1);
    assert.equal(postedEvents[0].event_type, "trigger");
    assert.match(postedEvents[0].description, /CRITICAL/);
    assert.equal(postedEvents[0].client, "aws-lambda/crypto-bot-health-monitor");
    assert.equal(postedEvents[0].details.public_ip, "1.2.3.4");
  });

  it("running + 1st fail, 2nd success → resolve (early exit)", async () => {
    let healthzCalls = 0;
    const postedEvents = [];
    const fetchImpl = mock.fn(async (url, init) => {
      if (typeof url === "string" && url.includes("pagerduty")) {
        postedEvents.push(JSON.parse(init.body));
        return { ok: true, status: 200, text: async () => "OK" };
      }
      healthzCalls++;
      const ok = healthzCalls >= 2;
      return { ok, status: ok ? 200 : 503, text: async () => "x" };
    });
    const deps = makeDeps({ state: "running", publicIp: "1.2.3.4", fetchImpl });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "healthy");
    assert.equal(out.attempts.length, 2);
    assert.equal(healthzCalls, 2);
    assert.equal(postedEvents.length, 1);
    assert.equal(postedEvents[0].event_type, "resolve");
  });

  it("stopped → resolve (deliberate shutdown)", async () => {
    const deps = makeDeps({ state: "stopped" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "stopped");
    assert.equal(deps.postedEvents.length, 1);
    assert.equal(deps.postedEvents[0].event_type, "resolve");
  });

  it("stopping → resolve", async () => {
    const deps = makeDeps({ state: "stopping" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "stopped");
    assert.equal(deps.postedEvents[0].event_type, "resolve");
  });

  it("pending → no-op (no PagerDuty call)", async () => {
    const deps = makeDeps({ state: "pending" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "pending");
    assert.equal(deps.postedEvents.length, 0);
  });

  it("terminated → trigger (infra gone)", async () => {
    const deps = makeDeps({ state: "terminated" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "infra_gone");
    assert.equal(deps.postedEvents.length, 1);
    assert.equal(deps.postedEvents[0].event_type, "trigger");
    assert.match(deps.postedEvents[0].description, /terminated/);
  });

  it("shutting-down → trigger (infra gone)", async () => {
    const deps = makeDeps({ state: "shutting-down" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "infra_gone");
    assert.equal(deps.postedEvents[0].event_type, "trigger");
  });

  it("running but no public IP → trigger (network issue)", async () => {
    const deps = makeDeps({ state: "running", publicIp: null });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "triggered_no_ip");
    assert.equal(deps.postedEvents[0].event_type, "trigger");
    assert.match(deps.postedEvents[0].description, /no public IP/);
  });

  it("unknown state → no-op (no PagerDuty calls)", async () => {
    const deps = makeDeps({ state: "rebooting" });
    const out = await mod.handleTick(deps);
    assert.equal(out.status, "unknown");
    assert.equal(deps.postedEvents.length, 0);
  });
});

describe("handleTick — side effects", () => {
  afterEach(() => {
    mod.__resetCacheForTest();
  });

  it("reads integration key from SSM and caches it across calls", async () => {
    const deps = makeDeps({ state: "stopped" });
    await mod.handleTick(deps);
    await mod.handleTick(deps);
    // SSM is called only once — the second tick uses the cached key.
    assert.equal(deps.ssm.send.mock.callCount(), 1);
  });

  it("passes the correct instance id to DescribeInstances", async () => {
    const deps = makeDeps({ state: "stopped" });
    await mod.handleTick(deps);
    const call = deps.ec2.send.mock.calls[0];
    assert.deepEqual(call.arguments[0].input.InstanceIds, ["i-test"]);
  });

  it("always uses the same dedup key for trigger + resolve", async () => {
    const deps1 = makeDeps({ state: "stopped" });
    await mod.handleTick(deps1);
    assert.equal(deps1.postedEvents[0].incident_key, "live-bot-health");

    const deps2 = makeDeps({ state: "terminated" });
    await mod.handleTick(deps2);
    assert.equal(deps2.postedEvents[0].incident_key, "live-bot-health");
  });
});
