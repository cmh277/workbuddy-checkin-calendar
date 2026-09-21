"use strict";
/**
 * ============================================================
 * WBIPC 客户端（Node，零依赖）
 * ============================================================
 *
 * WBIPC 是 WorkBuddy 宿主动态开启的**外部进程通道**。宿主的职责被明确限定为：
 *   「开通道、定协议、写一个约定路径的发现文件，到此为止」——不注入 env，
 *   不打包 SDK（`packages/wbipc-sdk-python` 只是官方参考实现）。
 *
 * 发现方式（不走环境变量）：读 `~/.workbuddy/wbipc/endpoint.json`，
 * 内容为 `{ "endpoint": "\\\\.\\pipe\\wbipc-<instanceId>", "ticket": "<base64url 32B>" }`。
 * Windows 下 endpoint 是命名管道名；POSIX 下是 socket 文件路径。
 *
 * 协议要点（设计 §5）：
 *   1. 换行分帧的 JSON。单帧上限 1 MiB，超限属于协议违约，直接断连。
 *   2. 握手三态 hello -> prove -> ready，必须在 5s 内走完。
 *      关键：**服务端先自证**。客户端先校验 server_proof，验不过直接硬失败，
 *      绝不把自己的 client_proof 交出去（防端点抢占）。
 *   3. ticket 只做 HMAC 密钥，**永不上线**。线上只传 ticket_id = sha256(ticket).hex[0:16]。
 *   4. transcript 用**长度前缀**拼接，避免 `a|bc` 与 `ab|c` 撞车（可延展性坑）。
 *
 * 业务价值：`wb.request` 管道把宿主登录态在发请求前注入为
 *   `Authorization: Bearer <token>` + `X-User-Id`（企业账号另带 `X-Enterprise-Id` / `X-Tenant-Id`）。
 * 因此**调用方完全不需要接触 accessToken**，也就不受登录态存储格式（明文 / $wbEncrypted 信封）变化影响。
 *
 * 调用方自带的请求头仅允许 `content-type` / `accept`；带鉴权头会被拒（E_BAD_REQUEST）。
 * 请求路径必须是相对路径，且宿主会把 baseUrl 固定为它自己解析出的后端 —— 调用方指定不了 host。
 */

const net = require("net");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const PROTOCOL = 1;
const HANDSHAKE_TIMEOUT_MS = 8000;
const DEFAULT_RPC_TIMEOUT_MS = 60000;
const PIPE_REQUEST = "wb.request";
const METHOD_FETCH = "http.fetch";

/** 宿主认可的请求头白名单（小写）。鉴权头由宿主填，调用方带了就报错。 */
const REQUEST_HEADER_ALLOWLIST = new Set(["content-type", "accept"]);

