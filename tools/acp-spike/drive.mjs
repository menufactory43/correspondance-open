// Pilote un agent ACP en JSON-RPC sur stdio, comme le ferait correspondance-agent.
// Usage : node drive.mjs "<commande>" "<prompt>" [--allow]
//   --allow : répond « autorisé » aux session/request_permission (sinon : refusé)
import { spawn } from "node:child_process";

const [cmd, promptText] = process.argv.slice(2);
const allow = process.argv.includes("--allow");
const cwd = process.cwd();

const env = { ...process.env };
delete env.ANTHROPIC_API_KEY;
delete env.ANTHROPIC_AUTH_TOKEN;
// Ne pas hériter du harnais Claude Code qui nous lance.
for (const k of Object.keys(env)) if (k.startsWith("CLAUDE_CODE_")) delete env[k];
delete env.CLAUDECODE;
delete env.CLAUDE_PID;
delete env.CLAUDE_EFFORT;
delete env.CLAUDE_EFFORT_LEVEL;

const child = spawn(cmd, { shell: true, stdio: ["pipe", "pipe", "pipe"], env, cwd });

let nextId = 1;
const pending = new Map();
const log = (dir, obj) => console.log(`${dir} ${JSON.stringify(obj)}`);

function send(obj) {
  log("→", obj);
  child.stdin.write(JSON.stringify(obj) + "\n");
}
function request(method, params) {
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    send({ jsonrpc: "2.0", id, method, params });
  });
}
function respond(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

let buf = "";
child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { console.log("‼ non-JSON:", line); continue; }
    log("←", msg);

    if (msg.id !== undefined && msg.method) {
      // Requête de l'agent vers nous.
      if (msg.method === "session/request_permission") {
        console.log(`★ PERMISSION DEMANDÉE — outil: ${JSON.stringify(msg.params?.toolCall?.title ?? msg.params?.toolCall?.rawInput ?? "?")}`);
        const opts = msg.params?.options ?? [];
        const pick = allow
          ? opts.find((o) => /allow/i.test(o.kind ?? o.optionId ?? ""))
          : opts.find((o) => /reject/i.test(o.kind ?? o.optionId ?? ""));
        respond(msg.id, { outcome: { outcome: "selected", optionId: (pick ?? opts[0])?.optionId } });
      } else if (msg.method === "fs/read_text_file") {
        respond(msg.id, { content: "" });
      } else if (msg.method === "fs/write_text_file") {
        respond(msg.id, {});
      } else {
        respond(msg.id, {});
      }
      continue;
    }
    if (msg.id !== undefined && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    }
  }
});
child.stderr.on("data", (d) => process.stderr.write("[stderr] " + d.toString()));

const timer = setTimeout(() => { console.log("‼ TIMEOUT 120 s"); child.kill("SIGKILL"); process.exit(2); }, 120000);

try {
  const init = await request("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: false },
  });
  console.log("✓ initialize:", JSON.stringify(init));

  const session = await request("session/new", { cwd, mcpServers: [] });
  console.log("✓ session/new:", JSON.stringify(session));

  const res = await request("session/prompt", {
    sessionId: session.sessionId,
    prompt: [{ type: "text", text: promptText }],
  });
  console.log("✓ session/prompt:", JSON.stringify(res));
} catch (e) {
  console.log("✗ ÉCHEC:", e.message);
  process.exitCode = 1;
} finally {
  clearTimeout(timer);
  child.kill();
}
