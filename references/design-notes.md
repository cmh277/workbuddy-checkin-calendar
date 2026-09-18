# 设计说明与实现细节

本文件是 `workbuddy-checkin-calendar` 的深入参考，仅在需要修改页面/算法时加载。

## 1. 页面结构

```
h1  WorkBuddy签到日历
h2.h-stat  一 签到统计
    .trunc   本周范围（周一 = 第 1 天，周日 = 第 7 天）：A ~ B
    .summary 6 张卡片：总计执行 / 本周签到成功 / 签到失败 / 本周已领取积分 / 累计已领取积分 / 最近一次签到成功
h2.h-cal   二 签到日历
    .calwrap
        input.cmr  x25（隐藏单选，name="calm"）
        .calmain  25 个月网格 .calmonth.m-N
        aside.calside
            .navpair.p-N  月份标题 + ‹上一月 + 下一月›
            .callegend    五色图例
h2.h-det   三 签到明细
    .trunc（仅在截断时出现）
    table 明细（最多 60 行）
.gen 最近生成时间
```

三个 `h2` 使用主题色渐变背景 + 4px 左侧色条：统计蓝（`#e8f0fe` / `#1a73e8`）、日历绿（`#e6f4ea` / `#1e8e3e`）、明细琥珀（`#fdf3e0` / `#c8922b`）。

## 2. 纯静态月份切换（零 JS）

```css
.cmr      { position:absolute; width:0; height:0; opacity:0; pointer-events:none; }
.calmonth { display:none; }                 /* 默认全部隐藏 */
.navpair  { display:none; }

#cm-N:checked ~ .calmain .m-N { display:block; }   /* 选中月份显示网格 */
#cm-N:checked ~ .calside .p-N { display:flex;  }   /* 对应导航/标题显示 */
```

- 每个月各配一套 `.navpair`，所以切换后侧栏的**月份标题会自动变成对应月份**。
- 上/下月按钮是 `<label for="cm-{idx±1}">`；首月/末月的按钮降级为 `<span class="navbtn disabled">`。
- `.cmr` 必须放在 `.calmain` 之前、且是它们的**兄弟节点**，否则 `~` 选择器失效。

## 3. 侧栏与日历第一行的对齐（不写死、不测量）

星期表头行固定 `height:18px`；`table.cal` 用 `border-collapse:separate; border-spacing:6px`。
⇒ 日期行顶部恒在表格顶部下方 `6 + 18 + 6 = 30px`，故：

```css
.calside { margin-top:30px; }
```

与字号、窗口宽度无关，任何环境都成立。**不要**改回 JS 测量方案。

## 4. 日历五状态

| 状态 | 类名 | 底色 / 边框 | 日期字色 | 角标 |
|------|------|-------------|----------|------|
| 已签到 | `.c-ok` | `#eef8f0` / `#c6e6cd` | `#1e8e3e` | ✅ U+2705 |
| 失败 | `.c-bad` | `#fdeeec` / `#f3c9c4` | `#d93025` | ❌ U+274C |
| 未签到 | `.c-none` | `#fdf6e7` / `#f0dfb8` | `#c8922b` | — |
| 任务开始前 | `.c-pre` | `#f5f6f7` / `#ecf0f1` | `#c4c8cc` | — |
| 未来日 | `.c-future` | 白底默认边框 | `#bdc1c6` | — |

- 今天额外加 `.today`：`box-shadow:0 0 0 2px #1a73e8 inset`。
- 日期格：阳历大字（18px 粗）+ 农历小字（11px）+ 右上角状态角标。
- 周一为一周起点：`$offset = (([int]([DateTime]::new($y,$m,1)).DayOfWeek) + 6) % 7`。
- `c-pre` 的判定基准是 `$firstRecDate`（CSV 首条记录日期）：早于该日的日期算「任务开始前」，不计入「未签到」，避免误读成连续漏签。

## 5. 农历转换（离线查表，1900–2100）

