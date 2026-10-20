import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, OFFICIAL_KEY, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

function interceptSystemone(status: number, body: string, headers: Record<string, string> = {}) {
  const seen: {
    body: string;
    authorization: string | null;
    contentType: string | null;
    cache: string | undefined;
  }[] = [];
  network.use(
    http.post(`${UPSTREAM}/v1/systemone`, async ({ request }) => {
      seen.push({
        body: await request.text(),
        authorization: request.headers.get("authorization"),
        contentType: request.headers.get("content-type"),
        cache: request.cache,
      });
      return new HttpResponse(body, { status, headers });
    }),
  );
  return seen;
}

describe("proxy", () => {
  it("forwards exact JSON bytes including null and large numbers", async () => {
    const payload = '{"n":9007199254740993,"x":null,"s":"  keep  "}';
    const seen = interceptSystemone(200, '{"ok":true}', {
      "content-type": "application/json; charset=utf-8",
      "x-typesafe-request-id": "req-1",
    });
    const response = await call("/v1/systemone", {
      method: "POST",
      headers: { ...bearer(), "content-type": "application/json", cookie: "a=b" },
      body: payload,
    });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('{"ok":true}');
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("x-typesafe-request-id")).toBe("req-1");
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(seen[0]?.body).toBe(payload);
    expect(seen[0]?.authorization).toBe(`Bearer ${OFFICIAL_KEY}`);
    expect(seen[0]?.contentType).toBe("application/json");
    expect(seen[0]?.cache).toBe("no-store");
  });

  it.each([401, 422, 429, 529])("preserves upstream %s body and retry headers", async (status) => {
    interceptSystemone(status, `{"error":${status}}`, {
      "content-type": "application/json",
      "Retry-After": "7",
      "retry-after-ms": "3500",
      "x-typesafe-request-id": `id-${status}`,
      "set-cookie": "secret=1",
      authorization: `Bearer ${OFFICIAL_KEY}`,
      "x-debug": "nope",
    });
    const response = await call("/v1/systemone", {
      method: "POST",
      headers: bearer(),
      body: "{}",
    });
    expect(response.status).toBe(status);
    expect(await response.text()).toBe(`{"error":${status}}`);
    expect(response.headers.get("Retry-After")).toBe("7");
    expect(response.headers.get("retry-after-ms")).toBe("3500");
    expect(response.headers.get("x-typesafe-request-id")).toBe(`id-${status}`);
    expect(response.headers.get("set-cookie")).toBeNull();
    expect(response.headers.get("authorization")).toBeNull();
    expect(response.headers.get("x-debug")).toBeNull();
    expect(response.headers.get("X-Falcon-Error-Origin")).toBeNull();
  });

  it("refuses redirects after a POST is sent", async () => {
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        return new HttpResponse("moved", {
          status: 302,
          headers: { location: "https://evil.example/steal" },
        });
      }),
    );
    await expectRelayError(
      await call("/v1/systemone", { method: "POST", headers: bearer(), body: "{}" }),
      502,
      "upstream_redirect",
      true,
    );
  });

  it("marks network failures after POST as outcome_unknown", async () => {
    await expectRelayError(
      await call("/v1/systemone", { method: "POST", headers: bearer(), body: "{}" }),
      502,
      "upstream_network",
      true,
    );
  });

  it("does not leak the official key downstream", async () => {
    interceptSystemone(200, `{"key":"${OFFICIAL_KEY}"}`, { "content-type": "application/json" });
    const response = await call("/v1/systemone", {
      method: "POST",
      headers: bearer(),
      body: "{}",
    });
    expect(response.status).toBe(200);
    expect(response.headers.get("authorization")).toBeNull();
    expect(await response.text()).toBe(`{"key":"${OFFICIAL_KEY}"}`);
  });
});
