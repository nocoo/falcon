import { describe, it } from "vitest";
import { bearer, call, expectRelayError, testEnv } from "./helpers.ts";

describe("env", () => {
  it("fails closed when the relay token is missing", async () => {
    await expectRelayError(
      await call("/api/live", {}, testEnv({ RELAY_TOKEN: "" })),
      503,
      "misconfigured",
      false,
    );
  });

  it("fails closed when the official key is missing", async () => {
    await expectRelayError(
      await call("/v1/models", { headers: bearer() }, testEnv({ TYPESAFE_API_KEY: "  " })),
      503,
      "misconfigured",
      false,
    );
  });

  it("fails closed when version or gitSha is missing", async () => {
    await expectRelayError(
      await call("/api/live", {}, testEnv({ VERSION: "" })),
      503,
      "misconfigured",
      false,
    );
    await expectRelayError(
      await call("/api/live", {}, testEnv({ GIT_SHA: "" })),
      503,
      "misconfigured",
      false,
    );
  });

  it("fails closed when the rate limit binding is missing", async () => {
    await expectRelayError(
      await call("/v1/models", { headers: bearer() }, testEnv({ RATE_LIMIT: undefined })),
      503,
      "misconfigured",
      false,
    );
  });
});
