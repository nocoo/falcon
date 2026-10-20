import { setupNetwork } from "@msw/cloudflare";

export const network = setupNetwork();
network.configure({ onUnhandledFrame: "error" });
