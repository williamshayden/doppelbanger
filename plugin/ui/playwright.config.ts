import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  use: {
    channel: "msedge",
    baseURL: "http://127.0.0.1:4173",
    viewport: { width: 760, height: 500 }
  },
  webServer: {
    command: "npm run build && npx vite preview --host 127.0.0.1 --port 4173",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: false
  }
});
