import type { Env } from "./env.ts";

export type { Env };

const UPSTREAM = "https://api.typesafe.ai";
const REQUEST_LIMIT = 1_048_576;
const RESPONSE_LIMIT = 4_194_304;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 25_000;
const DEFAULT_LIVE_TIMEOUT_MS = 5_000;
const CANCEL_BOUND_MS = 100;
const PASSED_HEADERS = ["content-type", "retry-after", "retry-after-ms", "x-typesafe-request-id"];
const EMPTY_STATUSES = new Set([204, 205]);

const MESSAGES: Record<string, string> = {
  unauthorized: "Relay token is missing or invalid",
  method_not_allowed: "Method is not allowed",
  not_found: "Path is not allowed",
  request_too_large: "Request body exceeded limit",
  response_too_large: "Upstream response exceeded limit",
  upstream_timeout: "Upstream request timed out",
  upstream_network: "Upstream request failed",
  upstream_redirect: "Upstream returned a redirect",
  rate_limited: "Rate limit exceeded",
  misconfigured: "Relay is not configured",
};

type ReadyEnv = {
  RELAY_TOKEN: string;
  TYPESAFE_API_KEY: string;
  VERSION: string;
  GIT_SHA: string;
  RATE_LIMIT: NonNullable<Env["RATE_LIMIT"]>;
  UPSTREAM_TIMEOUT_MS?: string;
  LIVE_TIMEOUT_MS?: string;
};

function ready(env: Env): env is ReadyEnv {
  return Boolean(
    env.RELAY_TOKEN?.trim() &&
      env.TYPESAFE_API_KEY?.trim() &&
      env.VERSION?.trim() &&
      env.GIT_SHA?.trim() &&
      env.RATE_LIMIT,
  );
}

function allowedMethod(pathname: string): string | undefined {
  if (pathname === "/v1/systemone") {
    return "POST";
  }
  if (pathname === "/v1/models" || pathname === "/api/live") {
    return "GET";
  }
  return undefined;
}

