import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const bundlePath = join(root, ".cloudflare/output/v0/workers/default/bundle/index.js");
const workerConfigPath = join(root, ".cloudflare/output/v0/workers/default/worker.config.json");
const UPSTREAM_ORIGIN = "https://api.typesafe.ai";
const LOOPBACK = "127.0.0.1";

/** Mirrors Tests/FalconIntegrationTests/ProxyIntegrationTests.swift MockUpstream /v1/models. */
export const SYNTHETIC_MODELS_BODY =
  '{"models":[{"name":"jev-synthetic","description":"Synthetic model","release_date":"2026-09-30"}]}';

type WorkerConfig = {
  compatibilityDate: string;
  compatibilityFlags?: string[];
  compatibility_flags?: string[];
  env: {
    VERSION: { type: "text"; value: string };
    GIT_SHA: { type: "text"; value: string };
    RATE_LIMIT: {
      type: "rate-limit";
      namespace: string;
      simple: { limit: number; period: number };
    };
  };
};

export type BuiltWorkerMeta = {
  version: string;
  gitSha: string;
  compatibilityDate: string;
  compatibilityFlags: string[];
  rateLimitNamespace: string;
  rateLimit: { limit: number; period: number };
};

export type HarnessOptions = {
  /** Ephemeral when 0. Dev default 7060. */
  port?: number;
  relayToken?: string;
  officialKey?: string;
};

export type HarnessMockState = {
  systemoneBodies: Uint8Array[];
};

