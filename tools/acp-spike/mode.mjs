// claude-agent-acp démarre en mode « auto » (un classifieur tranche à notre place).
// Vérifie qu'un session/set_mode vers « default » nous rend la décision.
import { spawn } from "node:child_process";
const env = { ...process.env };
for (const k of Object.keys(env)) if (k.startsWith("CLAUDE_CODE_")) delete env[k];
delete env.CLAUDECODE;
delete env.ANTHROPIC_API_KEY;

const child = spawn("npx --no-install claude-agent-acp", { shell: true, stdio: ["pipe", "pipe", "pipe"], env, cwd: process.cwd() });
let id = 1, buf = "", asked = 0;
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
      if (m.method === "session/request_permission") {
        asked++;
        console.log("PERMISSION DEMANDEE ->", m.params?.toolCall?.title);
      }
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: m.method === "session/request_permission" ? { outcome: { outcome: "selected", optionId: "reject" } } : {} }) + "\n");
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

await req("initialize", { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } } });
const s = await req("session/new", { cwd: process.cwd(), mcpServers: [] });
console.log("mode au départ:", s.modes?.currentModeId);
await req("session/set_mode", { sessionId: s.sessionId, modeId: "default" });
console.log("mode forcé -> default");
await req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Lance la commande shell: echo bonjour > preuve3.txt" }] });
console.log("permissions demandées:", asked);
child.kill();
process.exit(0);
