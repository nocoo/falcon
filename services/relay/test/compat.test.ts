import { describe, expect, it } from "vitest";
import { COMPATIBILITY_DATE, COMPATIBILITY_FLAGS } from "../compat.ts";

describe("compatibility", () => {
  it("explicitly enables request signal rather than relying on date defaults", () => {
    expect(COMPATIBILITY_DATE).toBe("2026-10-13");
    expect([...COMPATIBILITY_FLAGS]).toEqual(["enable_request_signal"]);
  });
});
