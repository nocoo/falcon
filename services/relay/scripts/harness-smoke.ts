import { createHarness, SYNTHETIC_MODELS_BODY, syntheticSystemoneResponse } from "./harness.ts";

const { mf, meta, mock, relayToken } = createHarness({ port: 0 });

try {
  const ready = await mf.ready;
  const base = ready.origin;

  const live = await fetch(`${base}/api/live`);
  if (live.status !== 200) {
    throw new Error(`live status ${live.status}`);
  }
  if (live.headers.get("Cache-Control") !== "no-store") {
    throw new Error("live missing no-store");
  }
  const liveBody: unknown = await live.json();
  if (
    JSON.stringify(liveBody) !==
    JSON.stringify({ status: "ok", version: meta.version, gitSha: meta.gitSha })
  ) {
    throw new Error(`live body ${JSON.stringify(liveBody)} meta=${JSON.stringify(meta)}`);
  }

  const models = await fetch(`${base}/v1/models`, {
    headers: { Authorization: `Bearer ${relayToken}` },
  });
  if (models.status !== 200) {
    throw new Error(`models status ${models.status}`);
  }
  if ((await models.text()) !== SYNTHETIC_MODELS_BODY) {
    throw new Error("models body mismatch vs Swift MockUpstream synthetic");
  }
  if (models.headers.get("x-typesafe-request-id") !== "synthetic-models") {
    throw new Error("models missing synthetic-models request id");
  }

  // Valid TypeSafe-shaped request; response is synthetic (not an echo).
  const payload =
    '{"model":"jev-latest","state":"synthetic","questions":{"n":{"type":"noul","instructions":"yes?"},"c":{"type":"choice","instructions":"choose","criteria":{"a":"A","b":"B"}}}}';
  const expectedUpstream = new TextEncoder().encode(payload);
  const expectedResponse = syntheticSystemoneResponse(expectedUpstream);

  const proxied = await fetch(`${base}/v1/systemone`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${relayToken}`,
      "content-type": "application/json",
    },
    body: payload,
  });
  if (proxied.status !== 200) {
    throw new Error(`proxy status ${proxied.status}`);
  }
  const text = await proxied.text();
  if (text !== expectedResponse) {
    throw new Error(`proxy body not synthetic TypeSafe response: ${text}`);
  }
  if (text === payload) {
    throw new Error("proxy must not echo the request body");
  }
  if (proxied.headers.get("x-typesafe-request-id") !== "synthetic-upstream-request") {
    throw new Error("proxy missing synthetic-upstream-request id");
  }
  if (proxied.headers.get("Cache-Control") !== "no-store") {
    throw new Error("proxy missing no-store");
  }

  // Raw-byte fidelity: mock observed exact request bytes separately from response shape.
  if (mock.systemoneBodies.length !== 1) {
    throw new Error(`expected one observed systemone body, got ${mock.systemoneBodies.length}`);
  }
  const observed = mock.systemoneBodies[0];
  if (!observed || observed.byteLength !== expectedUpstream.byteLength) {
    throw new Error("observed systemone bytes length mismatch");
  }
  for (let i = 0; i < observed.byteLength; i += 1) {
    if (observed[i] !== expectedUpstream[i]) {
      throw new Error(`observed systemone byte mismatch at ${i}`);
    }
  }

  const parsed: unknown = JSON.parse(text);
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    (parsed as { model?: unknown }).model !== "jev-synthetic" ||
    typeof (parsed as { answers?: unknown }).answers !== "object"
  ) {
    throw new Error("synthetic systemone response not parseable as TypeSafe shape");
  }

  if (!meta.compatibilityFlags.includes("enable_request_signal")) {
    throw new Error("built artifact missing enable_request_signal");
  }
  console.log(
    `harness-smoke ok on ephemeral ${base} VERSION=${meta.version} GIT_SHA=${meta.gitSha} compatibilityDate=${meta.compatibilityDate} flags=${meta.compatibilityFlags.join(",")}`,
  );
} finally {
  await mf.dispose();
}
