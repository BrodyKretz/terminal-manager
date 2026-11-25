// Loads the page in headless Chromium against the mock native bridge at 1440x900, checks the main flows,
// fails on any console error, and writes screenshots.
//   PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core node app/web/test/ui-check.js <out-dir>
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const { chromium } = require(process.env.PLAYWRIGHT_CORE || "playwright-core");

const WEB = path.resolve(__dirname, "..");
const OUT = path.resolve(process.argv[2] || "ui-check-out");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".svg": "image/svg+xml" };

function serve() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    const file = path.join(WEB, decodeURIComponent(url.pathname));
    if (!file.startsWith(WEB) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve(server)));
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const server = await serve();
  const base = `http://127.0.0.1:${server.address().port}/index.html`;
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on("console", m => { if (m.type() === "error") errors.push(m.text()); });
  page.on("pageerror", e => errors.push(String(e)));
  await page.addInitScript({ path: path.join(__dirname, "mock-native.js") });
  const checks = [];
  const check = (name, ok, detail) => checks.push({ name, ok: !!ok, detail });
  const settle = () => page.waitForTimeout(500);
  const shot = name => page.screenshot({ path: path.join(OUT, `${name}.png`) });

  for (const [style, name] of [["a", "lavender"], ["b", "log"], ["c", "slate"]]) {
    await page.goto(`${base}?style=${style}`);
    await page.waitForFunction(() => window.__app && window.__app.B.ready);
    await page.evaluate(() => document.fonts.ready);
    await page.click('[data-act="trayToggle"][data-sid="t1"]');
    await page.waitForSelector('.tsh .xterm-host .xterm-screen');
    await settle();
    check(`${name}: lane shows two asks and one ready`, (await page.$$(".wcard")).length === 3);
    check(`${name}: list shows five Claude sessions`, (await page.$$(".row")).length === 8);
    await shot(`main-${name}`);
    await page.click('[data-act="trayToggle"][data-sid="t1"]');
  }

  await page.goto(`${base}?style=a`);
  await page.waitForFunction(() => window.__app && window.__app.B.ready);
  await page.evaluate(() => document.fonts.ready);
  await page.click('.row-main[data-sid="a1"]');
  await page.waitForSelector("#svTerm .xterm-screen");
  await page.waitForTimeout(700);
  check("session view shows the ask card", await page.$(".askp"));
  const termText = await page.evaluate(() => document.querySelector("#svTerm .xterm-rows") ? document.querySelector("#svTerm .xterm-rows").textContent : "");
  check("the main terminal renders its output", /Welcome to Claude Code/.test(termText), termText.slice(0, 80));
  await shot("session-needs-you");

  await page.keyboard.press("Escape");
  await page.evaluate(() => window.__app.goFeed());
  await page.evaluate(() => window.__app.openNew());
  await page.click('[data-act="nmNext"]');
  await settle();
  check("new session step 2 lists folders", (await page.$$(".dirs button")).length >= 5);
  await shot("new-session-folder");
  await page.click('[data-act="nmNext"]');
  await settle();
  check("new session step 3 offers four modes with Auto on", await page.evaluate(() => document.querySelectorAll(".modes button").length === 4 && document.querySelector(".modes button.on").textContent.startsWith("Auto")));
  await shot("new-session-mode");
  await page.keyboard.press("Escape");

  await page.evaluate(() => window.__app.openPrefs());
  await settle();
  check("settings shows three switches", (await page.$$(".pref .switch")).length === 3);
  await shot("settings");
  await page.keyboard.press("Escape");

  await page.click('.wcard [data-act="answer"][data-sid="a1"][data-i="0"]');
  await page.waitForTimeout(400);
  check("answering from the lane moves the session to working", await page.evaluate(() => window.__app.B.byId("a1").status === "working"));
  await page.evaluate(() => window.__app.openSession("t2"));
  await page.waitForSelector("#svTerm .xterm-screen");
  await page.waitForTimeout(400);
  check("a terminal session opens its real terminal", await page.evaluate(() => /git status/.test(document.querySelector("#svTerm .xterm-rows").textContent)));

  await browser.close();
  server.close();
  const failed = checks.filter(c => !c.ok);
  console.log(JSON.stringify({ checks: checks.length, failed, errors }, null, 2));
  process.exit(failed.length || errors.length ? 1 : 0);
}

main().catch(err => { console.error(err); process.exit(1); });
