// Décompose ce qu'un tour paie : lancement du processus, initialize,
// session/load (reprise d'une conversation), puis le prompt lui-même.
import { spawn } from "node:child_process";

const env = { ...process.env };
for (const k of Object.keys(env)) if (k.startsWith("CLAUDE_CODE_")) delete env[k];
delete env.CLAUDECODE;
delete env.ANTHROPIC_API_KEY;

function client() {
  const child = spawn("npx --no-install claude-code-acp", { shell: true, stdio: ["pipe", "pipe", "pipe"], env, cwd: process.cwd() });
  let id = 1, buf = "";
  const pending = new Map();
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const l = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!l) continue;
      let m;
      try { m = JSON.parse(l); } catch { continue; }
      if (m.id !== undefined && m.method) {
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { outcome: { outcome: "selected", optionId: "allow_always" } } }) + "\n");
      } else if (pending.has(m.id)) {
        const p = pending.get(m.id);
        pending.delete(m.id);
        m.error ? p.rej(new Error(JSON.stringify(m.error))) : p.res(m.result);
      }
    }
  });
  const req = (method, params) => new Promise((res, rej) => {
    const i = id++;
    pending.set(i, { res, rej });
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n");
  });
  return { req, kill: () => child.kill() };
}

const caps = { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } } };
const ms = (t) => Math.round(Number(process.hrtime.bigint() - t) / 1e6);
const cwd = process.cwd();

// Une conversation qui existe déjà — c'est le cas courant : un agent répond
// dans une room où il a déjà répondu.
const seed = client();
await seed.req("initialize", caps);
const s = await seed.req("session/new", { cwd, mcpServers: [] });
await seed.req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Retiens : bleu. Réponds OK." }] });
seed.kill();

// TOUR FROID : tout, comme aujourd'hui — un processus par tour.
for (let n = 0; n < 2; n++) {
  const t0 = process.hrtime.bigint();
  const c = client();
  await c.req("initialize", caps);
  const tInit = ms(t0);
  const t1 = process.hrtime.bigint();
  await c.req("session/load", { sessionId: s.sessionId, cwd, mcpServers: [] });
  const tLoad = ms(t1);
  const t2 = process.hrtime.bigint();
  await c.req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Réponds uniquement OK." }] });
  const tPrompt = ms(t2);
  console.log(`froid  → processus+initialize ${tInit} ms · session/load ${tLoad} ms · prompt ${tPrompt} ms · TOTAL ${tInit + tLoad + tPrompt} ms`);
  c.kill();
}

// TOUR CHAUD : le processus et la session sont déjà là, on n'envoie que le prompt.
const warm = client();
await warm.req("initialize", caps);
await warm.req("session/load", { sessionId: s.sessionId, cwd, mcpServers: [] });
for (let n = 0; n < 2; n++) {
  const t = process.hrtime.bigint();
  await warm.req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Réponds uniquement OK." }] });
  console.log(`chaud  → prompt seul ${ms(t)} ms`);
}
warm.kill();
process.exit(0);
