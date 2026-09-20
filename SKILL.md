---
name: workbuddy-checkin-calendar
description: WorkBuddy 签到日历 —— 自动签到并维护一张可视化记录表（统计卡片 + 五状态签到日历 + 明细表），支持补记缺失的积分记录、按周统计与口径核查。适用于查询/展示 WorkBuddy 签到情况、签到日历、签到记录表、本周签到成功次数、已领取积分、连签天数，以及修复因手动签到导致的积分统计偏小。触发词：签到日历、签到记录表、签到统计、签到明细、查看签到、补记签到、WorkBuddy 积分。
version: "1.0.0"
license: MIT
agent_created: true
---

# WorkBuddy 签到日历

自动完成 WorkBuddy 每日积分签到，并把结果累积成一张可读、可核对的可视化记录表（HTML 日历页 + Markdown 表 + CSV 源数据）。

- **签到能力**复用内置子 skill `workbuddy-checkin/`（vendored，负责读取本地登录态、调用官方接口），本 skill 负责**调度 + 记录 + 渲染 + 核对**；仓库自包含，克隆即可用，无需额外安装依赖。
- 全流程本机运行，无后端服务，网络仅发往腾讯官方接口。

## 何时使用

- 用户要「签到」「看看签到情况」「签到日历」「签到记录表」「签到明细」。
- 用户问「本周签到成功几次 / 已领取多少积分 / 连签几天 / 最近一次签到」。
- 用户发现积分统计偏小，需要补记某天缺失的积分记录。
- 需要为签到任务配置定时自动化（见「配置定时任务」）。

## 快速开始

Windows PowerShell：

```powershell
# 签到一次并重建记录表（默认输出到 <当前目录>\signin-records）
powershell -ExecutionPolicy Bypass -File scripts\checkin_calendar.ps1

# 指定输出目录
powershell -ExecutionPolicy Bypass -File scripts\checkin_calendar.ps1 -OutDir "D:\data\signin-records"

# 只按现有 CSV 重建表格，不签到、不追加行（改样式后刷新用）
powershell -ExecutionPolicy Bypass -File scripts\checkin_calendar.ps1 -OutDir "<dir>" -RebuildOnly

# 排障：只打印依赖解析结果
powershell -ExecutionPolicy Bypass -File scripts\checkin_calendar.ps1 -ShowPaths
```

脚本不做交互，可安全重复运行（幂等，见下）。

## 参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `-OutDir <path>` | `<当前目录>\signin-records` | 记录输出目录，不存在会自动创建 |
| `-RebuildOnly` | 关 | 只按现有 CSV 重建 MD/HTML，不签到、不追加行 |
| `-GuardPath <p>` | 自动定位 | 守卫脚本 `checkin_guard.ps1` 路径；默认自动找同级 `workbuddy-checkin` skill |
| `-Title <t>` | `WorkBuddy签到日历` | 页面标题 / MD 一级标题 |
| `-ShowPaths` | 关 | 只打印 `OUTDIR` / `GUARD` / `NODE` 解析结果后退出 |

## 输出文件

| 文件 | 内容 |
|------|------|
| `checkin-records.html` | **主要交付件**：统计卡片 + 五状态签到日历 + 明细表，纯静态 HTML/CSS |
| `checkin-records.csv` | 结构化源数据，可被 Excel/WPS 直接打开 |
| `checkin-records.md` | 可读 Markdown（统计小表格 + 本月日历小结 + 全量明细） |
| `last_run.txt` | 最近一次状态行，含 `hint=` 兜底提醒字段 |
| `last_guard_output.txt` | 最近一次守卫脚本原始输出，排障用 |

CSV 字段：序号 / 执行时间 / 执行结果 / 执行结论 / 令牌状态 / 守卫脚本判定 / 积分·连签 / 备注。

## 签到幂等与调度策略

