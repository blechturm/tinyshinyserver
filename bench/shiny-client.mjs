// A minimal Shiny client that speaks the protocol a browser's shiny.js does:
// it loads the page, following redirects by hand so that the replica a
// logical endpoint chose is known, opens the page's WebSocket, sends init,
// and then sends input updates and RPC calls (file uploads).
//
// Needs Node.js 22 or later (global fetch and WebSocket).

export class ShinySession {
  constructor({ timeoutMs = 120000 } = {}) {
    this.timeoutMs = timeoutMs;
    this.waiters = new Map(); // output id -> { prefix, resolve, reject, timer }
    this.rpc = new Map(); // tag -> { resolve, reject }
    this.tag = 0;
    this.values = {};
  }

  // Load the page at url, or at the replica it redirects to
  async load(url) {
    let target = url;
    this.redirects = [];
    for (let hop = 0; hop < 5; hop++) {
      const r = await fetch(target, { redirect: "manual", headers: { Accept: "text/html" } });
      if (r.status >= 300 && r.status < 400) {
        target = new URL(r.headers.get("location"), target).toString();
        this.redirects.push(target);
        await r.arrayBuffer();
        continue;
      }
      if (r.status !== 200) throw new Error("page answered HTTP " + r.status);
      this.html = await r.text();
      break;
    }
    this.pageUrl = target;
    this.replica = (new URL(target).pathname.match(/\/proxy\/([^/]+)\//) || [])[1] ?? "";
    return this;
  }

  // Open the WebSocket of the loaded page and wait for the session's token
  async connect() {
    const wsUrl = new URL("websocket/", this.pageUrl);
    wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
    this.ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = () => reject(new Error("websocket error"));
    });
    this.closed = false;
    this.ws.onmessage = (event) => this.receive(event.data);
    this.ws.onclose = () => {
      this.closed = true;
      for (const [, w] of this.waiters) { clearTimeout(w.timer); w.reject(new Error("websocket closed")); }
      this.waiters.clear();
      for (const [, w] of this.rpc) w.reject(new Error("websocket closed"));
      this.rpc.clear();
    };
    const ready = this.waitFor("session_id", "");
    this.ws.send(JSON.stringify({ method: "init", data: {} }));
    this.token = await ready;
    return this;
  }

  async open(url) {
    const start = performance.now();
    await this.load(url);
    await this.connect();
    this.startup = performance.now() - start;
    return this;
  }

  receive(data) {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    if (msg.response && this.rpc.has(msg.response.tag)) {
      const w = this.rpc.get(msg.response.tag);
      this.rpc.delete(msg.response.tag);
      if (msg.response.error) w.reject(new Error(msg.response.error));
      else w.resolve(msg.response.value);
    }
    if (!msg.values) return;
    Object.assign(this.values, msg.values);
    for (const [id, value] of Object.entries(msg.values)) {
      const w = this.waiters.get(id);
      if (w && typeof value === "string" && value.startsWith(w.prefix)) {
        this.waiters.delete(id);
        clearTimeout(w.timer);
        w.resolve(value);
      }
    }
  }

  waitFor(output, prefix) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(output);
        reject(new Error("timeout"));
      }, this.timeoutMs);
      this.waiters.set(output, { prefix, resolve, reject, timer });
    });
  }

  // Send input op and wait for its output; resolves to the answer's fields
  // [id, pid, token, ...]
  async request(op, id, amount) {
    const answer = this.waitFor(op + "_out", id + "|");
    const value = amount === undefined ? id : id + ":" + amount;
    this.ws.send(JSON.stringify({ method: "update", data: { [op]: value } }));
    return (await answer).split("|");
  }

  call(method, args) {
    const tag = ++this.tag;
    return new Promise((resolve, reject) => {
      this.rpc.set(tag, { resolve, reject });
      this.ws.send(JSON.stringify({ method, args, tag }));
    });
  }

  // Upload bytes to fileInput inputId as shiny.js does; resolves to the
  // answer of output up_out
  async upload(inputId, name, bytes) {
    const job = await this.call("uploadInit", [[{ name, size: bytes.length, type: "application/octet-stream" }]]);
    const r = await fetch(new URL(job.uploadUrl, this.pageUrl), { method: "POST", body: bytes });
    if (!r.ok) throw new Error("upload answered HTTP " + r.status);
    await r.arrayBuffer();
    const answer = this.waitFor("up_out", "upload|");
    await this.call("uploadEnd", [job.jobId, inputId]);
    return (await answer).split("|");
  }

  // Fetch the session's download output id
  async download(id) {
    const href = this.values[id];
    if (typeof href !== "string") throw new Error("no download link for " + id);
    const r = await fetch(new URL(href, this.pageUrl));
    if (!r.ok) throw new Error("download answered HTTP " + r.status);
    return await r.text();
  }

  close() {
    try { this.ws.close(); } catch {}
  }
}