function base64url(buf) {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** ticket 的**公开**标识：sha256 前 8 字节的 hex。不是秘密。 */
function ticketId(ticket) {
  return crypto.createHash("sha256").update(ticket, "utf8").digest("hex").slice(0, 16);
}

/** 长度前缀拼接 transcript：role + protocol + endpoint + clientNonce + serverNonce。 */
function encodeTranscript(role, t) {
  const parts = [
    role === "server" ? "wbipc-s" : "wbipc-c",
    String(t.protocol),
    t.endpoint,
    t.clientNonce,
    t.serverNonce,
  ];
  const chunks = [];
  for (const part of parts) {
    const buf = Buffer.from(part, "utf8");
    const len = Buffer.alloc(4);
    len.writeUInt32BE(buf.length, 0);
    chunks.push(len, buf);
  }
  return Buffer.concat(chunks);
}

function computeProof(ticket, role, t) {
  return base64url(
    crypto.createHmac("sha256", Buffer.from(ticket, "utf8")).update(encodeTranscript(role, t)).digest()
  );
}

/** 常数时间比较。 */
function safeEqual(a, b) {
  const ab = Buffer.from(String(a), "utf8");
  const bb = Buffer.from(String(b), "utf8");
  if (ab.length !== bb.length || ab.length === 0) return false;
  return crypto.timingSafeEqual(ab, bb);
}

/** 与宿主同规则算出发现文件路径：`WORKBUDDY_CONFIG_DIR` 优先，否则 `~/.workbuddy`。 */
function discoveryPath(configDir) {
  const base = configDir || process.env.WORKBUDDY_CONFIG_DIR || path.join(os.homedir() || process.env.HOME || "", ".workbuddy");
  return path.join(base, "wbipc", "endpoint.json");
}

/** 读取发现文件。读不到 = 不在 WorkBuddy 环境里（或客户端未运行）。 */
function readDiscovery(configDir) {
  const file = discoveryPath(configDir);
  if (!fs.existsSync(file)) {
    const err = new Error("WorkBuddy 未在运行（找不到 " + file + "）");
    err.code = "NOT_WORKBUDDY_ENV";
    throw err;
  }
  const raw = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!raw.endpoint || !raw.ticket) {
    const err = new Error("发现文件内容不完整：" + file);
    err.code = "BAD_DISCOVERY";
    throw err;
  }
  return { file, endpoint: raw.endpoint, ticket: raw.ticket };
}

/** 把宿主返回的错误映射成带稳定 code 的异常。 */
function rpcError(err) {
  const e = new Error(err.message || "wbipc error");
  e.code = err.code || "E_INTERNAL";
  e.data = err.data;
  return e;
}

class WbipcClient {
  constructor(disc, clientInfo, opts) {
    this.endpoint = disc.endpoint;
    this.ticket = disc.ticket;
    this.client = clientInfo || { kind: "skill", id: "workbuddy-checkin", version: "1.0.0" };
    this.rpcTimeoutMs = (opts && opts.rpcTimeoutMs) || DEFAULT_RPC_TIMEOUT_MS;
    this._nextId = 1;
    this._pending = new Map();
    this._buf = Buffer.alloc(0);
    this._ack = null;
  }

