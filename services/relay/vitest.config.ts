import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { COMPATIBILITY_DATE, COMPATIBILITY_FLAGS } from "./compat.ts";

export default defineConfig({
  plugins: [
    cloudflareTest({
      main: "./src/index.ts",
      miniflare: {
        // Keep in lockstep with cloudflare.config.ts; workerd max is 2026-10-13.
        compatibilityDate: COMPATIBILITY_DATE,
        compatibilityFlags: [...COMPATIBILITY_FLAGS],
        bindings: {
          VERSION: "0.1.7",
          GIT_SHA: "test-git-sha",
          RELAY_TOKEN: "test-relay-token",
          TYPESAFE_API_KEY: "test-official-key",
        },
      },
    }),
  ],
  test: {
    fsModuleCache: false,
    setupFiles: ["./test/setup.ts"],
    include: ["test/**/*.test.ts"],
    coverage: {
      provider: "istanbul",
      reportsDirectory: "coverage",
      include: ["src/**/*.ts"],
      exclude: ["**/*.d.ts"],
      reporter: ["text", "json-summary", "lcov"],
      thresholds: {
        statements: 95,
        branches: 95,
        functions: 95,
        lines: 95,
      },
    },
  },
});
