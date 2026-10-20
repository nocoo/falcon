import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, testEnv, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

describe("rate limit", () => {
  it("uses the platform binding instead of a hardcoded quota", async () => {
    const keys: string[] = [];
    network.use(http.get(`${UPSTREAM}/v1/models`, () => HttpResponse.json({ models: [] })));
    const env = testEnv({
      RATE_LIMIT: {
        async limit(input) {
          keys.push(input.key);
          return { success: true };
        },
      },
    });
    const response = await call("/v1/models", { headers: bearer() }, env);
    expect(response.status).toBe(200);
    expect(keys).toEqual(["relay"]);
  });

  it("returns 429 when the platform limiter rejects the key before any upstream call", async () => {
    let upstreamHits = 0;
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        upstreamHits += 1;
        return HttpResponse.json({ models: [] });
      }),
    );
    const env = testEnv({
      RATE_LIMIT: {
        async limit() {
          return { success: false };
        },
      },
    });
    const response = await call("/v1/models", { headers: bearer() }, env);
    await expectRelayError(response, 429, "rate_limited", false);
    expect(response.headers.get("Retry-After")).toBe("1");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(upstreamHits).toBe(0);
  });

  it("rate-limits anonymous live before the models probe", async () => {
    let upstreamHits = 0;
    let keys: string[] = [];
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        upstreamHits += 1;
        return HttpResponse.json({ models: [] });
      }),
    );
    const limited = await call(
      "/api/live",
      {},
      testEnv({
        RATE_LIMIT: {
          async limit(input) {
            keys.push(input.key);
            return { success: false };
          },
        },
      }),
    );
    await expectRelayError(limited, 429, "rate_limited", false);
    expect(upstreamHits).toBe(0);
    expect(keys).toEqual(["live"]);

    keys = [];
    const allowed = await call(
      "/api/live",
      {},
      testEnv({
        RATE_LIMIT: {
          async limit(input) {
            keys.push(input.key);
            return { success: true };
          },
        },
      }),
    );
    expect(allowed.status).toBe(200);
    expect(keys).toEqual(["live"]);
    expect(upstreamHits).toBe(1);
  });

  it("does not consume the limiter on failed auth", async () => {
    let calls = 0;
    const limiter = {
      async limit() {
        calls += 1;
        return { success: true };
      },
    };
    await call("/v1/models", {}, testEnv({ RATE_LIMIT: limiter }));
    expect(calls).toBe(0);
  });

  it("returns sanitized 503 when the business limiter throws before upstream", async () => {
    let upstreamHits = 0;
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        upstreamHits += 1;
        return HttpResponse.json({ models: [] });
      }),
    );
    await expectRelayError(
      await call(
        "/v1/models",
        { headers: bearer() },
        testEnv({
          RATE_LIMIT: {
            async limit() {
              throw new Error("binding failed");
            },
          },
        }),
      ),
      503,
      "misconfigured",
      false,
    );
    expect(upstreamHits).toBe(0);
  });

  it("returns sanitized 503 when the live limiter throws before the models probe", async () => {
    let upstreamHits = 0;
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        upstreamHits += 1;
        return HttpResponse.json({ models: [] });
      }),
    );
    await expectRelayError(
      await call(
        "/api/live",
        {},
        testEnv({
          RATE_LIMIT: {
            async limit() {
              throw new Error("binding failed");
            },
          },
        }),
      ),
      503,
      "misconfigured",
      false,
    );
    expect(upstreamHits).toBe(0);
  });
});
