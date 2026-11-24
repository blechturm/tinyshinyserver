// Protocol-level load generator for the benchmark app (bench/app/app.R).
//
// Each virtual user opens the app like a browser does: it requests the page,
// following the logical endpoint's redirect to a replica, opens the page's
// WebSocket, sends Shiny's init message, and then sends input updates and
// waits for the output that answers each one. Every answer starts with the
// request id, so each operation's latency is measured exactly, and the answer
// names the process that computed it.
//
// Needs Node.js 22 or later (global fetch and WebSocket); no packages.
//
//   node loadgen.mjs --url http://127.0.0.1:3838/proxy/demo/ --scenario B \
//     --users 20 --duration 30 --warmup 10 --out run.csv --summary run.json

import { writeFileSync } from "node:fs";
import { ShinySession } from "./shiny-client.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith("--")) pairs.push([arg.slice(2), all[i + 1]?.startsWith("--") ? "true" : all[i + 1]]);
    return pairs;
  }, [])
);
const URL_ = args.url;
const USERS = Number(args.users ?? 10);
const DURATION = Number(args.duration ?? 30) * 1000;
const WARMUP = Number(args.warmup ?? 10) * 1000;
const SCENARIO = args.scenario ?? "A";
const HEAVY_UNITS = Number(args["heavy-units"] ?? 500); // ~0.5 s of CPU
const IO_MS = Number(args["io-ms"] ?? 500);
const OP_TIMEOUT = Number(args["op-timeout"] ?? 120) * 1000;
const RAMP = Number(args.ramp ?? 2) * 1000; // users arrive spread over this
const SEED = Number(args.seed ?? 1);
// With session churn, each user leaves after this many operations and a new
// visitor takes its place at once, so sessions keep being assigned
// throughout the run; 0 keeps each user's first session for the whole run.
const SESSION_OPS = Number(args["session-ops"] ?? 0);

// Workload of each scenario: the role of user i, and what each role does.
// think: mean think time in ms between an answer and the next request.
const ROLES = {
  light: { op: "fast", think: 500 },
  heavy: { op: "cpu", amount: HEAVY_UNITS, think: 2000 },
  io: { op: "io", amount: IO_MS, think: 1000 },
  saturate: { op: "cpu", amount: 250, think: 250 },
  stateful: { op: "state", think: 500 },
  // bench/app-data: filter one of 100 categories and aggregate
  querier: { op: "query", amount: () => 1 + Math.floor(random() * 100), think: 500 },
};
function roleOf(i) {
  switch (SCENARIO) {
    case "A": return i % 5 === 4 ? "stateful" : "light";
    case "B": return i % 5 === 4 ? "heavy" : "light"; // 20% heavy
    case "C": return i % 5 === 4 ? "io" : "light"; // 20% blocking I/O
    case "D": return "saturate";
    case "Q": return i % 2 === 1 ? "querier" : "light"; // half query the dataset
    default: throw new Error("Unknown scenario " + SCENARIO);
  }
}

// Deterministic exponential think times
let rng = SEED >>> 0 || 1;
function random() {
  rng ^= rng << 13; rng >>>= 0; rng ^= rng >>> 17; rng ^= rng << 5; rng >>>= 0;
  return rng / 4294967296;
}
const exponential = (mean) => -mean * Math.log(1 - random());
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const rows = [];
const sessions = [];
let errors = 0;
const t0 = performance.now();
const now = () => performance.now() - t0;

async function openSession(i) {
  const arrival = now();
  try {
    const session = await new ShinySession({ timeoutMs: OP_TIMEOUT }).open(URL_);
    sessions.push({ user: i, role: roleOf(i), replica: session.replica, startup_ms: session.startup, arrival_ms: arrival, error: "" });
    return session;
  } catch (e) {
    errors++;
    sessions.push({ user: i, role: roleOf(i), replica: "", startup_ms: NaN, arrival_ms: arrival, error: String(e.message) });
    return null;
  }
}

async function user(i) {
  const role = ROLES[roleOf(i)];
  await sleep(random() * RAMP);
  let session = await openSession(i);
  if (!session) return;
  let n = 0;
  let sessionOps = 0;
  while (now() < DURATION) {
    if (SESSION_OPS > 0 && sessionOps >= SESSION_OPS) {
      session.close();
      session = await openSession(i);
      if (!session) return;
      sessionOps = 0;
    }
    await sleep(exponential(role.think));
    if (now() >= DURATION) break;
    const id = `u${i}r${++n}`;
    const sent = now();
    sessionOps++;
    try {
      const amount = typeof role.amount === "function" ? role.amount() : role.amount;
      const answer = await session.request(role.op, id, amount);
      const done = now();
      rows.push([sent.toFixed(1), done.toFixed(1), (done - sent).toFixed(2), role.op, i, session.replica, answer[1], sent < WARMUP ? 1 : 0, ""]);
    } catch (e) {
      const done = now();
      errors++;
      rows.push([sent.toFixed(1), done.toFixed(1), (done - sent).toFixed(2), role.op, i, session.replica, "", sent < WARMUP ? 1 : 0, e.message]);
      if (e.message === "websocket closed") break;
    }
  }
  session.close();
}

const quantile = (sorted, q) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : null;

await Promise.all(Array.from({ length: USERS }, (_, i) => user(i)));

const header = "sent_ms,done_ms,latency_ms,op,user,replica,pid,warmup,error";
if (args.out) writeFileSync(args.out, [header, ...rows.map((r) => r.join(","))].join("\n") + "\n");

const measured = rows.filter((r) => r[7] === 0);
const window = (DURATION - WARMUP) / 1000;
const byOp = {};
for (const op of [...new Set(measured.map((r) => r[3]))]) {
  const ok = measured.filter((r) => r[3] === op && r[8] === "");
  const lat = ok.map((r) => Number(r[2])).sort((a, b) => a - b);
  byOp[op] = {
    n: ok.length, errors: measured.filter((r) => r[3] === op && r[8] !== "").length,
    throughput_per_s: ok.length / window,
    p50: quantile(lat, 0.5), p95: quantile(lat, 0.95), p99: quantile(lat, 0.99), max: lat.at(-1) ?? null,
  };
}
const startups = sessions.filter((s) => SESSION_OPS === 0 || s.arrival_ms >= WARMUP).map((s) => s.startup_ms).filter(Number.isFinite).sort((a, b) => a - b);
const distribution = {};
for (const s of sessions) distribution[s.replica || "(failed)"] = (distribution[s.replica || "(failed)"] ?? 0) + 1;
const summary = {
  scenario: SCENARIO, users: USERS, session_ops: SESSION_OPS, duration_s: DURATION / 1000, warmup_s: WARMUP / 1000, url: URL_,
  sessions: sessions.length, session_errors: sessions.filter((s) => s.error).length, errors,
  startup_ms: { p50: quantile(startups, 0.5), p95: quantile(startups, 0.95), max: startups.at(-1) ?? null },
  distribution, ops: byOp,
};
if (args.summary) writeFileSync(args.summary, JSON.stringify({ ...summary, session_detail: sessions }, null, 1));
console.log(JSON.stringify(summary));
process.exit(0);
