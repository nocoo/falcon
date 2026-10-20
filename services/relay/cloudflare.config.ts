import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bindings, defineConfig } from "cf/config";
import { COMPATIBILITY_DATE, COMPATIBILITY_FLAGS } from "./compat.ts";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };
import { parseMarketingVersion, resolveGitSha } from "./src/version.ts";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "../..");
const projectYml = join(here, "../../project.yml");

function gitHead(): string {
  return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8", cwd: root });
}

const version = parseMarketingVersion(readFileSync(projectYml, "utf8"));
const gitSha = resolveGitSha(process.env, gitHead);

export default defineConfig({
  worker: {
    name: "falcon-relay",
    entrypoint,
    compatibilityDate: COMPATIBILITY_DATE,
    compatibilityFlags: [...COMPATIBILITY_FLAGS],
    workersDev: false,
    previewUrls: false,
    domains: ["falcon.hexly.ai"],
    cache: { enabled: false },
    observability: {
      enabled: true,
      traces: { enabled: true },
      logs: { enabled: true, headSamplingRate: 1 },
      redactQueryString: true,
    },
    env: {
      VERSION: bindings.text(version),
      GIT_SHA: bindings.text(gitSha),
      RELAY_TOKEN: bindings.secret(),
      TYPESAFE_API_KEY: bindings.secret(),
      RATE_LIMIT: bindings.rateLimit({
        namespace: "19823",
        simple: { limit: 100, period: 60 },
      }),
    },
  },
});