- **方案A（提前退出）**：运行前先判断今天是否已签到成功 —— 判据①守卫日期标记 `last_success.txt` == 今天；判据②本地记录里今天已有「签到成功 / 今日已签到」行。命中则直接退出：**不调接口、不追加 CSV 行**，只刷新 `last_run.txt`。因此每天通常只有一条真实记录。
- **不限定整点**：任何时刻运行都尝试签到，由守卫脚本内部幂等（当日已签则 SKIP，绝不重复领取）。
- **失败照常重试**：令牌失效 / 网络异常时守卫**不写**日期标记，后续运行会继续补签，直到当天签成为止。
- `-RebuildOnly` 只重建表格，不签到也不追加行。

## 统计口径

| 指标 | 口径 |
|------|------|
| 总计执行 | 表内全部记录行数 |
| ✅ 本周签到成功 | 本周内 `执行结果` 含「签到成功」的条数，上限 7 |
| ❌ 签到失败 | 全量 `执行结果` 含「失败」的条数 |
| 本周已领取积分 | 本周内各行 `积分/连签` 的 `credit=N` 累加，每周归零 |
| 累计已领取积分 | 全量 `credit=N` 累加 |
| 最近一次签到成功 | 最后一条**真实签到成功**记录（排除「今日已签到（守卫跳过）」行） |
| 本周范围 | 周一（第 1 天）~ 周日（第 7 天）；周日归属它之前那个周一所在的一周 |

**积分来源（重要，勿误解）**：

- **单次积分是接口真值**，来自 `POST /v2/billing/meter/daily-checkin` 响应中的 `data.credit` / `data.streak_days`，脚本内**没有任何 100/1000 硬编码常量**。
- **汇总积分是本地累加**，即对 CSV 各行 `credit=N` 求和。
- `checkin-status` 接口虽然有 `total_credits` / `week_checkin_days` 等权威总量字段，但**实测对部分账号恒返回 0**（`active:false`），不可作为数据源；因此只能本地累加。
- 由此产生一个**已知缺口**：若某天是用户在客户端手动签到、或接口返回 `code=10001`（已签到），该天记录里没有 `credit` 值 → 该天不进汇总。用 `scripts/add_record.py` 补记（方案B）。

## 补记缺失记录（方案B）

当发现「签到成功但积分没算进去」时，用补记工具写入一条带 `credit` 的记录：

```bash
python scripts/add_record.py --csv <dir>/checkin-records.csv \
    --time "2026-09-14 09:27:14" --result "签到成功（补记）" \
    --credit 100 --streak 8 --unique-date \
    --note "接口返回「今日已签到」，按每日基础分记"
```

- 按 `--time` 升序插入并自动重排序号，幂等（`--unique-date` 表示该日期已有记录就跳过）。
- `--dry-run` 只预览不落盘。
- 补记后加 `-RebuildOnly` 重新渲染表格即可看到统计更新。

## 页面设计约束（务必遵守）

- **禁止内嵌 JavaScript**：WorkBuddy 预览面板**不执行内嵌 JS**。月份切换用隐藏 `input[type=radio]` + `label[for]` + `:checked ~` 兄弟选择器实现；侧栏对齐用固定几何量（`th` 高 18px + `border-spacing:6px` ⇒ `.calside{margin-top:30px}`），不用 JS 测量。
- **日历可浏览范围**是滑动窗口「当前月 ±12 个月」恒 25 个月（纯静态必须预渲染全部月份，无法真正无限），HTML 体积恒定；更早历史仍在 CSV/MD 中。
- 中文 .ps1 必须存为 **UTF-8 带 BOM**，否则 PS 5.1 按 ANSI 读取会乱码。
- 明细表在 HTML 中只渲染最近 60 条（带提示行），CSV/MD 保留全量。

五状态配色与更多细节见 `references/design-notes.md`。

## 配置定时任务

用 `automation_update`（recurring）创建，例如每 3 小时触发一次（脚本幂等，仅在未签到时真正调用接口）：

