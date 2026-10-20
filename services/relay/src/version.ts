export function parseMarketingVersion(yaml: string): string {
  const match = yaml.match(/MARKETING_VERSION:\s*"([^"]+)"/);
  if (!match?.[1]) {
    throw new Error("MARKETING_VERSION missing");
  }
  return match[1];
}

export function resolveGitSha(
  env: Record<string, string | undefined>,
  gitHead: () => string,
): string {
  const fromEnv =
    env.GIT_SHA?.trim() || env.WORKERS_CI_COMMIT_SHA?.trim() || env.GITHUB_SHA?.trim();
  if (fromEnv) {
    return fromEnv;
  }
  const sha = gitHead().trim();
  if (!sha) {
    throw new Error("gitSha missing");
  }
  return sha;
}
