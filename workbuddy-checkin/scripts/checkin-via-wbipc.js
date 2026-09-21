"use strict";
/**
 * ============================================================
 * WorkBuddy 每日积分签到 —— WBIPC 通路（Node，零依赖）
 * ============================================================
 *
 * 与旧版 checkin.ps1 的根本区别：
 *   旧版：自己读取/解密本地 accessToken，再用 curl 打接口。
 *         桌面端 5.6.0 起 accessToken 变成 `{$wbEncrypted: 1, envelope: ...}` 信封，
 *         解密密钥来自 Electron 原生绑定 `workbuddyStorage.loggerGet()`，
 *         外部 Node 脚本在原理上拿不到 —— 该路径已不可用。
 *   本版：完全不经手令牌。走宿主动态开启的 WBIPC 通道，
 *         由宿主在发请求前注入 `Authorization: Bearer <token>` + `X-User-Id`
 *         （企业账号另带 `X-Enterprise-Id` / `X-Tenant-Id`）。
 *         因此不受登录态存储格式变化影响，也不会把长期凭据暴露给脚本。
 *
 * 前置条件：WorkBuddy 桌面端**正在运行**（命名管道随 daemon 生命周期存在），
 *           且已登录。发现文件：`~/.workbuddy/wbipc/endpoint.json`。
 *
 * 用法：
 *   node checkin-via-wbipc.js                执行签到（幂等，已签则跳过）
 *   node checkin-via-wbipc.js --status       只查询状态，不领取
 *   node checkin-via-wbipc.js --json         附机器可读 JSON 摘要行
 *
 * 退出码：0 = 已签到/本次签到成功；1 = 失败（守卫脚本据此决定是否写 marker）
 * ============================================================
 */

const { readDiscovery, WbipcClient } = require("./wbipc-client");

const STATUS_PATHS = [
  "/v2/billing/meter/checkin-activity-status",
  "/billing/meter/checkin-activity-status",
];
const CLAIM_PATHS = ["/v2/billing/meter/daily-checkin", "/billing/meter/daily-checkin"];

const args = process.argv.slice(2);
const STATUS_ONLY = args.includes("--status");
const WANT_JSON = args.includes("--json");

function out(line) {
  process.stdout.write(line + "\n");
}

function jsonLine(payload) {
  if (WANT_JSON) out("WBIPC_RESULT:" + JSON.stringify(payload));
}