```jsonc
{
  "name": "WorkBuddy 每日积分签到",
  "scheduleType": "recurring",
  "rrule": "FREQ=HOURLY;INTERVAL=3",
  "cwds": ["<用户工作目录>"],
  "status": "ACTIVE",
  "prompt": "运行 <skill>/scripts/checkin_calendar.ps1 -OutDir <工作目录>/signin-records，读取 signin-records/last_run.txt 的 hint 字段并按兜底提醒规则汇报，最后用 present_files 展示 signin-records/checkin-records.html。"
}
```

**兜底提醒规则**（读 `last_run.txt` 的 `hint=`）：

1. 以「夜间预警」开头（当天 21:00 后仍未签到成功）→ **醒目提醒用户**：定时任务依赖 WorkBuddy 客户端处于运行状态，整天未启动会直接断签；建议打开桌面端确认登录态与网络。
2. 含「令牌失效」→ 提醒打开 WorkBuddy 桌面端刷新登录态，后续运行会自动重试。
3. 含「本次尝试失败」→ 说明后续运行会自动重试，当天结束前仍有机会补上。
4. 「今日已完成（无需操作）」→ 正常汇报即可。

## 依赖与定位

| 依赖 | 用途 | 缺失时 |
|------|------|--------|
| skill `workbuddy-checkin` | 读取本地登录态、调用签到接口（`checkin_guard.ps1`） | 报 `RUNNER_ERR`，记录为失败；用 `-GuardPath` 指定 |
| Node.js | 守卫脚本解密本地登录态所需 | 用环境变量 `WB_CHECKIN_NODE` 或标准路径安装 |
| WorkBuddy 桌面端（已登录） | 提供本地登录态 | 无法签到，提示令牌不可用 |
| `curl.exe` | 守卫脚本调用接口 | Win10 1803+ 自带 |
| Python 3 | 仅 `add_record.py` 补记工具需要 | 不影响签到与渲染 |

脚本自动定位 Node（`WB_CHECKIN_NODE` → `~/.workbuddy/binaries/node/versions/*/node.exe` → `PATH` 中的 `node`）与守卫脚本（同级 skill → `~/.workbuddy/skills/workbuddy-checkin/`）。用 `-ShowPaths` 查看实际解析结果。

## 排错

- **`GUARD=(未找到…)`**：未安装 `workbuddy-checkin` skill；安装它，或用 `-GuardPath` 指定 `checkin_guard.ps1`。
- **表格中文乱码**：`.ps1` 丢了 UTF-8 BOM。重新以「UTF-8 带 BOM」保存。
- **点击上一月/下一月无反应**：页面被改回了依赖内嵌 JS 的实现。改回纯 CSS 方案。
- **`Sort-Object` 导致死循环**：对只含单个元素的月份集合排序会返回标量字符串，再取 `[0]` 会得到首字符并使 `Substring` 抛错。渲染月份列表时必须用 `[string[]]` 强类型 + 有界循环。
- **PowerShell 工具 stdout 捕获为空**：嵌套调用 `powershell.exe -ExecutionPolicy Bypass -File …` 并把输出重定向到文件后再读取。
- **统计数字偏小**：见「积分来源」的已知缺口，用 `add_record.py` 补记。
- **连签第 7 天奖励可能漏算**：接口另有 `streak_bonus_credit` 字段；若第 7 天的奖励走独立字段返回，当前只累加 `credit` 会漏算 1000。届时用 `daily-checkin` 原始响应核对。

## 安全说明

- 本 skill **不读取、不保存任何令牌**；令牌读取与网络请求全部在 `workbuddy-checkin` 的守卫脚本内完成，本 skill 只消费其文本输出。
- 记录的 `积分/连签` 字段仅含 `credit=N streak=M`，**不含令牌、不含账号信息**。
- 网络访问：本 skill 自身不发起网络请求；间接请求仅发往腾讯官方接口 `copilot.tencent.com`。
- 写文件范围：仅 `-OutDir` 指定目录内的 5 个记录文件。
- 请勿用于他人账户或批量刷分。
