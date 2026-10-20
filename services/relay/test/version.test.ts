import { describe, expect, it } from "vitest";
import { parseMarketingVersion, resolveGitSha } from "../src/version.ts";

describe("version", () => {
  it("reads MARKETING_VERSION from project.yml text", () => {
    expect(parseMarketingVersion('MARKETING_VERSION: "0.1.7"\n')).toBe("0.1.7");
    expect(
      parseMarketingVersion(`
targets:
  Falcon:
    settings:
      base:
        MARKETING_VERSION: "0.1.7"
        CURRENT_PROJECT_VERSION: "8"
`),
    ).toBe("0.1.7");
  });

  it("rejects missing MARKETING_VERSION", () => {
    expect(() => parseMarketingVersion('CURRENT_PROJECT_VERSION: "8"\n')).toThrow(
      /MARKETING_VERSION missing/,
    );
  });

  it("prefers GIT_SHA then WORKERS_CI_COMMIT_SHA then GITHUB_SHA then git", () => {
    expect(
      resolveGitSha(
        { GIT_SHA: "env-sha", WORKERS_CI_COMMIT_SHA: "ci-sha", GITHUB_SHA: "gh-sha" },
        () => "git-sha",
      ),
    ).toBe("env-sha");
    expect(
      resolveGitSha({ WORKERS_CI_COMMIT_SHA: "ci-sha", GITHUB_SHA: "gh-sha" }, () => "git-sha"),
    ).toBe("ci-sha");
    expect(resolveGitSha({ GITHUB_SHA: " gh-sha " }, () => "git-sha")).toBe("gh-sha");
    expect(resolveGitSha({}, () => "git-sha\n")).toBe("git-sha");
  });

  it("rejects empty gitSha sources", () => {
    expect(() => resolveGitSha({}, () => "  ")).toThrow(/gitSha missing/);
  });
});
