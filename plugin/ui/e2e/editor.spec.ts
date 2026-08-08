import { expect, test } from "@playwright/test";
import { mkdirSync } from "node:fs";

const expectedHostMessages = [
  { version: 1, type: "ui.ready", payload: {} },
  { version: 1, type: "parameter.begin_edit", payload: { id: 0 } },
  { version: 1, type: "parameter.set", payload: { id: 0, value: 0.75 } },
  { version: 1, type: "parameter.end_edit", payload: { id: 0 } },
  { version: 1, type: "parameter.begin_edit", payload: { id: 1 } },
  { version: 1, type: "parameter.set", payload: { id: 1, value: 0.25 } },
  { version: 1, type: "parameter.end_edit", payload: { id: 1 } },
  { version: 1, type: "parameter.begin_edit", payload: { id: 2 } },
  { version: 1, type: "parameter.set", payload: { id: 2, value: 0.6 } },
  { version: 1, type: "parameter.end_edit", payload: { id: 2 } },
  { version: 1, type: "parameter.begin_edit", payload: { id: 3 } },
  { version: 1, type: "parameter.set", payload: { id: 3, value: 0.4 } },
  { version: 1, type: "parameter.end_edit", payload: { id: 3 } },
  { version: 1, type: "bypass.begin_edit", payload: {} },
  { version: 1, type: "bypass.set", payload: { value: true } },
  { version: 1, type: "bypass.end_edit", payload: {} }
];

async function exerciseControls(page: import("@playwright/test").Page) {
  await page.addInitScript(() => {
    const editorWindow = window as typeof window & { __doppelbangerMessages: unknown[] };
    editorWindow.__doppelbangerMessages = [];
    editorWindow.IPlugSendMsg = (message: string) => editorWindow.__doppelbangerMessages.push(JSON.parse(message));
  });
  await page.goto("/");
  for (const [label, value] of [["LOW", "0.75"], ["MID", "0.25"], ["HIGH", "0.6"], ["OUTPUT", "0.4"]] as const) {
    const control = page.getByRole("slider", { name: label });
    await control.dispatchEvent("pointerdown");
    await control.fill(value);
    await control.dispatchEvent("pointerup");
  }
  await page.getByRole("switch", { name: "BYPASS" }).click();
  await expect.poll(() => page.evaluate(() => (window as typeof window & { __doppelbangerMessages: unknown[] }).__doppelbangerMessages)).toEqual(expectedHostMessages);
}

test("renders and automates every control at 760 by 500 without non-loopback requests", async ({ page }) => {
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.hostname !== "127.0.0.1" && url.hostname !== "localhost") {
      await route.abort();
      return;
    }
    await route.continue();
  });
  await exerciseControls(page);
  await expect(page.getByText("DOPPELBANGER")).toBeVisible();
  await page.evaluate(() => window.scrollTo(0, 0));
  mkdirSync("../../var/validation/react-editor", { recursive: true });
  await page.screenshot({ path: "../../var/validation/react-editor/editor-760x500.png" });
});

test("automates every control and maintains the fixed design surface at 1520 by 1000", async ({ browser }) => {
  const page = await browser.newPage({ viewport: { width: 1520, height: 1000 } });
  await exerciseControls(page);
  await expect(page.locator(".editor-shell")).toHaveCSS("width", "760px");
  await page.close();
});
