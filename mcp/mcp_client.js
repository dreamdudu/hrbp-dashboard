// One-shot MCP client (no external deps). Reads a JSON request from stdin:
//   { transport:"stdio"|"http", command, args, env, cwd, url, headers, op:"list"|"call", tool, arguments, timeoutMs }
// Connects, performs the MCP handshake (initialize -> notifications/initialized),
// runs tools/list or tools/call, prints {ok, tools|result, error} JSON to stdout, then exits.
const { spawn } = require("child_process");

const PROTOCOL_VERSION = "2025-06-18";
const CLIENT_INFO = { name: "hrbp-dashboard", version: "1.0.0" };

function readStdin() {
  return new Promise((res) => {
    let buf = "";
    process.stdin.on("data", (d) => (buf += d));
    process.stdin.on("end", () => res(buf));
    setTimeout(() => res(buf), 2000); // safety if no end
  });
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj));
}

// ---------- stdio transport ----------
async function runStdio(req) {
  const timeoutMs = req.timeoutMs || 60000;
  const cmd = req.command;
  if (!cmd) throw new Error("缺少 command");
  const env = Object.assign({}, process.env, req.env || {});
  const child = spawn(cmd, req.args || [], {
    env,
    cwd: req.cwd || undefined,
    stdio: ["pipe", "pipe", "pipe"],
    shell: process.platform === "win32", // allow npx/uvx resolution on Windows
  });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d.toString()));

  let rxBuf = "";
  const pending = new Map(); // id -> {resolve,reject}
  child.stdout.on("data", (d) => {
    rxBuf += d.toString();
    let idx;
    while ((idx = rxBuf.indexOf("\n")) >= 0) {
      const line = rxBuf.slice(0, idx).trim();
      rxBuf = rxBuf.slice(idx + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch (e) { continue; }
      if (msg.id !== undefined && pending.has(msg.id)) {
        const p = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else p.resolve(msg.result);
      }
    }
  });

  let nextId = 1;
  function send(method, params) {
    const id = nextId++;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params: params || {} }) + "\n";
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(payload);
    });
  }
  function notify(method, params) {
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params: params || {} }) + "\n");
  }

  const killTimer = setTimeout(() => { try { child.kill(); } catch (e) {} }, timeoutMs);
  const fail = (e) => { clearTimeout(killTimer); try { child.kill(); } catch (x) {} throw e; };

  child.on("error", (e) => {
    for (const p of pending.values()) p.reject(new Error("无法启动 MCP 进程：" + e.message));
  });

  try {
    await send("initialize", {
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: CLIENT_INFO,
    });
    notify("notifications/initialized", {});
    let result;
    if (req.op === "call") {
      result = await send("tools/call", { name: req.tool, arguments: req.arguments || {} });
    } else {
      result = await send("tools/list", {});
    }
    clearTimeout(killTimer);
    try { child.kill(); } catch (e) {}
    return result;
  } catch (e) {
    e.message = (e.message || "") + (stderr ? ("\n[stderr] " + stderr.slice(0, 1500)) : "");
    fail(e);
  }
}

// ---------- streamable-http transport ----------
function httpRpc(url, headers, body) {
  return new Promise((resolve, reject) => {
    let mod, u;
    try { u = new URL(url); } catch (e) { return reject(new Error("无效的 URL")); }
    mod = u.protocol === "https:" ? require("https") : require("http");
    const data = JSON.stringify(body);
    const req = mod.request(
      url,
      {
        method: "POST",
        headers: Object.assign(
          { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "Content-Length": Buffer.byteLength(data) },
          headers || {}
        ),
      },
      (res) => {
        let buf = "";
        res.on("data", (d) => (buf += d.toString()));
        res.on("end", () => {
          // SSE? extract last data: line
          let txt = buf;
          if (/^\s*event:|^\s*data:/m.test(buf)) {
            const lines = buf.split(/\r?\n/).filter((l) => l.indexOf("data:") === 0).map((l) => l.slice(5).trim());
            txt = lines[lines.length - 1] || "";
          }
          try { resolve(JSON.parse(txt)); } catch (e) { reject(new Error("HTTP 响应解析失败：" + buf.slice(0, 500))); }
        });
      }
    );
    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

async function runHttp(req) {
  const url = req.url;
  if (!url) throw new Error("缺少 url");
  const headers = req.headers || {};
  let id = 1;
  const init = await httpRpc(url, headers, { jsonrpc: "2.0", id: id++, method: "initialize", params: { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: CLIENT_INFO } });
  if (init && init.error) throw new Error(init.error.message || "initialize 失败");
  // initialized notification (best effort)
  try { await httpRpc(url, headers, { jsonrpc: "2.0", method: "notifications/initialized", params: {} }); } catch (e) {}
  let resp;
  if (req.op === "call") resp = await httpRpc(url, headers, { jsonrpc: "2.0", id: id++, method: "tools/call", params: { name: req.tool, arguments: req.arguments || {} } });
  else resp = await httpRpc(url, headers, { jsonrpc: "2.0", id: id++, method: "tools/list", params: {} });
  if (resp && resp.error) throw new Error(resp.error.message || "调用失败");
  return resp && resp.result;
}

(async () => {
  let req;
  try {
    req = JSON.parse(await readStdin());
  } catch (e) {
    out({ ok: false, error: "请求解析失败" });
    process.exit(0);
  }
  try {
    const result = req.transport === "http" ? await runHttp(req) : await runStdio(req);
    if (req.op === "call") out({ ok: true, result: result });
    else out({ ok: true, tools: (result && result.tools) || [] });
  } catch (e) {
    out({ ok: false, error: (e && e.message) || String(e) });
  }
  process.exit(0);
})();
