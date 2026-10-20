import { describe, expect, it } from "vitest";
import { bearer, call, expectRelayError } from "./helpers.ts";

const methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"] as const;

describe("routes", () => {
  it("rejects unknown paths", async () => {
    await expectRelayError(await call("/health", { headers: bearer() }), 404, "not_found", false);
    await expectRelayError(
      await call("/v1/systemone/", { method: "POST", headers: bearer(), body: "{}" }),
      404,
      "not_found",
      false,
    );
  });

  it("rejects unsupported methods on known paths", async () => {
    for (const method of methods) {
      if (method !== "POST") {
        const response = await call("/v1/systemone", { method, headers: bearer() });
        await expectRelayError(response, 405, "method_not_allowed", false);
        expect(response.headers.get("Allow")).toBe("POST");
      }
      if (method !== "GET") {
        const response = await call("/v1/models", { method, headers: bearer() });
        await expectRelayError(response, 405, "method_not_allowed", false);
        expect(response.headers.get("Allow")).toBe("GET");
      }
      if (method !== "GET") {
        const response = await call("/api/live", { method });
        await expectRelayError(response, 405, "method_not_allowed", false);
        expect(response.headers.get("Allow")).toBe("GET");
      }
    }
  });

  it("does not forward arbitrary caller paths", async () => {
    await expectRelayError(
      await call("/v1/models/../admin", { headers: bearer() }),
      404,
      "not_found",
      false,
    );
  });

  it("rejects URLs whose raw form contains .. even when pathname is clean", async () => {
    await expectRelayError(
      await call("/v1/models?ref=../admin", { headers: bearer() }),
      404,
      "not_found",
      false,
    );
  });
});