/** POST 一个候选路径，命中非 404 即返回。 */
async function postFirst(client, paths, body) {
  let last = null;
  for (const p of paths) {
    const r = await client.fetch({
      method: "POST",
      path: p,
      headers: { "content-type": "application/json", accept: "application/json" },
      body: body === undefined ? "{}" : body,
    });
    if (r.status !== 404) return { path: p, res: r };
    last = { path: p, res: r };
  }
  return last;
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function main() {
  let disc;
  try {
    disc = readDiscovery();
  } catch (e) {
    out("RUNNER_ERR: " + e.message);
    out("hint: WBIPC 通道随 WorkBuddy 桌面端启动而存在，请先打开客户端并确认已登录。");
    return 1;
  }

  const client = new WbipcClient(disc, {
    kind: "skill",
    id: "workbuddy-checkin",
    version: "1.1.0",
  });

  try {
    const ack = await client.connect();
    if (!ack.pipes.includes("wb.request")) {
      out("RUNNER_ERR: 宿主未开放 wb.request 管道（当前登录态不可用）");
      out("hint: 请在 WorkBuddy 桌面端重新登录后重试。");
      return 1;
    }
    await client.openRequestPipe();

    // ---------- 1. 查询签到状态 ----------
    const st = await postFirst(client, STATUS_PATHS, "{}");
    if (st.res.status === 401 || st.res.status === 403) {
      out("令牌已过期或无权限（HTTP " + st.res.status + "），请在 WorkBuddy 桌面端刷新登录态");
      return 1;
    }
    if (st.res.status !== 200) {
      out("RUNNER_ERR: 查询签到状态失败（HTTP " + st.res.status + "）：" + st.res.body.slice(0, 200));
      return 1;
    }
    const stJson = parseJson(st.res.body);
    if (!stJson || stJson.code !== 0 || !stJson.data) {
      out("RUNNER_ERR: 查询签到状态返回异常：" + st.res.body.slice(0, 200));
      return 1;
    }

    const d0 = stJson.data;
    const streak0 = Number(d0.streak_days || 0);
    const todayCredit0 = Number(d0.today_credit || 0);

    if (d0.today_checked_in === true) {
      out("今日已签到，无需重复领取");
      out("credit=" + todayCredit0 + " streak_days=" + streak0);
      jsonLine({
        state: "already",
        today_checked_in: true,
        streak_days: streak0,
        total_credits: d0.total_credits,
        credit: todayCredit0,
        checkin_dates: d0.checkin_dates || [],
      });
      return 0;
    }

    if (STATUS_ONLY) {
      out("今日未签到（--status 模式，不领取）");
      out("credit=0 streak_days=" + streak0);
      jsonLine({ state: "pending", today_checked_in: false, streak_days: streak0, total_credits: d0.total_credits });
      return 0;
    }

    // ---------- 2. 领取签到 ----------
    const cl = await postFirst(client, CLAIM_PATHS, "{}");
    const clJson = parseJson(cl.res.body);

    // 幂等：接口返回 10001 或 400+10001 视为当日已完成
    const alreadyByIdempotency =
      (clJson && (clJson.code === 10001 || clJson.code === 409)) ||
      (cl.res.status === 400 && /10001/.test(cl.res.body));

    if (cl.res.status === 401 || cl.res.status === 403) {
      out("令牌已过期或无权限（HTTP " + cl.res.status + "），请在 WorkBuddy 桌面端刷新登录态");
      return 1;
    }
    if (alreadyByIdempotency) {
      out("今日已签到，无需重复领取（接口幂等拒绝）");
      out("credit=" + todayCredit0 + " streak_days=" + streak0);
      jsonLine({ state: "already", today_checked_in: true, streak_days: streak0, credit: todayCredit0, checkin_dates: d0.checkin_dates || [] });
      return 0;
    }
    if (!clJson || clJson.code !== 0 || !clJson.data) {
      out("RUNNER_ERR: 签到失败（HTTP " + cl.res.status + "）：" + cl.res.body.slice(0, 200));
      return 1;
    }

    const credit = Number(clJson.data.credit || 0);
    let streak = Number(clJson.data.streak_days || streak0);

    // ---------- 3. 回查，取最终连签与日历数据 ----------
    let dates = d0.checkin_dates || [];
    try {
      const st2 = await postFirst(client, STATUS_PATHS, "{}");
      const j2 = parseJson(st2.res.body);
      if (j2 && j2.code === 0 && j2.data) {
        streak = Number(j2.data.streak_days || streak);
        dates = j2.data.checkin_dates || dates;
      }
    } catch {
      /* 回查失败不影响签到结果 */
    }

    out("签到成功！领取 credit=" + credit + " streak_days=" + streak);
    jsonLine({
      state: "success",
      today_checked_in: true,
      credit,
      streak_days: streak,
      is_streak_day: clJson.data.is_streak_day === true,
      checkin_dates: dates,
    });
    return 0;
  } catch (e) {
    out("RUNNER_ERR: " + (e.code ? e.code + " " : "") + e.message);
    if (e.code === "E_NOT_CONNECTED") out("hint: " + JSON.stringify(e.data || {}));
    return 1;
  } finally {
    client.close();
  }
}

main().then(
  (code) => process.exit(code),
  (e) => {
    out("RUNNER_ERR: " + (e && e.message ? e.message : String(e)));
    process.exit(1);
  }
);
