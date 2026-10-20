import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, testEnv, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

function hangingStream(): ReadableStream<Uint8Array> {
  return new ReadableStream({
    pull() {
      // never enqueues or closes
    },
  });
}

function throwingStream(): ReadableStream<Uint8Array> {
  return new ReadableStream({
    pull() {
      throw new Error("body boom");
    },
  });
}

describe("total deadline", () => {
  it("times out a hanging request body before upstream send as a relay error", async () => {
    let upstreamHits = 0;
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        upstreamHits += 1;
        return HttpResponse.json({});
      }),
    );
    await expectRelayError(
      await call(
        "/v1/systemone",
        {
          method: "POST",
          headers: bearer(),
          body: hangingStream(),
          duplex: "half",
        } as RequestInit,
        testEnv({ UPSTREAM_TIMEOUT_MS: "40" }),
      ),
      504,
      "upstream_timeout",
      false,
    );
    expect(upstreamHits).toBe(0);
  });

  it("maps a throwing request body to a sanitized relay error without platform 500", async () => {
    let upstreamHits = 0;
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        upstreamHits += 1;
        return HttpResponse.json({});
      }),
    );
    await expectRelayError(
      await call(
        "/v1/systemone",
        {
          method: "POST",
          headers: bearer(),
          body: throwingStream(),
          duplex: "half",
        } as RequestInit,
        testEnv({ UPSTREAM_TIMEOUT_MS: "500" }),
      ),
      502,
      "upstream_network",
      false,
    );
    expect(upstreamHits).toBe(0);
  });

  it("applies one deadline across body read plus upstream fetch", async () => {
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, async () => {
        await new Promise((resolve) => setTimeout(resolve, 80));
        return HttpResponse.json({});
      }),
    );
    const body = new ReadableStream<Uint8Array>({
      async start(controller) {
        await new Promise((resolve) => setTimeout(resolve, 40));
        controller.enqueue(new TextEncoder().encode("{}"));
        controller.close();
      },
    });
    await expectRelayError(
      await call(
        "/v1/systemone",
        {
          method: "POST",
          headers: { ...bearer(), "content-type": "application/json" },
          body,
          duplex: "half",
        } as RequestInit,
        testEnv({ UPSTREAM_TIMEOUT_MS: "60" }),
      ),
      504,
      "upstream_timeout",
      true,
    );
  });

  it("rejects an already-aborted client request before upstream send", async () => {
    let upstreamHits = 0;
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        upstreamHits += 1;
        return HttpResponse.json({});
      }),
    );
    const controller = new AbortController();
    controller.abort();
    await expectRelayError(
      await call(
        "/v1/systemone",
        {
          method: "POST",
          headers: bearer(),
          body: "{}",
          signal: controller.signal,
        },
        testEnv({ UPSTREAM_TIMEOUT_MS: "500" }),
      ),
      502,
      "upstream_network",
      false,
    );
    expect(upstreamHits).toBe(0);
  });

  it("times out a hanging upstream response body after send", async () => {
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode('{"partial":'));
            // leave the stream open so response body read must hit the deadline
          },
        });
        return new HttpResponse(body, {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }),
    );
    await expectRelayError(
      await call(
        "/v1/systemone",
        { method: "POST", headers: bearer(), body: "{}" },
        testEnv({ UPSTREAM_TIMEOUT_MS: "40" }),
      ),
      504,
      "upstream_timeout",
      true,
    );
  });

  it("treats client abort during upstream response body as outcome_unknown", async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        const body = new ReadableStream<Uint8Array>({
          async start(controller) {
            controller.enqueue(new TextEncoder().encode('{"partial":'));
            await gate;
            controller.enqueue(new TextEncoder().encode("true}"));
            controller.close();
          },
        });
        return new HttpResponse(body, {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }),
    );
    const controller = new AbortController();
    const pending = call(
      "/v1/systemone",
      { method: "POST", headers: bearer(), body: "{}", signal: controller.signal },
      testEnv({ UPSTREAM_TIMEOUT_MS: "2000" }),
    );
    await new Promise((resolve) => setTimeout(resolve, 20));
    controller.abort();
    release();
    await expectRelayError(await pending, 502, "upstream_network", true);
  });
});