function timeoutMs(raw: string | undefined, fallback: number): number {
  const value = Number(raw);
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function withNoStore(headers: Headers): Headers {
  headers.set("Cache-Control", "no-store");
  return headers;
}

function relayError(
  status: number,
  code: keyof typeof MESSAGES,
  outcomeUnknown: boolean,
  extra?: HeadersInit,
): Response {
  const headers = withNoStore(new Headers(extra));
  headers.set("content-type", "application/json");
  headers.set("X-Falcon-Error-Origin", "relay");
  return new Response(
    JSON.stringify({
      error: {
        origin: "relay",
        code,
        message: MESSAGES[code],
        outcome_unknown: outcomeUnknown,
      },
    }),
    { status, headers },
  );
}

async function tokenMatches(provided: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [left, right] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  return crypto.subtle.timingSafeEqual(left, right);
}

function extractBearer(header: string | null): string | undefined {
  const match = /^Bearer[ \t]+(\S+)$/i.exec(header ?? "");
  return match?.[1];
}

type ReadResult =
  | { ok: true; bytes: Uint8Array }
  | { ok: false; reason: "limit" | "abort" | "error" };

async function cancelBounded(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  await Promise.race([
    reader.cancel().catch(() => undefined),
    new Promise<void>((resolve) => {
      setTimeout(resolve, CANCEL_BOUND_MS);
    }),
  ]);
}

async function discardBody(body: ReadableStream<Uint8Array> | null): Promise<void> {
  if (!body) {
    return;
  }
  await cancelBounded(body.getReader());
}

function joinChunks(chunks: Uint8Array[], size: number): Uint8Array {
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function readLimited(
  body: ReadableStream<Uint8Array> | null,
  limit: number,
  signal: AbortSignal,
): Promise<ReadResult> {
  if (!body) {
    return { ok: true, bytes: new Uint8Array() };
  }
  if (signal.aborted) {
    return { ok: false, reason: "abort" };
  }
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  // One listener for the whole read: cancel resolves pending read() with {done:true}.
  const onAbort = () => {
    void cancelBounded(reader);
  };
  signal.addEventListener("abort", onAbort);
  try {
    for (;;) {
      const { done, value } = await reader.read();
      // cancel() resolves pending read() with {done:true}; recheck before success.
      if (signal.aborted) {
        await cancelBounded(reader);
        return { ok: false, reason: "abort" };
      }
      if (done) {
        return { ok: true, bytes: joinChunks(chunks, size) };
      }
      size += value.byteLength;
      if (size > limit) {
        await cancelBounded(reader);
        return { ok: false, reason: "limit" };
      }
      chunks.push(value);
    }
  } catch {
    await cancelBounded(reader);
    return { ok: false, reason: signal.aborted ? "abort" : "error" };
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
}

function passHeaders(from: Headers): Headers {
  const headers = withNoStore(new Headers());
  for (const name of PASSED_HEADERS) {
    const value = from.get(name);
    if (value !== null) {
      headers.set(name, value);
    }
  }
  return headers;
}

function logSafe(message: string, path: string, code?: string): void {
  console.log(JSON.stringify({ message, path, ...(code ? { code } : {}) }));
}

function isModelsPayload(bytes: Uint8Array): boolean {
  try {
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
    return (
      typeof parsed === "object" &&
      parsed !== null &&
      Array.isArray((parsed as { models?: unknown }).models)
    );
  } catch {
    return false;
  }
}

function transportError(
  ac: AbortController,
  clientAborted: boolean,
  pathname: string,
  sent: boolean,
): Response {
  const timedOut = ac.signal.reason === "timeout" && !clientAborted;
  const code: keyof typeof MESSAGES = timedOut ? "upstream_timeout" : "upstream_network";
  logSafe("upstream_failed", pathname, code);
  return relayError(timedOut ? 504 : 502, code, sent);
}

function upstreamHeaders(request: Request, apiKey: string): Headers {
  const headers = new Headers();
  headers.set("Authorization", `Bearer ${apiKey}`);
  const contentType = request.headers.get("content-type");
  if (contentType) {
    headers.set("Content-Type", contentType);
  }
  return headers;
}

type Budget = {
  ac: AbortController;
  dispose: () => void;
};

function armBudget(ms: number, request: Request): Budget {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort("timeout"), ms);
  const onClientAbort = () => ac.abort("client");
  if (request.signal.aborted) {
    ac.abort("client");
  } else {
    request.signal.addEventListener("abort", onClientAbort);
  }
  return {
    ac,
    dispose() {
      clearTimeout(timer);
      request.signal.removeEventListener("abort", onClientAbort);
      // Response bytes are already buffered; abort any still-open upstream work.
      if (!ac.signal.aborted) {
        ac.abort("disposed");
      }
    },
  };
}

type Admission = "ok" | "limited" | "misconfigured" | "aborted";

async function admit(
  env: ReadyEnv,
  key: "live" | "relay",
  signal: AbortSignal,
): Promise<Admission> {
  if (signal.aborted) {
    return "aborted";
  }
  try {
    const result = await new Promise<{ success: boolean } | "aborted">((resolve, reject) => {
      const onAbort = () => {
        cleanup();
        resolve("aborted");
      };
      const cleanup = () => {
        signal.removeEventListener("abort", onAbort);
      };
      signal.addEventListener("abort", onAbort);
      env.RATE_LIMIT.limit({ key }).then(
        (value) => {
          cleanup();
          resolve(signal.aborted ? "aborted" : value);
        },
        (error: unknown) => {
          cleanup();
          if (signal.aborted) {
            resolve("aborted");
          } else {
            reject(error);
          }
        },
      );
    });
    if (result === "aborted") {
      return "aborted";
    }
    return result.success ? "ok" : "limited";
  } catch {
    return "misconfigured";
  }
}

function admissionResponse(
  admission: Admission,
  ac: AbortController,
  clientAborted: boolean,
  pathname: string,
): Response | undefined {
  if (admission === "ok") {
    return undefined;
  }
  if (admission === "limited") {
    return relayError(429, "rate_limited", false, { "Retry-After": "1" });
  }
  if (admission === "misconfigured") {
    return relayError(503, "misconfigured", false);
  }
  return transportError(ac, clientAborted, pathname, false);
}

async function forwardResponse(
  upstream: Response,
  signal: AbortSignal,
  pathname: string,
  clientAborted: boolean,
  ac: AbortController,
): Promise<Response> {
  if (upstream.status >= 300 && upstream.status < 400) {
    await discardBody(upstream.body);
    logSafe("upstream_redirect", pathname, "upstream_redirect");
    return relayError(502, "upstream_redirect", true);
  }
  if (EMPTY_STATUSES.has(upstream.status)) {
    await readLimited(upstream.body, RESPONSE_LIMIT, signal);
    return new Response(null, {
      status: upstream.status,
      headers: passHeaders(upstream.headers),
    });
  }
  const boxed = await readLimited(upstream.body, RESPONSE_LIMIT, signal);
  if (boxed.ok) {
    return new Response(boxed.bytes, {
      status: upstream.status,
      headers: passHeaders(upstream.headers),
    });
  }
  if (boxed.reason === "limit") {
    logSafe("response_too_large", pathname, "response_too_large");
    return relayError(502, "response_too_large", true);
  }
  return transportError(ac, clientAborted, pathname, true);
}

async function live(request: Request, env: ReadyEnv): Promise<Response> {
  const headers = withNoStore(
    new Headers({
      "content-type": "application/json",
    }),
  );
  const body = (status: "ok" | "error") =>
    JSON.stringify({ status, version: env.VERSION, gitSha: env.GIT_SHA });
  const budget = armBudget(timeoutMs(env.LIVE_TIMEOUT_MS, DEFAULT_LIVE_TIMEOUT_MS), request);
  try {
    const admission = await admit(env, "live", budget.ac.signal);
    const denied = admissionResponse(admission, budget.ac, request.signal.aborted, "/api/live");
    if (denied) {
      return denied;
    }
    const response = await fetch(`${UPSTREAM}/v1/models`, {
      method: "GET",
      headers: { Authorization: `Bearer ${env.TYPESAFE_API_KEY}` },
      redirect: "manual",
      cache: "no-store",
      signal: budget.ac.signal,
    });
    if (response.status !== 200) {
      await discardBody(response.body);
      logSafe("live_probe_failed", "/api/live");
      return new Response(body("error"), { status: 503, headers });
    }
    const boxed = await readLimited(response.body, RESPONSE_LIMIT, budget.ac.signal);
    if (!boxed.ok || !isModelsPayload(boxed.bytes)) {
      logSafe("live_probe_failed", "/api/live");
      return new Response(body("error"), { status: 503, headers });
    }
    return new Response(body("ok"), { status: 200, headers });
  } catch {
    logSafe("live_probe_failed", "/api/live");
    return new Response(body("error"), { status: 503, headers });
  } finally {
    budget.dispose();
  }
}

async function proxy(request: Request, env: ReadyEnv, pathname: string): Promise<Response> {
  const contentLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > REQUEST_LIMIT) {
    return relayError(413, "request_too_large", false);
  }

  const budget = armBudget(
    timeoutMs(env.UPSTREAM_TIMEOUT_MS, DEFAULT_UPSTREAM_TIMEOUT_MS),
    request,
  );
  let sent = false;
  try {
    const admission = await admit(env, "relay", budget.ac.signal);
    const denied = admissionResponse(admission, budget.ac, request.signal.aborted, pathname);
    if (denied) {
      return denied;
    }

    const incoming = await readLimited(request.body, REQUEST_LIMIT, budget.ac.signal);
    if (!incoming.ok) {
      if (incoming.reason === "limit") {
        return relayError(413, "request_too_large", false);
      }
      return transportError(budget.ac, request.signal.aborted, pathname, false);
    }

    // Mark sent before awaiting fetch: official may have received the POST
    // even when the local fetch promise rejects on network/timeout.
    sent = true;
    const upstream = await fetch(`${UPSTREAM}${pathname}`, {
      method: request.method,
      headers: upstreamHeaders(request, env.TYPESAFE_API_KEY),
      body: request.method === "POST" ? incoming.bytes : undefined,
      redirect: "manual",
      cache: "no-store",
      signal: budget.ac.signal,
    });
    return await forwardResponse(
      upstream,
      budget.ac.signal,
      pathname,
      request.signal.aborted,
      budget.ac,
    );
  } catch {
    return transportError(budget.ac, request.signal.aborted, pathname, sent);
  } finally {
    budget.dispose();
  }
}

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    if (!ready(env)) {
      return relayError(503, "misconfigured", false);
    }
    const url = new URL(request.url);
    if (url.pathname.includes("..") || request.url.includes("..")) {
      return relayError(404, "not_found", false);
    }
    const allow = allowedMethod(url.pathname);
    if (!allow) {
      return relayError(404, "not_found", false);
    }
    if (request.method !== allow) {
      return relayError(405, "method_not_allowed", false, { Allow: allow });
    }
    if (url.pathname === "/api/live") {
      return live(request, env);
    }
    const token = extractBearer(request.headers.get("authorization"));
    if (!token || !(await tokenMatches(token, env.RELAY_TOKEN))) {
      return relayError(401, "unauthorized", false, { "WWW-Authenticate": "Bearer" });
    }
    return proxy(request, env, url.pathname);
  },
};
