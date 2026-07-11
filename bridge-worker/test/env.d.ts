import type { Env as FlowCoachEnv } from "../src/index";

declare global {
  namespace Cloudflare {
    interface Env extends FlowCoachEnv {}
  }
}
