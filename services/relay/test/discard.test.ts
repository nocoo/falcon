import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError, GIT_SHA, UPSTREAM, VERSION } from "./helpers.ts";
import { network } from "./network.ts";

describe("discard upstream bodies on early returns", () => {
  it("discards a null redirect body without hanging", async () => {
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        return new HttpResponse(null, {
          status: 302,
          headers: { Location: "https://evil.example/steal" },
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

  it("cancels a hanging upstream body when business returns a redirect error", async () => {
    let cancelled = false;
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("redirect-body"));
          },
          cancel() {
            cancelled = true;
          },
        });
        return new HttpResponse(body, {
          status: 302,
          headers: { Location: "https://evil.example/steal" },
        });
      }),
    );
    await expectRelayError(
      await call("/v1/systemone", { method: "POST", headers: bearer(), body: "{}" }),
      502,
      "upstream_redirect",
      true,
    );
    expect(cancelled).toBe(true);
  });

  it("cancels a hanging upstream body when live returns non-200", async () => {
    let cancelled = false;
    network.use(
      http.get(`${UPSTREAM}/v1/models`, () => {
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("error-body"));
          },
          cancel() {
            cancelled = true;
          },
        });
        return new HttpResponse(body, {
          status: 500,
          headers: { "content-type": "application/json" },
        });
      }),
    );
    const response = await call("/api/live");
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: "error", version: VERSION, gitSha: GIT_SHA });
    expect(cancelled).toBe(true);
  });
});
