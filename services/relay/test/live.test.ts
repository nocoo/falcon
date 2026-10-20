import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { call, GIT_SHA, RELAY_TOKEN, testEnv, UPSTREAM, VERSION } from "./helpers.ts";
import { network } from "./network.ts";

describe("live", () => {
  it("returns anonymous status version and gitSha with no-store", async () => {
    const caches: Array<string | undefined> = [];
    network.use(
      http.get(`${UPSTREAM}/v1/models`, ({ request }) => {
        caches.push(request.cache);
        return HttpResponse.json({ models: [{ name: "jev-latest" }] });
      }),
    );
    const response = await call("/api/live");
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(caches).toEqual(["no-store"]);
    expect(await response.json()).toEqual({ status: "ok", version: VERSION, gitSha: GIT_SHA });
  });

  it("does not send inference when probing live", async () => {
    network.use(http.get(`${UPSTREAM}/v1/models`, () => HttpResponse.json({ models: [] })));
    const response = await call("/api/live");
    expect(response.status).toBe(200);
  });

  it("returns 503 when the models probe fails", async () => {
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        return new HttpResponse("nope", {
          status: 500,
          headers: { "content-type": "application/json" },
        });
      }),
    );
    const response = await call("/api/live");
    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ status: "error", version: VERSION, gitSha: GIT_SHA });
  });

  it("returns 503 when the models probe cannot connect", async () => {
    const response = await call("/api/live", {}, testEnv({ LIVE_TIMEOUT_MS: "20" }));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: "error", version: VERSION, gitSha: GIT_SHA });
  });

  it("returns 503 when the models probe exceeds the live deadline", async () => {
    network.use(http.get(`${UPSTREAM}/v1/models`, () => new Promise(() => undefined)));
    const response = await call("/api/live", {}, testEnv({ LIVE_TIMEOUT_MS: "30" }));
    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ status: "error", version: VERSION, gitSha: GIT_SHA });
  });

  it("does not require a relay bearer", async () => {
    network.use(http.get(`${UPSTREAM}/v1/models`, () => HttpResponse.json({ models: [] })));
    const response = await call("/api/live", {
      headers: { Authorization: `Bearer ${RELAY_TOKEN}` },
    });
    expect(response.status).toBe(200);
  });

  it("rejects a 200 HTML body as a failed models probe", async () => {
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        return new HttpResponse("<html>ok</html>", {
          status: 200,
          headers: { "content-type": "text/html" },
        });
      }),
    );
    const response = await call("/api/live");
    expect(response.status).toBe(503);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(await response.json()).toEqual({ status: "error", version: VERSION, gitSha: GIT_SHA });
  });

  it("rejects a 200 JSON body without a models array", async () => {
    network.use(http.get(`${UPSTREAM}/v1/models`, () => HttpResponse.json({ data: [] })));
    const response = await call("/api/live");
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: "error", version: VERSION, gitSha: GIT_SHA });
  });
});