`$lunarInfo` 为 201 个十六进制数：低 4 位 = 闰月月份，`0x10000` 位 = 闰月是否 30 天，`0x8000..0x8` 位 = 1–12 月的大小月。
辅助函数：`LeapMonth` / `LeapDays` / `LYearDays` / `MonthDays` / `SolarToLunar` / `LunarDayLabel`。

- 基准日 `1900-01-31`，`$offset` 为距基准的天数。
- 初一显示月份名（「八月」「闰六月」），其余显示日名（初一…三十）。
- 校验样例（2026-09）：9/11 = 八月初一、9/18 = 初八、9/25 = 十五（中秋），与公开历法一致。

## 6. 周定义与统计实现

```powershell
$dowN  = [int](Get-Date).DayOfWeek   # .NET: Sunday=0, Monday=1 ... Saturday=6
$backN = $dowN - 1
if ($dowN -eq 0) { $backN = 6 }      # 周日（第7天）回退 6 天到本周一（第1天）
$weekStartStr = $nowD.Date.AddDays(-$backN).ToString("yyyy-MM-dd HH:mm:ss")
```

- `执行时间` 定宽 `yyyy-MM-dd HH:mm:ss`，**字典序 == 时间序**，直接字符串比较即可，不用 `ParseExact`（避免异常）。
- 边界已验证：跨月 2026-10-01(Thu) → 起点 09-28；跨年 2027-01-03(Sun) → 起点 2026-12-28。
- 一周内 7 天的 `weekStart` 全部相同（含周日），即周日属于「它之前那个周一」所在的一周。

## 7. 记账与幂等

- 只有「真实执行签到」的运行才追加 CSV 行（成功 / 失败 / 守卫跳过）。
- 当天已签后的触发**不追加行**（方案A），只刷新 `last_run.txt`。
- 内置幂等自清理：删除 `执行结果 == "跳过（非整点）"` 的历史遗留行并重排序号（旧「整点门槛」策略的产物），删净后不再触发。

## 8. 已知坑

| 坑 | 现象 | 规避 |
|----|------|------|
| 内嵌 JS 不执行 | 预览面板里侧栏不对齐、按钮无反应（但 Edge 无头截图正常，易误判） | 一律纯静态 CSS |
| `Sort-Object` 返回标量 | 单元素集合排序返回字符串，`[0]` 取到首字符 → `Substring` 抛错甚至死循环 | 用 `[string[]]` 强类型 + 有界循环（上限 60） |
| PS 5.1 编码 | 中文 .ps1 无 BOM → 按 ANSI 读取乱码 | 保存为 UTF-8 **带 BOM** |
| PowerShell 工具 stdout 为空 | 工具直接调用时读不到输出 | 嵌套 `powershell.exe -ExecutionPolicy Bypass -File …` 并重定向到文件 |
| 无头浏览器用户目录 | 在工作区里建 `--user-data-dir` 会因 Windows 目录句柄锁**删不掉** | 截图一律用 `$env:TEMP` 下的临时目录；能用文本 grep 核实的就不截图 |
| 并行编辑同一文件 | 写入竞争导致改动丢失 | 串行 Edit + grep 复核 |
| 接口字段不可信 | `checkin-status` 的 `today_checked_in`、`total_credits` 等实测可能恒为 0/false | 幂等靠 `daily-checkin` 的 `code=10001`；积分数值只信 `daily-checkin` 响应的 `credit` |

## 9. 积分数值链路

```
decrypt-token.js                       (workbuddy-checkin skill)
  → checkin.ps1  POST /v2/billing/meter/daily-checkin
      响应 data.credit / data.streak_days        ← 唯一的积分真值来源
  → checkin_guard.ps1  判定成功并写日期标记，输出形如
      "签到成功！领取 OK credit=100 streak_days=3"
  → checkin_calendar.ps1  正则 credit=(\d+) / streak_days=(\d+) 抽值
  → CSV「积分/连签」列  "credit=100 streak=3"
  → 统计卡片按 credit 本地累加（本周 / 累计）
```

关键结论：**单次积分来自接口；汇总积分是本地累加**。脚本内不存在 100 / 1000 的硬编码常量。
若某天缺 `credit`（手动签到 / `code=10001`），该天不进汇总 → 用 `add_record.py` 补记。
