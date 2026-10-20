import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, testEnv, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

const REQUEST_LIMIT = 1_048_576;
const RESPONSE_LIMIT = 4_194_304;

function streamOf(bytes: Uint8Array, chunk = 64_000): ReadableStream<Uint8Array> {
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) {
        controller.close();
        return;
      }
      const next = bytes.subarray(offset, offset + chunk);
      offset += next.length;
      controller.enqueue(next);
    },
  });
}

describe("limits", () => {
  it("accepts many small chunks that sum to under 1MiB", async () => {
    const chunk = "a".repeat(1024);
    const chunks = 512;
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, async ({ request }) => {
        const body = await request.text();
        expect(body.length).toBe(chunk.length * chunks);
        return HttpResponse.json({});
      }),
    );
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        const encoder = new TextEncoder();
        for (let i = 0; i < chunks; i += 1) {
          controller.enqueue(encoder.encode(chunk));
        }
        controller.close();
      },
    });
    const response = await call("/v1/systemone", {
      method: "POST",
      headers: { ...bearer(), "content-type": "application/json" },
      body: stream,
      duplex: "half",
    } as RequestInit);
    expect(response.status).toBe(200);
  });

  it("accepts an exact 1MiB request and rejects one extra byte", async () => {
    const exact = "a".repeat(REQUEST_LIMIT);
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        return HttpResponse.json({});
      }),
    );
    const ok = await call("/v1/systemone", {
      method: "POST",
      headers: { ...bearer(), "content-type": "application/json" },
      body: exact,
    });
    expect(ok.status).toBe(200);
    await expectRelayError(
      await call("/v1/systemone", {
        method: "POST",
        headers: {
          ...bearer(),
          "content-type": "application/json",
          "content-length": String(REQUEST_LIMIT + 1),
        },
        body: "a".repeat(REQUEST_LIMIT + 1),
      }),
      413,
      "request_too_large",
      false,
    );
  });

  it("rejects a chunked request that overflows 1MiB", async () => {
    const bytes = new Uint8Array(REQUEST_LIMIT + 1).fill(97);
    await expectRelayError(
      await call("/v1/systemone", {
        method: "POST",
        headers: bearer(),
        body: streamOf(bytes),
        duplex: "half",
      } as RequestInit),
      413,
      "request_too_large",
      false,
    );
  });

  it("accepts an exact 4MiB response and rejects overflow without a partial success", async () => {
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        return new HttpResponse("b".repeat(RESPONSE_LIMIT), {
          headers: { "content-type": "application/json" },
        });
      }),
    );
    const ok = await call("/v1/systemone", { method: "POST", headers: bearer(), body: "{}" });
    expect(ok.status).toBe(200);
    expect((await ok.text()).length).toBe(RESPONSE_LIMIT);
    network.resetHandlers();
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        return new HttpResponse("c".repeat(RESPONSE_LIMIT + 1), {
          headers: { "content-type": "application/json" },
        });
      }),
    );
    await expectRelayError(
      await call("/v1/systemone", { method: "POST", headers: bearer(), body: "{}" }),
      502,
      "response_too_large",
      true,
    );
  });

  it("times out an upstream POST as outcome_unknown", async () => {
    network.use(http.post(`${UPSTREAM}/v1/systemone`, () => new Promise(() => undefined)));
    await expectRelayError(
      await call(
        "/v1/systemone",
        { method: "POST", headers: bearer(), body: "{}" },
        testEnv({ UPSTREAM_TIMEOUT_MS: "50" }),
      ),
      504,
      "upstream_timeout",
      true,
    );
  });

  it("treats a client abort after POST as outcome_unknown", async () => {
    let upstreamSeen = false;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, async () => {
        upstreamSeen = true;
        await gate;
        return HttpResponse.json({});
      }),
    );
    const controller = new AbortController();
    const pending = call(
      "/v1/systemone",
      { method: "POST", headers: bearer(), body: "{}", signal: controller.signal },
      testEnv({ UPSTREAM_TIMEOUT_MS: "2000" }),
    );
    for (let i = 0; i < 50 && !upstreamSeen; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(upstreamSeen).toBe(true);
    controller.abort();
    release();
    await expectRelayError(await pending, 502, "upstream_network", true);
  });
});
