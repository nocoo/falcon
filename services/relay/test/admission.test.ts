import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, testEnv, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

describe("shared request budget before admission", () => {
  it("times out a hanging business rate limiter before any upstream call", async () => {
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
          UPSTREAM_TIMEOUT_MS: "40",
          RATE_LIMIT: {
            async limit() {
              await new Promise(() => undefined);
              return { success: true };
            },
          },
        }),
      ),
      504,
      "upstream_timeout",
      false,
    );
    expect(upstreamHits).toBe(0);
  });

  it("ignores a late business limiter success after the shared budget expires", async () => {
    let upstreamHits = 0;
    let limitFinished = false;
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
          UPSTREAM_TIMEOUT_MS: "40",
          RATE_LIMIT: {
            async limit() {
              await new Promise((resolve) => setTimeout(resolve, 80));
              limitFinished = true;
              return { success: true };
            },
          },
        }),
      ),
      504,
      "upstream_timeout",
      false,
    );
    await new Promise((resolve) => setTimeout(resolve, 60));
    expect(limitFinished).toBe(true);
    expect(upstreamHits).toBe(0);
  });

  it("times out a hanging live rate limiter before the models probe", async () => {
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
          LIVE_TIMEOUT_MS: "40",
          RATE_LIMIT: {
            async limit() {
              await new Promise(() => undefined);
              return { success: true };
            },
          },
        }),
      ),
      504,
      "upstream_timeout",
      false,
    );
    expect(upstreamHits).toBe(0);
  });

  it("ignores a late live limiter success after the shared budget expires", async () => {
    let upstreamHits = 0;
    let limitFinished = false;
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
          LIVE_TIMEOUT_MS: "40",
          RATE_LIMIT: {
            async limit() {
              await new Promise((resolve) => setTimeout(resolve, 80));
              limitFinished = true;
              return { success: true };
            },
          },
        }),
      ),
      504,
      "upstream_timeout",
      false,
    );
    await new Promise((resolve) => setTimeout(resolve, 60));
    expect(limitFinished).toBe(true);
    expect(upstreamHits).toBe(0);
  });
});
