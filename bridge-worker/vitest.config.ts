import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          FLOW_COACH_MAILBOX_ID: "fixture-person",
          FLOW_COACH_ACTIONS_SECRET: "fixture-actions-secret",
          FLOW_COACH_DEVICE_SECRET: "fixture-device-secret",
          FLOW_COACH_LOCAL_TEST: "true",
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
