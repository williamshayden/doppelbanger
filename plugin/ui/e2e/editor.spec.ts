import { expect, test } from "@playwright/test";
import { mkdirSync } from "node:fs";

test("renders the final 760 by 500 editor without non-loopback requests", async ({ page }) => {
  await page.addInitScript(() => { window.IPlugSendMsg = () => undefined; });
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") {
      await route.abort();
      return;
    }
    await route.continue();
  });
  await page.goto("/");
  await expect(page.getByText("DOPPELBANGER")).toBeVisible();
  await expect(page.getByRole("slider", { name: "LOW" })).toBeVisible();
  await page.getByRole("slider", { name: "LOW" }).fill("0.75");
  await page.getByRole("switch", { name: "BYPASS" }).click();
  await page.evaluate(() => window.scrollTo(0, 0));
  mkdirSync("../../var/validation/react-editor", { recursive: true });
  await page.screenshot({ path: "../../var/validation/react-editor/editor-760x500.png" });
});

test("maintains the fixed design surface at a double-density viewport", async ({ browser }) => {
  const page = await browser.newPage({ viewport: { width: 1520, height: 1000 } });
  await page.goto("/");
  await expect(page.locator(".editor-shell")).toHaveCSS("width", "760px");
  await page.close();
});
