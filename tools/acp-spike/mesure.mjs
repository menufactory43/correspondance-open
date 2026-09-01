// Combien coûte le démarrage d'un tour ACP : un processus neuf (froid) contre
// un processus déjà debout (chaud). Décide si on garde un moteur chaud par
// conversation ou si on relance à chaque tour.
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

// FROID : lancer le processus, initialize, session/new — tout ce qu'un tour
// paie avant même d'envoyer la question.
const froids = [];
for (let n = 0; n < 3; n++) {
  const t = process.hrtime.bigint();
  const c = client();
  await c.req("initialize", caps);
  const s = await c.req("session/new", { cwd: process.cwd(), mcpServers: [] });
  froids.push(ms(t));
  c.kill();
}

// CHAUD : le même processus, une session de plus — ce qu'on paierait si on
// gardait un moteur debout par conversation.
const c = client();
await c.req("initialize", caps);
const chauds = [];
for (let n = 0; n < 3; n++) {
  const t = process.hrtime.bigint();
  await c.req("session/new", { cwd: process.cwd(), mcpServers: [] });
  chauds.push(ms(t));
}

// Un tour complet, pour situer le démarrage dans le total.
const s = await c.req("session/new", { cwd: process.cwd(), mcpServers: [] });
const t = process.hrtime.bigint();
await c.req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Réponds uniquement OK." }] });
const tour = ms(t);
c.kill();

console.log("froid (processus + initialize + session/new) :", froids.join(" ms, "), "ms");
console.log("chaud (session/new seul)                     :", chauds.join(" ms, "), "ms");
console.log("un tour trivial (session/prompt)             :", tour, "ms");
process.exit(0);
