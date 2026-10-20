import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, OFFICIAL_KEY, RELAY_TOKEN, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

describe("auth", () => {
  it("rejects missing authorization", async () => {
    const response = await call("/v1/models");
    await expectRelayError(response, 401, "unauthorized", false);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });

  it("rejects a wrong bearer token with the same envelope", async () => {
    await expectRelayError(
      await call("/v1/models", { headers: bearer("wrong-token") }),
      401,
      "unauthorized",
      false,
    );
  });

  it("rejects a different-length token", async () => {
    await expectRelayError(
      await call("/v1/models", { headers: bearer("x") }),
      401,
      "unauthorized",
      false,
    );
  });

  it("rejects a non-bearer scheme", async () => {
    await expectRelayError(
      await call("/v1/models", { headers: { Authorization: `Basic ${RELAY_TOKEN}` } }),
      401,
      "unauthorized",
      false,
    );
  });

  it("accepts case-insensitive Bearer and isolates secrets", async () => {
    const seen: Record<string, string | null>[] = [];
    network.use(
      http.get(`${UPSTREAM}/v1/models`, ({ request }) => {
        seen.push({
          authorization: request.headers.get("authorization"),
          cookie: request.headers.get("cookie"),
          agent: request.headers.get("x-falcon-agent"),
          project: request.headers.get("x-falcon-project"),
          host: request.headers.get("host"),
        });
        return HttpResponse.json({ models: [] });
      }),
    );
    const response = await call("/v1/models", {
      headers: {
        Authorization: `bearer ${RELAY_TOKEN}`,
        Cookie: "session=caller",
        Host: "evil.example",
        "X-Falcon-Agent": "codex",
        "X-Falcon-Project": "falcon",
      },
    });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('{"models":[]}');
    expect(seen).toHaveLength(1);
    expect(seen[0]?.authorization).toBe(`Bearer ${OFFICIAL_KEY}`);
    expect(seen[0]?.cookie).toBeNull();
    expect(seen[0]?.agent).toBeNull();
    expect(seen[0]?.project).toBeNull();
    expect(seen[0]?.host).not.toBe("evil.example");
  });
});