export function readBuiltWorkerMeta(): BuiltWorkerMeta {
  readFileSync(bundlePath);
  const config = JSON.parse(readFileSync(workerConfigPath, "utf8")) as WorkerConfig;
  const version = config.env.VERSION.value.trim();
  const gitSha = config.env.GIT_SHA.value.trim();
  const compatibilityDate = config.compatibilityDate.trim();
  const compatibilityFlags = [
    ...(config.compatibilityFlags ?? config.compatibility_flags ?? []),
  ].map((flag) => flag.trim());
  if (!version || !gitSha || !compatibilityDate) {
    throw new Error("worker.config.json missing VERSION, GIT_SHA, or compatibilityDate");
  }
  if (!compatibilityFlags.includes("enable_request_signal")) {
    throw new Error("worker.config.json missing compatibilityFlags enable_request_signal");
  }
  return {
    version,
    gitSha,
    compatibilityDate,
    compatibilityFlags,
    rateLimitNamespace: config.env.RATE_LIMIT.namespace,
    rateLimit: config.env.RATE_LIMIT.simple,
  };
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

function isObject(value: Json | undefined): value is { [key: string]: Json } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Synthetic TypeSafe /v1/systemone body; same rules as Swift MockUpstream.answer. */
export function syntheticSystemoneResponse(requestBody: Uint8Array): string {
  const root = JSON.parse(new TextDecoder().decode(requestBody)) as Json;
  if (!isObject(root) || !isObject(root.questions)) {
    throw new Error("synthetic fixture requires questions object");
  }
  const answers: { [key: string]: Json } = {};
  for (const [id, question] of Object.entries(root.questions)) {
    if (question === undefined) {
      throw new Error("synthetic fixture requires questions object");
    }
    answers[id] = answer(question);
  }
  return JSON.stringify({
    model: "jev-synthetic",
    answers,
    usage: { input_tokens: 10, output_tokens: 2 },
    echo: root.state ?? null,
  });
}

function answer(question: Json): Json {
  if (!isObject(question)) {
    throw new Error("fixture received invalid question");
  }
  switch (question.type) {
    case "choice": {
      if (!isObject(question.criteria)) {
        throw new Error("fixture received invalid choice criteria");
      }
      const winner = Object.keys(question.criteria).sort()[0];
      if (!winner) {
        throw new Error("fixture received empty choice criteria");
      }
      const probabilities: { [key: string]: Json } = {};
      for (const key of Object.keys(question.criteria)) {
        probabilities[key] = key === winner ? 1 : 0;
      }
      return {
        type: "choice",
        choice: winner,
        probabilities,
        confidence: 1,
      };
    }
    case "noul":
      return { type: "noul", noul: 0.9 };
    case "score": {
      if (!Array.isArray(question.criteria)) {
        throw new Error("fixture received invalid score criteria");
      }
      const legend: { [key: string]: Json } = {};
      const probabilities: { [key: string]: Json } = {};
      question.criteria.forEach((level, index) => {
        if (level === undefined) {
          throw new Error("fixture received invalid score criteria");
        }
        legend[String(index)] = level;
        probabilities[String(index)] = index === 0 ? 1 : 0;
      });
      return {
        type: "score",
        score: 0,
        legend,
        probabilities,
        confidence: 1,
      };
    }
    default:
      throw new Error("fixture received invalid question");
  }
}

export function createHarness(options: HarnessOptions = {}): {
  mf: Miniflare;
  meta: BuiltWorkerMeta;
  mock: HarnessMockState;
  relayToken: string;
} {
  const meta = readBuiltWorkerMeta();
  const relayToken = options.relayToken ?? "harness-relay-token";
  const officialKey = options.officialKey ?? "harness-official-key";
  const mock: HarnessMockState = { systemoneBodies: [] };
  const port = options.port ?? Number(process.env.HARNESS_PORT ?? "7060");

  const outboundService = async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    if (url.origin !== UPSTREAM_ORIGIN) {
      return new Response("outbound blocked", { status: 502 });
    }
    if (url.pathname === "/v1/models" && request.method === "GET") {
      return new Response(SYNTHETIC_MODELS_BODY, {
        status: 200,
        headers: {
          "content-type": "application/json",
          "x-typesafe-request-id": "synthetic-models",
        },
      });
    }
    if (url.pathname === "/v1/systemone" && request.method === "POST") {
      const body = new Uint8Array(await request.arrayBuffer());
      mock.systemoneBodies.push(body);
      try {
        const synthetic = syntheticSystemoneResponse(body);
        return new Response(synthetic, {
          status: 200,
          headers: {
            "content-type": "application/json",
            "x-typesafe-request-id": "synthetic-upstream-request",
          },
        });
      } catch {
        return new Response('{"error":"synthetic upstream"}', {
          status: 400,
          headers: {
            "content-type": "application/json",
            "x-typesafe-request-id": "synthetic-upstream-request",
          },
        });
      }
    }
    return new Response("mock not found", { status: 404 });
  };

  const mf = new Miniflare(
    convertV4MiniflareOptions({
      host: LOOPBACK,
      port,
      compatibilityDate: meta.compatibilityDate,
      compatibilityFlags: meta.compatibilityFlags,
      modules: true,
      scriptPath: bundlePath,
      bindings: {
        VERSION: meta.version,
        GIT_SHA: meta.gitSha,
        RELAY_TOKEN: relayToken,
        TYPESAFE_API_KEY: officialKey,
      },
      ratelimits: {
        RATE_LIMIT: {
          namespace_id: meta.rateLimitNamespace,
          simple: {
            limit: meta.rateLimit.limit,
            period: meta.rateLimit.period as 10 | 60,
          },
        },
      },
      outboundService,
    }),
  );

  return { mf, meta, mock, relayToken };
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];

if (isMain) {
  const { mf, meta } = createHarness();
  const url = await mf.ready;
  console.log(`falcon-relay harness listening on ${url.origin}`);
  console.log(
    `built VERSION=${meta.version} GIT_SHA=${meta.gitSha} compatibilityDate=${meta.compatibilityDate} flags=${meta.compatibilityFlags.join(",")}`,
  );
  console.log("synthetic secrets only; outbound mocked to api.typesafe.ai");
  const stop = async () => {
    await mf.dispose();
    process.exit(0);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}
