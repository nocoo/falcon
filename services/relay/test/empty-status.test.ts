import { HttpResponse, http } from "msw";
import { describe, expect, it } from "vitest";
import { bearer, call, UPSTREAM } from "./helpers.ts";
import { network } from "./network.ts";

describe("empty upstream statuses", () => {
  it.each([204, 205])("preserves legal empty %s without throwing", async (status) => {
    network.use(
      http.post(`${UPSTREAM}/v1/systemone`, () => {
        return new HttpResponse(null, {
          status,
          headers: { "x-typesafe-request-id": `empty-${status}` },
        });
      }),
    );
    const response = await call("/v1/systemone", {
      method: "POST",
      headers: bearer(),
      body: "{}",
    });
    expect(response.status).toBe(status);
    expect(await response.text()).toBe("");
    expect(response.headers.get("x-typesafe-request-id")).toBe(`empty-${status}`);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });
});
