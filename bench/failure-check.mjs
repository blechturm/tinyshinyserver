// Scenario E: terminate one replica while sessions are active.
//
//   node failure-check.mjs --url http://127.0.0.1:3838/proxy/demo/ \
//     --mgmt http://127.0.0.1:3839 --victim demo-1 [--kill-cmd "docker exec tss kill -9 {pid}"]
//     [--out failure.json]
//
// Sessions on every replica send light operations continuously. After a few
// seconds the victim replica's process is killed (by its PID from the
// management API, with process.kill() or kill-cmd when the server runs in a
// container). The script then records:
//   - whether sessions on the other replicas saw any error (fault isolation)
//   - how the victim's own sessions ended
//   - where new visitors were sent while the victim was down
//   - when the management API showed the victim running again, and whether
//     new visitors reached it afterwards
// Exits with status 1 if a session on a healthy replica failed or a new
// visitor was sent to the dead replica.

import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { ShinySession } from "./shiny-client.mjs";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith("--")) pairs.push([arg.slice(2), all[i + 1]]);
    return pairs;
  }, [])
);
const URL_ = args.url;
const MGMT = args.mgmt;
const VICTIM = args.victim;
const SESSIONS = Number(args.sessions ?? 8);
const KILL_AT = Number(args["kill-at"] ?? 5) * 1000;
const WATCH = Number(args.watch ?? 40) * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = performance.now();
const now = () => Math.round(performance.now() - t0);

async function appStatus(name) {
  const r = await fetch(MGMT + "/api/apps");
  const apps = await r.json();
  return Object.values(apps).find((a) => a.name === name);
}

const OP_TIMEOUT = Number(args["op-timeout"] ?? 10) * 1000;
const sessions = await Promise.all(Array.from({ length: SESSIONS }, () => new ShinySession({ timeoutMs: OP_TIMEOUT }).open(URL_)));
const outcome = sessions.map((s) => ({ replica: s.replica, ok: 0, failed: 0, first_error: null, error_at: null }));
let stop = false;
const loops = sessions.map(async (s, i) => {
  let n = 0;
  while (!stop) {
    try {
      await s.request("fast", `l${i}n${++n}`);
      outcome[i].ok++;
    } catch (e) {
      outcome[i].failed++;
      outcome[i].first_error ??= e.message;
      outcome[i].error_at ??= now();
      break;
    }
    await sleep(100);
  }
});

await sleep(KILL_AT);
const victim = await appStatus(VICTIM);
const killedAt = now();
if (args["kill-cmd"]) execSync(args["kill-cmd"].replace("{pid}", victim.pid));
else process.kill(victim.pid, "SIGKILL");
console.log(`killed ${VICTIM} (pid ${victim.pid}) at ${killedAt} ms`);

// New visitors while the victim is down, and after it is back
const arrivals = [];
let backAt = null;
let reachedVictimAt = null;
while (now() < killedAt + WATCH) {
  const status = await appStatus(VICTIM);
  const running = status?.status === "running" && status.pid !== victim.pid;
  if (running && backAt === null) backAt = now();
  try {
    const s = await new ShinySession({ timeoutMs: 10000 }).load(URL_);
    arrivals.push({ at: now(), replica: s.replica, victim_running: running });
    if (s.replica === VICTIM && reachedVictimAt === null && backAt !== null) {
      await s.connect();
      await s.request("fast", "probe");
      reachedVictimAt = now();
      s.close();
    }
  } catch (e) {
    arrivals.push({ at: now(), replica: "", error: e.message });
  }
  await sleep(250);
}
stop = true;
await Promise.allSettled(loops);
for (const s of sessions) s.close();

const healthy = outcome.filter((o) => o.replica !== VICTIM);
const victims = outcome.filter((o) => o.replica === VICTIM);
const sentToDead = arrivals.filter((a) => a.replica === VICTIM && !a.victim_running && a.at > killedAt + 100);
const result = {
  victim: VICTIM, killed_pid: victim.pid, killed_at_ms: killedAt,
  healthy_sessions: healthy.length,
  healthy_sessions_with_errors: healthy.filter((o) => o.failed > 0).length,
  victim_sessions: victims.length,
  victim_session_errors: victims.map((o) => ({ error: o.first_error, after_kill_ms: o.error_at === null ? null : o.error_at - killedAt })),
  arrivals_while_down: arrivals.filter((a) => !a.victim_running).length,
  arrivals_sent_to_dead_replica: sentToDead.length,
  victim_running_again_after_ms: backAt === null ? null : backAt - killedAt,
  new_session_reached_restarted_victim_after_ms: reachedVictimAt === null ? null : reachedVictimAt - killedAt,
  arrivals,
};
if (args.out) writeFileSync(args.out, JSON.stringify(result, null, 1));
const { arrivals: _, ...brief } = result;
console.log(JSON.stringify(brief, null, 1));
process.exit(result.healthy_sessions_with_errors === 0 && sentToDead.length === 0 ? 0 : 1);
