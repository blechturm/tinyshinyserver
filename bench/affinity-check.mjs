// Protocol-level check of session affinity through a replica group's
// logical endpoint. Exits with status 1 if any check fails.
//
//   node affinity-check.mjs --url http://127.0.0.1:3838/proxy/demo/ --sessions 8
//
// For each of several sessions opened at once, as by visitors arriving
// together or one visitor's browser tabs, it checks that every operation,
// the session's mutable state, a download, and an upload are all served by
// the process of the replica that the redirect chose; that the sessions were
// spread over the replicas; that a reconnection at the replica's address
// returns to the same process; and that the logical address takes no
// WebSocket itself.

import { createHash, randomBytes } from "node:crypto";
import { ShinySession } from "./shiny-client.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith("--")) pairs.push([arg.slice(2), all[i + 1]]);
    return pairs;
  }, [])
);
const URL_ = args.url;
const SESSIONS = Number(args.sessions ?? 8);
const results = [];
const check = (name, ok, detail = "") => {
  results.push({ name, ok: !!ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  (" + detail + ")" : ""}`);
};

async function exercise(i) {
  const s = await new ShinySession({ timeoutMs: 30000 }).open(URL_);
  const pids = new Set();
  const note = (answer) => { pids.add(answer[1]); return answer; };
  note(await s.request("fast", `s${i}f`));
  const counts = [];
  for (let k = 1; k <= 3; k++) counts.push(note(await s.request("state", `s${i}c${k}`))[3]);
  note(await s.request("cpu", `s${i}p`, 5));
  note(await s.request("io", `s${i}o`, 10));
  const bytes = randomBytes(100 * 1024);
  const up = note(await s.upload("up", "data.bin", bytes));
  const download = (await s.download("dl")).trim().split(/\r?\n/);
  return { s, pids, counts, up, bytes, download };
}

try {
  const runs = await Promise.all(Array.from({ length: SESSIONS }, (_, i) => exercise(i)));
  const byReplica = {};
  for (const [i, r] of runs.entries()) {
    const pid = [...r.pids][0];
    byReplica[r.s.replica] ??= new Set();
    byReplica[r.s.replica].add(pid);
    check(`session ${i}: redirected to a replica`, r.s.redirects.length === 1 && r.s.replica !== "", r.s.replica);
    check(`session ${i}: all operations and the upload ran in one process`, r.pids.size === 1, [...r.pids].join(","));
    check(`session ${i}: session state is its own`, r.counts.join(",") === "1,2,3", r.counts.join(","));
    check(`session ${i}: upload reached the session intact`,
      r.up[2] === r.s.token && Number(r.up[3]) === r.bytes.length &&
      r.up[4] === createHash("md5").update(r.bytes).digest("hex"));
    check(`session ${i}: download came from the session's own process`,
      r.download[0] === r.s.token && r.download[1] === pid && r.download[2] === "3", r.download.join(","));
  }
  for (const [replica, pids] of Object.entries(byReplica)) {
    check(`replica ${replica}: served by a single process`, pids.size === 1, [...pids].join(","));
  }
  const counts = Object.values(Object.fromEntries(runs.map((r) => [r.s.replica, 0])));
  for (const r of runs) counts[Object.keys(byReplica).indexOf(r.s.replica)]++;
  check("sessions arriving together were spread over the replicas",
    Object.keys(byReplica).length > 1 || SESSIONS === 1, JSON.stringify(Object.fromEntries(
      Object.keys(byReplica).map((k) => [k, runs.filter((r) => r.s.replica === k).length])
    )));

  // A reconnection, as after a dropped connection or a reload of the
  // replica's own address, returns to the same process
  const first = runs[0];
  const pid = [...first.pids][0];
  first.s.close();
  await new Promise((r) => setTimeout(r, 200));
  const again = new ShinySession({ timeoutMs: 30000 });
  await again.load(first.s.pageUrl);
  await again.connect();
  const answer = await again.request("fast", "re");
  check("reconnection at the replica's address returns to its process",
    again.redirects.length === 0 && answer[1] === pid && again.token !== first.s.token, `${answer[1]} vs ${pid}`);
  again.close();

  // The logical endpoint has no process of its own to take a WebSocket
  const logicalWs = new URL("websocket/", URL_);
  logicalWs.protocol = "ws:";
  const refused = await new Promise((resolve) => {
    const ws = new WebSocket(logicalWs);
    ws.onmessage = () => resolve(false);
    ws.onclose = () => resolve(true);
    ws.onerror = () => resolve(true);
    setTimeout(() => resolve(false), 5000);
  });
  check("the logical address refuses WebSockets", refused);

  for (const r of runs) r.s.close();
} catch (e) {
  check("checks ran to completion", false, e.message);
}

const failed = results.filter((r) => !r.ok).length;
console.log(`${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
