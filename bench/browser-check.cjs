// Browser check of a replica group, in headless Chromium through Playwright
// (on NODE_PATH, as for tests/browser):
//
//   node bench/browser-check.cjs http://127.0.0.1:3838/proxy/demo/ http://127.0.0.1:3839
//
// Opens the logical address in two browser contexts (two visitors) and in a
// second tab of the first, and checks in each page that the redirect chose a
// replica, that clicks are answered by that replica's process for that
// session, that an upload and a session download work, and then that killing
// one replica's process shows Shiny's disconnected overlay in its pages while
// a page on another replica keeps working.

const { chromium } = require("playwright");
const fs = require("fs");
const os = require("os");
const path = require("path");

const [url, mgmt] = process.argv.slice(2);
let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
};
const answer = async (page, output) => (await page.locator("#" + output).textContent()).split("|");

async function exercise(page, label) {
  await page.goto(url);
  await page.waitForFunction(() => document.querySelector("#session_id")?.textContent?.length > 0);
  const replica = new URL(page.url()).pathname.split("/")[2];
  const token = await page.locator("#session_id").textContent();
  const pid = (await page.locator("p code").textContent()).trim();
  await page.click("#b_fast");
  await page.waitForFunction(() => document.querySelector("#fast_out").textContent.includes("|"));
  await page.click("#b_state");
  await page.waitForFunction(() => document.querySelector("#state_out").textContent.includes("|"));
  await page.click("#b_state");
  await page.waitForFunction(() => document.querySelector("#state_out").textContent.endsWith("|2"));
  const fast = await answer(page, "fast_out");
  const state = await answer(page, "state_out");
  check(`${label}: redirected to a replica`, /^demo-\d+$/.test(replica), replica);
  check(`${label}: clicks answered by the page's process and session`,
    fast[1] === pid && fast[2] === token && state[1] === pid && state[3] === "2", `${pid}`);

  const file = path.join(os.tmpdir(), `tss-upload-${label.replace(/\W/g, "")}.txt`);
  fs.writeFileSync(file, "x".repeat(5000));
  await page.setInputFiles("#up", file);
  await page.waitForFunction(() => document.querySelector("#up_out").textContent.includes("|"));
  const up = await answer(page, "up_out");
  check(`${label}: upload reached the session`, up[1] === pid && up[2] === token && up[3] === "5000");

  const [download] = await Promise.all([page.waitForEvent("download"), page.click("#dl")]);
  const lines = fs.readFileSync(await download.path(), "utf8").trim().split(/\r?\n/);
  check(`${label}: download came from the session`, lines[0] === token && lines[1] === pid && lines[2] === "2",
    lines.join(","));
  return { page, replica, pid, token };
}

(async () => {
  const browser = await chromium.launch(process.env.TSS_TEST_BROWSER ? { executablePath: process.env.TSS_TEST_BROWSER } : {});
  const first = await browser.newContext({ acceptDownloads: true });
  const second = await browser.newContext({ acceptDownloads: true });
  const pages = [];
  pages.push(await exercise(await first.newPage(), "visitor 1"));
  pages.push(await exercise(await second.newPage(), "visitor 2"));
  pages.push(await exercise(await first.newPage(), "visitor 1, second tab"));
  check("visitors were spread over replicas", new Set(pages.map((p) => p.replica)).size > 1,
    pages.map((p) => p.replica).join(","));

  // Kill the replica of the first page
  const victim = pages[0];
  const survivors = pages.filter((p) => p.replica !== victim.replica);
  process.kill(Number(victim.pid), "SIGKILL");
  const t0 = Date.now();
  for (const p of pages.filter((p) => p.replica === victim.replica)) {
    const shown = await p.page.waitForSelector("#shiny-disconnected-overlay", { timeout: 15000 }).then(() => true, () => false);
    check(`page on killed ${victim.replica} shows Shiny's disconnected overlay`, shown, `${Date.now() - t0} ms`);
  }
  for (const p of survivors) {
    const before = (await answer(p.page, "fast_out"))[0];
    await p.page.click("#b_fast");
    const ok = await p.page.waitForFunction((b) => !document.querySelector("#fast_out").textContent.startsWith(b + "|"),
      before, { timeout: 5000 }).then(() => true, () => false);
    const overlay = await p.page.$("#shiny-disconnected-overlay");
    check(`page on ${p.replica} keeps working`, ok && !overlay);
  }
  // A new visit avoids the dead replica
  const fresh = await (await browser.newContext()).newPage();
  await fresh.goto(url);
  const replica = new URL(fresh.url()).pathname.split("/")[2];
  check("a new visitor is not sent to the killed replica", replica !== victim.replica, replica);
  await browser.close();
  console.log(failures ? `${failures} failed` : "all passed");
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
