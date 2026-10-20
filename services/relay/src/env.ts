export type Env = {
  [K in keyof Cloudflare.Env]?: Cloudflare.Env[K];
} & {
  UPSTREAM_TIMEOUT_MS?: string;
  LIVE_TIMEOUT_MS?: string;
};
