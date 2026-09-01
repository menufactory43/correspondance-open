// Vérifie la reprise : une session, un prompt, puis session/load dans un NOUVEAU processus.
import { spawn } from "node:child_process";
const env = { ...process.env };
for (const k of Object.keys(env)) if (k.startsWith("CLAUDE_CODE_")) delete env[k];
delete env.CLAUDECODE;
delete env.ANTHROPIC_API_KEY;

function client() {
  const child = spawn("npx --no-install claude-code-acp", { shell: true, stdio: ["pipe", "pipe", "pipe"], env, cwd: process.cwd() });
  let id = 1, buf = "";
  const pending = new Map();
  const texts = [];
  child.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const l = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!l) continue;
      let m;
      try { m = JSON.parse(l); } catch { continue; }
      if (m.params?.update?.content?.text) texts.push(m.params.update.content.text);
      if (m.id !== undefined && m.method) {
        child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { outcome: { outcome: "selected", optionId: "reject" } } }) + "\n");
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
  return { req, texts, kill: () => child.kill() };
}

const caps = { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } } };

const a = client();
await a.req("initialize", caps);
const s = await a.req("session/new", { cwd: process.cwd(), mcpServers: [] });
await a.req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Retiens ce mot : MARGUERITE. Réponds juste OK." }] });
console.log("session:", s.sessionId, "| réponse:", a.texts.join("").trim());
a.kill();

const b = client();
await b.req("initialize", caps);
try {
  const loaded = await b.req("session/load", { sessionId: s.sessionId, cwd: process.cwd(), mcpServers: [] });
  console.log("session/load OK", JSON.stringify(loaded).slice(0, 100));
  b.texts.length = 0;
  await b.req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Quel mot devais-tu retenir ? Un seul mot." }] });
  console.log("MEMOIRE ->", b.texts.join("").trim());
} catch (e) {
  console.log("ECHEC session/load:", e.message);
}
b.kill();
process.exit(0);
