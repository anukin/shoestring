// Captures documentation screenshots from a running Shoestring service that
// was seeded with tools/screenshots/seed.exs. See tools/screenshots/README.md.
//
//     node tools/screenshots/capture.js http://localhost:4000 docs/images
//
// Requires Playwright's Chromium. It only reads pages; it clicks nothing.
const { chromium } = require("playwright");
const path = require("path");

const base = process.argv[2] || "http://localhost:4000";
const out = process.argv[3] || "docs/images";

const pages = [
  ["usage", "/usage"],
  ["teams", "/teams"],
  ["agents", "/agents"],
  ["sessions", "/sessions"],
  ["session", "/sessions/sess-example"],
  ["lessons", "/lessons"],
];

(async () => {
  const browser = await chromium.launch();
  const context = await browser.newContext({
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 2,
    colorScheme: "light",
  });
  const page = await context.newPage();
  for (const [name, route] of pages) {
    await page.goto(base + route, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-phx-main].phx-connected, [data-phx-main]", { timeout: 10000 });
    const file = path.join(out, `${name}.png`);
    await page.screenshot({ path: file, fullPage: false });
    console.log(file);
  }
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