  /** 建连 + 完成握手。resolve 出 `session_hello_ack`（含 pipes 列表）。 */
  connect() {
    return new Promise((resolve, reject) => {
      const sock = net.connect({ path: this.endpoint });
      this._sock = sock;
      sock.setNoDelay(true);
      let settled = false;
      const done = (fn, arg) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        fn(arg);
      };
      const timer = setTimeout(() => done(reject, new Error("WBIPC 握手超时")), HANDSHAKE_TIMEOUT_MS + 2000);

      sock.on("error", (e) => done(reject, e));
      sock.on("close", () => {
        for (const p of this._pending.values()) p.reject(new Error("WBIPC 连接已关闭"));
        this._pending.clear();
      });
      sock.on("data", (chunk) => this._onData(chunk));

      sock.once("connect", () => {
        this._clientNonce = base64url(crypto.randomBytes(16));
        this._onAck = (ack) => {
          if (ack.error) return done(reject, new Error("WBIPC 握手被拒：" + ack.error));
          this._ack = ack;
          done(resolve, ack);
        };
        this._write({
          type: "session_hello",
          protocol_min: PROTOCOL,
          protocol_max: PROTOCOL,
          client_nonce: this._clientNonce,
          ticket_id: ticketId(this.ticket),
          client: this.client,
        });
      });
    });
  }

  get pipes() {
    return (this._ack && this._ack.pipes) || [];
  }

  _write(obj) {
    if (!this._sock || this._sock.destroyed) return;
    this._sock.write(Buffer.from(JSON.stringify(obj) + "\n", "utf8"));
  }

  _onData(chunk) {
    this._buf = Buffer.concat([this._buf, chunk]);
    for (;;) {
      const nl = this._buf.indexOf(10);
      if (nl < 0) return;
      const line = this._buf.subarray(0, nl).toString("utf8");
      this._buf = this._buf.subarray(nl + 1);
      if (!line.trim()) continue;
      let frame;
      try {
        frame = JSON.parse(line);
      } catch {
        this._sock.destroy();
        return;
      }
      this._onFrame(frame);
    }
  }

  _onFrame(f) {
    if (f.type === "session_challenge") {
      // 关键安全步骤：先验服务端证明，验不过不交出 client_proof。
      const t = {
        protocol: PROTOCOL,
        endpoint: this.endpoint,
        clientNonce: this._clientNonce,
        serverNonce: f.server_nonce,
      };
      if (!safeEqual(computeProof(this.ticket, "server", t), f.server_proof)) {
        this._onAck && this._onAck({ error: "E_ENDPOINT_UNTRUSTED" });
        this._sock.destroy();
        return;
      }
      this._write({ type: "session_prove", client_proof: computeProof(this.ticket, "client", t) });
      return;
    }
    if (f.type === "session_hello_ack") return this._onAck && this._onAck(f);
    if (f.type === "session_hello_error") return this._onAck && this._onAck({ error: f.code });
    if (f.type === "pipe_revoked") return;
    if (f.jsonrpc === "2.0" && f.id !== undefined) {
      const p = this._pending.get(f.id);
      if (!p) return;
      this._pending.delete(f.id);
      clearTimeout(p.timer);
      if (f.error) p.reject(rpcError(f.error));
      else p.resolve(f.result);
    }
  }

  /** JSON-RPC 调用。channel 调用必须带 mode: "call"（v1 没有 stream 方法）。 */
  rpc(method, params, mode) {
    const id = this._nextId++;
    const frame = { jsonrpc: "2.0", id, method, params: params || {} };
    if (mode) frame.mode = mode;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this._pending.has(id)) {
          this._pending.delete(id);
          // 超时后补发 $/cancel，释放服务端 in-flight 槽位。
          this._write({ jsonrpc: "2.0", method: "$/cancel", params: { id } });
          const e = new Error("WBIPC 调用超时：" + method);
          e.code = "E_TIMEOUT";
          reject(e);
        }
      }, this.rpcTimeoutMs);
      this._pending.set(id, { resolve, reject, timer });
      this._write(frame);
    });
  }

  /** 绑定 wb.request 管道，拿到 channel id 与方法名列表。 */
  async openRequestPipe() {
    const r = await this.rpc("broker/GetPipe", { pipe: PIPE_REQUEST });
    this._channel = r.channel;
    return r;
  }

  /**
   * 通过宿主代理发一次 HTTP 请求。宿主自动注入鉴权头。
   * @returns {Promise<{status:number, headers:object, body:string}>}
   */
  async fetch(opts) {
    const headers = {};
    for (const [k, v] of Object.entries(opts.headers || {})) {
      const lower = k.toLowerCase();
      if (!REQUEST_HEADER_ALLOWLIST.has(lower)) {
        throw new Error("请求头 " + k + " 不在白名单内（仅允许 content-type / accept）");
      }
      headers[lower] = v;
    }
    const params = { method: (opts.method || "GET").toUpperCase(), path: opts.path, headers };
    if (opts.query) params.query = opts.query;
    if (opts.body !== undefined) {
      params.body_b64 = Buffer.from(opts.body, "utf8").toString("base64");
    }
    const channel = this._channel || "c:" + PIPE_REQUEST;
    const r = await this.rpc(channel + "/" + METHOD_FETCH, params, "call");
    return {
      status: r.status,
      headers: r.headers || {},
      body: Buffer.from(r.body_b64 || "", "base64").toString("utf8"),
    };
  }

  close() {
    try {
      this._sock && this._sock.destroy();
    } catch {}
  }
}

module.exports = {
  PROTOCOL,
  PIPE_REQUEST,
  METHOD_FETCH,
  REQUEST_HEADER_ALLOWLIST,
  WbipcClient,
  base64url,
  ticketId,
  encodeTranscript,
  computeProof,
  safeEqual,
  discoveryPath,
  readDiscovery,
};
