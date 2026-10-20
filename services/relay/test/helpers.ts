import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { expect } from "vitest";
import type { Env } from "../src/env.ts";
import worker from "../src/index.ts";

export const RELAY_TOKEN = "test-relay-token";
export const OFFICIAL_KEY = "test-official-key";
export const VERSION = "0.1.7";
export const GIT_SHA = "test-git-sha";
export const UPSTREAM = "https://api.typesafe.ai";

export function allowAllRateLimit(): NonNullable<Env["RATE_LIMIT"]> {
  return {
    async limit() {
      return { success: true };
    },
  };
}

export function testEnv(overrides: Partial<Env> = {}): Env {
  return {
    RELAY_TOKEN,
    TYPESAFE_API_KEY: OFFICIAL_KEY,
    VERSION,
    GIT_SHA,
    RATE_LIMIT: allowAllRateLimit(),
    ...overrides,
  };
}

export function bearer(token = RELAY_TOKEN): Record<string, string> {
  return { Authorization: `Bearer ${token}` };
}

export async function call(
  path: string,
  init: RequestInit = {},
  env: Env = testEnv(),
): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`https://falcon.hexly.ai${path}`, init),
    env,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

export async function expectRelayError(
  response: Response,
  status: number,
  code: string,
  outcomeUnknown: boolean,
): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.headers.get("X-Falcon-Error-Origin")).toBe("relay");
  expect(response.headers.get("content-type")).toMatch(/application\/json/);
  const body: unknown = await response.json();
  expect(body).toEqual({
    error: {
      origin: "relay",
      code,
      message: expect.any(String),
      outcome_unknown: outcomeUnknown,
    },
  });
  const message = (body as { error: { message: string } }).error.message;
  expect(message.length).toBeGreaterThan(0);
  expect(message).not.toContain(RELAY_TOKEN);
  expect(message).not.toContain(OFFICIAL_KEY);
}
