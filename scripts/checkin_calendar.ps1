# ============================================================
# WorkBuddy 签到日历 - 签到调度 + 统一记录表 + 日历渲染
# ------------------------------------------------------------
# 职责：
#   1. 判断「今天是否已签到成功」（守卫脚本日期标记 / 本地记录双判据）。
#   2. 已签到 -> 直接退出，不调接口、不追加记录行（方案A）。
#   3. 未签到 -> 调守卫脚本自动签到，解析其判定，写一条真实结果记录。
#   4. 维护同一张汇总表，并同步渲染三件套：
#        checkin-records.csv   结构化源数据
#        checkin-records.md    可读 Markdown（全量明细）
#        checkin-records.html  「WorkBuddy签到日历」页面（统计 + 日历 + 明细）
#
# 参数：
#   -OutDir <path>   记录输出目录（默认 <当前目录>\signin-records）
#   -RebuildOnly     只按现有 CSV 重建 MD/HTML，不签到、不追加行
#   -GuardPath <p>   指定守卫脚本路径（默认自动定位同级的 workbuddy-checkin skill）
#   -Title <t>       页面标题（默认「WorkBuddy签到日历」）
#
# 编码要求：本文件含中文，必须以 UTF-8 **带 BOM** 保存，否则 PS 5.1 会按 ANSI 读成乱码。
# ============================================================
param(
    [string]$OutDir = "",
    [switch]$RebuildOnly,
    [string]$GuardPath = "",
    [string]$Title = "WorkBuddy签到日历",
    [switch]$ShowPaths              # 只打印依赖解析结果，不签到、不写文件（排障用）
)

$ErrorActionPreference = "Continue"
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

# ---------- 输出目录 ----------
if (-not $OutDir -or $OutDir.Trim() -eq "") {
    $OutDir = Join-Path (Get-Location).Path "signin-records"
}
$RecDir   = $OutDir
$CsvFile  = Join-Path $RecDir "checkin-records.csv"
$MdFile   = Join-Path $RecDir "checkin-records.md"
$HtmlFile = Join-Path $RecDir "checkin-records.html"
$RunFile  = Join-Path $RecDir "last_run.txt"
$RawFile  = Join-Path $RecDir "last_guard_output.txt"

# ---------- 定位依赖（守卫脚本 / Node 运行时）----------
function Resolve-Guard([string]$explicit) {
    $cands = @()
    if ($explicit -and $explicit.Trim() -ne "") { $cands += $explicit }
    # $PSScriptRoot = ...\skills\workbuddy-checkin-calendar\scripts
    # 上溯两级 -> ...\skills，再拼同级 skill 的守卫脚本
    $skillRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if ($skillRoot) { $cands += (Join-Path $skillRoot "workbuddy-checkin\checkin_guard.ps1") }
    if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE ".workbuddy\skills\workbuddy-checkin\checkin_guard.ps1") }
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return ""
}

function Resolve-Node {
    if ($env:WB_CHECKIN_NODE -and (Test-Path $env:WB_CHECKIN_NODE)) { return $env:WB_CHECKIN_NODE }
    $hit = ""
    if ($env:USERPROFILE) {
        $base = Join-Path $env:USERPROFILE ".workbuddy\binaries\node\versions"
        if (Test-Path $base) {
            $found = @(Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                       Where-Object { Test-Path (Join-Path $_.FullName "node.exe") } |
                       Sort-Object Name -Descending)
            if ($found.Count -gt 0) { $hit = Join-Path $found[0].FullName "node.exe" }
        }
    }
    if (-not $hit) {
        try { $c = Get-Command node -ErrorAction SilentlyContinue; if ($c) { $hit = $c.Source } } catch {}
    }
    return $hit
}

function Resolve-PsExe {
    $p = Join-Path $PSHOME "powershell.exe"
    if (Test-Path $p) { return $p }
    return (Get-Process -Id $PID).Path
}

$Guard = Resolve-Guard $GuardPath
$NodeExe = Resolve-Node

# ---------- 排障：只打印依赖解析结果 ----------
if ($ShowPaths) {
    Write-Output ("OUTDIR=" + $RecDir)
    if ($Guard)   { Write-Output ("GUARD=" + $Guard) }   else { Write-Output "GUARD=(未找到，请安装 workbuddy-checkin skill 或用 -GuardPath 指定)" }
    if ($NodeExe) { Write-Output ("NODE="  + $NodeExe) } else { Write-Output "NODE=(未找到)" }
    exit 0
}

New-Item -ItemType Directory -Force -Path $RecDir | Out-Null

# ---------- 会话常量 ----------
$Chk   = [char]::ConvertFromUtf32(0x2705)   # U+2705 绿色对号
$Xmk   = [char]::ConvertFromUtf32(0x274C)   # U+274C 红色叉号
$Gray  = "#9aa0a6"

function Esc([string]$s) {
    if ($null -eq $s) { return "" }
    return ($s -replace "&", "&amp;" -replace "<", "&lt;" -replace ">", "&gt;")
}

# ---------- 读取现有记录 ----------
$rows = @()
if (Test-Path $CsvFile) {
    try { $rows = @(Import-Csv -Path $CsvFile -Encoding UTF8) } catch { $rows = @() }
}

# ---------- 自清理：删除旧「整点门槛」策略遗留的「跳过（非整点）」行 ----------
# 只删「执行结果 == 跳过（非整点）」这一类；保留其余全部记录。幂等，删净后不再触发。
$beforePrune = $rows.Count
$rows = @($rows | Where-Object { ([string]$_."执行结果") -ne "跳过（非整点）" })
if ($rows.Count -ne $beforePrune) {
    for ($pi = 0; $pi -lt $rows.Count; $pi++) { try { $rows[$pi]."序号" = [string]($pi + 1) } catch {} }
    $rows | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8
}

$stamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$summary = ""
$raw     = ""
$seq     = 0
$hint    = ""

if (-not $RebuildOnly) {
    $now      = Get-Date
    $hour     = $now.Hour
    $todayStr = $now.ToString("yyyy-MM-dd")

    $result = ""; $conclusion = ""; $tokenState = ""; $guardVerdict = ""; $credit = "-"; $note = ""

    # ============================================================
    # 预检（方案A）：今天是否已签到成功？
    #   已签到 -> 不调接口、不追加 CSV 行，仅刷新 last_run.txt。
    #   判据①：守卫日期标记文件内容 == 今天；判据②：本地记录里今天已有成功/已签行。
    #   失败日不写标记 -> 仍会继续重试，符合「没签成就一直补」。
    # ============================================================
    $alreadySigned = $false
    if ($Guard) {
        $MarkerFile = Join-Path (Split-Path -Parent $Guard) "last_success.txt"
        if (Test-Path $MarkerFile) {
            try {
                $mk = Get-Content $MarkerFile -Raw -ErrorAction SilentlyContinue
                if ($null -ne $mk -and $mk.Trim() -eq $todayStr) { $alreadySigned = $true }
            } catch {}
        }
    }
    if (-not $alreadySigned) {
        foreach ($r0 in $rows) {
            $ts0 = [string]$r0."执行时间"
            if ($ts0.StartsWith($todayStr)) {
                $res0 = [string]$r0."执行结果"
                if ($res0 -match "签到成功" -or $res0 -match "今日已签到") { $alreadySigned = $true; break }
            }
        }
    }

    if ($alreadySigned) {
        $hint = "今日已完成（无需操作）"
        $summary = "time=" + $stamp + " | hour=" + $hour + " | target=True | result=今日已完成（当日已签，自动跳过，不记账） | token=未使用（今日已签跳过） | guard=SKIP（今日已签到，未调用接口） | credit=- | hint=" + $hint
        [System.IO.File]::WriteAllText($RunFile, $summary + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    }
    else {
        # 今日未签到 -> 调守卫自动补签
        if (-not $Guard) {
            $raw = "RUNNER_ERR: 未找到守卫脚本 checkin_guard.ps1，请先安装 workbuddy-checkin skill 或用 -GuardPath 指定"
        } else {
            if ($NodeExe) { $env:WB_CHECKIN_NODE = $NodeExe }
            $psExe = Resolve-PsExe
            try {
                $raw = (& $psExe -ExecutionPolicy Bypass -File $Guard 2>&1 | Out-String)
            } catch {
                $raw = "RUNNER_ERR: " + $_.Exception.Message
            }
        }
        $raw = ($raw + "").Trim()

        # ---- 守卫脚本判定 ----
        if     ($raw -match "today already signed") { $guardVerdict = "SKIP（今日已签到，未调用接口）" }
        elseif ($raw -match "marker written")       { $guardVerdict = "RUN - marker written（当日完成，后续跳过）" }
        elseif ($raw -match "marker NOT written")   { $guardVerdict = "RUN - 未成功，marker 未写入（后续重试）" }
        else                                        { $guardVerdict = "未识别" }

        # ---- 积分 / 连签（数值一律来自接口响应）----
        $mc = [regex]::Match($raw, "credit=(\d+)")
        $ms = [regex]::Match($raw, "streak_days=(\d+)")
        if ($mc.Success -or $ms.Success) {
            $cv = "-"; $sv = "-"
            if ($mc.Success) { $cv = $mc.Groups[1].Value }
            if ($ms.Success) { $sv = $ms.Groups[1].Value }
            $credit = "credit=" + $cv + " streak=" + $sv
        }

        # ---- 令牌状态 ----
        if     ($raw -match "令牌已过期")            { $tokenState = "失效（需刷新登录态）" }
        elseif ($raw -match "获取令牌失败")          { $tokenState = "不可用（未取到令牌）" }
        elseif ($raw -match "today already signed")  { $tokenState = "未使用（今日已签跳过）" }
        elseif ($raw -match "签到成功")              { $tokenState = "有效" }
        elseif ($raw -match "今日已签到")            { $tokenState = "有效" }
        else                                         { $tokenState = "未知" }

        # ---- 执行结果 / 结论 ----
        if     ($raw -match "today already signed")  { $result = "今日已签到（守卫跳过）"; $conclusion = "守卫判定当日已完成，未调用接口" }
        elseif ($raw -match "签到成功")              { $result = "签到成功";               $conclusion = "本次成功领取积分" }
        elseif ($raw -match "今日已签到")            { $result = "今日已签到";             $conclusion = "当日已完成，未重复领取" }
        elseif ($raw -match "令牌已过期")            { $result = "失败";                   $conclusion = "令牌失效，需打开 WorkBuddy 桌面端刷新登录态" }
        else                                         { $result = "失败";                   $conclusion = "签到未成功，后续运行将重试" }

        $note = "任意时刻自动签到（未限定整点）"

        # ---------- 追加到统一汇总表 (CSV) ----------
        $seq = $rows.Count + 1
        $newRow = [pscustomobject][ordered]@{
            "序号"       = [string]$seq
            "执行时间"   = $stamp
            "执行结果"   = $result
            "执行结论"   = $conclusion
            "令牌状态"   = $tokenState
            "守卫脚本判定" = $guardVerdict
            "积分/连签"  = $credit
            "备注"       = $note
        }
        $rows = @($rows) + @($newRow)
        $rows | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8

        # ---- 兜底提醒判定 ----
        $signedNow = ($result -match "签到成功") -or ($result -match "今日已签到")
        if ($signedNow) {
            $hint = "今日已完成（无需操作）"
        } elseif ($tokenState -match "失效") {
            $hint = "令牌失效：请打开 WorkBuddy 桌面端刷新登录态，后续运行会自动重试"
        } else {
            $hint = "今日未签到成功（本次尝试失败，后续运行将自动重试）"
        }
        if ((-not $signedNow) -and ($hour -ge 21)) {
            $hint = "夜间预警：今日（" + $todayStr + "）仍未签到成功，请打开 WorkBuddy 桌面端检查登录态与网络，避免断签"
        }

        $summary = "time=" + $stamp + " | hour=" + $hour + " | target=True | result=" + $result + " | token=" + $tokenState + " | guard=" + $guardVerdict + " | credit=" + $credit + " | hint=" + $hint
        [System.IO.File]::WriteAllText($RunFile, $summary + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        try { [System.IO.File]::WriteAllText($RawFile, $raw, (New-Object System.Text.UTF8Encoding($true))) } catch {}
    }
}

# ---------- 按结果统计 ----------
$nTotal = 0; $nOk = 0; $nBad = 0; $nSkip = 0; $sumCredit = 0
foreach ($r0 in $rows) {
    $nTotal++
    $res0 = [string]$r0."执行结果"
    if     ($res0 -match "签到成功") { $nOk++ }
    elseif ($res0 -match "失败")     { $nBad++ }
    else                             { $nSkip++ }
    $m0 = [regex]::Match([string]$r0."积分/连签", "credit=(\d+)")
    if ($m0.Success) { $sumCredit += [int]$m0.Groups[1].Value }
}
$lastStamp = ""
$lastResult = ""
if ($nTotal -gt 0) { $lastStamp = [string]$rows[$nTotal - 1]."执行时间"; $lastResult = [string]$rows[$nTotal - 1]."执行结果" }

# ---------- 本周统计 ----------
# 一周定义：周一 = 第 1 天 … 周日 = 第 7 天；周日归属它之前那个周一所在的一周。每周归零。
# 执行时间格式固定为 "yyyy-MM-dd HH:mm:ss"（定宽），字典序 == 时间序，故直接字符串比较。
$nowD  = Get-Date
$dowN  = [int]$nowD.DayOfWeek            # .NET: Sunday=0, Monday=1 ... Saturday=6
$backN = $dowN - 1
if ($dowN -eq 0) { $backN = 6 }          # 周日（第7天）回退 6 天到本周一（第1天）
$weekStartDate = $nowD.Date.AddDays(-$backN)          # 本周一（第 1 天）
$weekEndDate   = $weekStartDate.AddDays(6)            # 本周日（第 7 天）
$weekStartStr  = $weekStartDate.ToString("yyyy-MM-dd HH:mm:ss")
$weekRangeStr  = $weekStartDate.ToString("yyyy-MM-dd") + "（周一 · 第1天）~ " + $weekEndDate.ToString("yyyy-MM-dd") + "（周日 · 第7天）"

$nWeekOk       = 0                       # 本周签到成功次数（0..7）
$sumWeekCredit = 0                       # 本周已领取积分（累加，从 0 开始）
foreach ($r0 in $rows) {
    $ts0 = [string]$r0."执行时间"
    if ($ts0.Length -lt 19) { continue }
    if ($ts0 -lt $weekStartStr) { continue }
    if ([string]$r0."执行结果" -match "签到成功") { $nWeekOk++ }
    $mw = [regex]::Match([string]$r0."积分/连签", "credit=(\d+)")
    if ($mw.Success) { $sumWeekCredit += [int]$mw.Groups[1].Value }
}
if ($nWeekOk -gt 7) { $nWeekOk = 7 }     # 一周最多 7 天，上限封顶

# ---------- 最近一次「签到成功」 ----------
# 取最后一条【真实签到成功】记录（不含「今日已签到（守卫跳过）」等跳过行）。
$lastOkStamp  = ""
$lastOkCredit = ""
for ($i = $rows.Count - 1; $i -ge 0; $i--) {
    if ([string]$rows[$i]."执行结果" -match "签到成功") {
        $lastOkStamp = [string]$rows[$i]."执行时间"
        $ml = [regex]::Match([string]$rows[$i]."积分/连签", "credit=(\d+)")
        if ($ml.Success) { $lastOkCredit = $ml.Groups[1].Value }
        break
    }
}
if ($lastOkStamp  -eq "") { $lastOkStamp  = "—" }
if ($lastOkCredit -eq "") { $lastOkCredit = "—" }

# ---------- 签到日历数据聚合 ----------
$curYm     = (Get-Date).ToString("yyyy-MM")
$todayDate = (Get-Date).ToString("yyyy-MM-dd")
$dayStatus = @{}                       # 日期(yyyy-MM-dd) -> "ok" / "bad"
$ymSet     = New-Object System.Collections.Generic.HashSet[string]
$firstRecDate = ""                     # 首条记录日期 = 「任务开始前」的判定基准
foreach ($r0 in $rows) {
    $ts0 = [string]$r0."执行时间"
    if ($ts0.Length -ge 7) { [void]$ymSet.Add($ts0.Substring(0, 7)) }
    if ($ts0.Length -ge 10) {
        $d0   = $ts0.Substring(0, 10)
        if ($firstRecDate -eq "" -or $d0 -lt $firstRecDate) { $firstRecDate = $d0 }
        $res0 = [string]$r0."执行结果"
        if ($res0 -match "签到成功") {
            $dayStatus[$d0] = "ok"
        } elseif ($res0 -match "失败") {
            if (-not ($dayStatus.ContainsKey($d0) -and $dayStatus[$d0] -eq "ok")) { $dayStatus[$d0] = "bad" }
        }
    }
}
[string[]]$recMonths = @(@($ymSet) | Sort-Object)
# 可浏览范围：滑动窗口「当前月 ±12 个月」，恒为 25 个月。
# 好处：HTML 体积恒定；代价：更早的历史月份不可翻（数据仍在 CSV / 明细中完整保留）。
$calStart = (Get-Date).AddMonths(-12)
$calEnd   = (Get-Date).AddMonths(12)
$calMonths = New-Object System.Collections.ArrayList
for ($k = 0; $k -lt 60; $k++) {          # 有界循环，防死循环
    $mm = $calStart.AddMonths($k)
    if ($mm -gt $calEnd) { break }
    [void]$calMonths.Add($mm.ToString("yyyy-MM"))
}
$curIdx = [array]::IndexOf($calMonths, $curYm)
if ($curIdx -lt 0) { $curIdx = 0 }

# 本月签到天数统计（用于 MD 文字版）
$cmOk = 0; $cmBad = 0; $cmNone = 0; $cmPre = 0
$cY = (Get-Date).Year; $cM = (Get-Date).Month
$cDims = [DateTime]::DaysInMonth($cY, $cM)
for ($d = 1; $d -le $cDims; $d++) {
    $ds = ("{0:D4}-{1:D2}-{2:D2}" -f $cY, $cM, $d)
    if ($ds -gt $todayDate) { continue }
    if     (($firstRecDate -ne "") -and ($ds -lt $firstRecDate))        { $cmPre++ }
    elseif ($dayStatus.ContainsKey($ds) -and $dayStatus[$ds] -eq "ok")  { $cmOk++ }
    elseif ($dayStatus.ContainsKey($ds) -and $dayStatus[$ds] -eq "bad") { $cmBad++ }
    else                                                                { $cmNone++ }
}

# ---------- 阴历（农历）转换：1900-2100 离线查表，无外部依赖 ----------
$LMonNames = @("正月","二月","三月","四月","五月","六月","七月","八月","九月","十月","冬月","腊月")
$LDays = @("初一","初二","初三","初四","初五","初六","初七","初八","初九","初十",
           "十一","十二","十三","十四","十五","十六","十七","十八","十九","二十",
           "廿一","廿二","廿三","廿四","廿五","廿六","廿七","廿八","廿九","三十")
$lunarInfo = @(
0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
0x06ca0,0x0b550,0x15355,0x04da0,0x0a5b0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,
0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,
0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x055c0,0x0ab60,0x096d5,0x092e0,
0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06b20,0x1a6c4,0x0aae0,
0x0a2e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,
0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,
0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,
0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252,
0x0d520
)
function LeapMonth([int]$y) { return ($lunarInfo[$y - 1900] -band 0xf) }
function LeapDays([int]$y) {
    if ((LeapMonth $y) -ne 0) {
        if (($lunarInfo[$y - 1900] -band 0x10000) -ne 0) { return 30 } else { return 29 }
    }
    return 0
}
function LYearDays([int]$y) {
    $sum = 348
    $bit = 0x8000
    while ($bit -gt 0x8) {
        if (($lunarInfo[$y - 1900] -band $bit) -ne 0) { $sum += 1 }
        $bit = $bit -shr 1
    }
    return $sum + (LeapDays $y)
}
function MonthDays([int]$y, [int]$m) {
    if (($lunarInfo[$y - 1900] -band (0x10000 -shr $m)) -ne 0) { return 30 } else { return 29 }
}
function SolarToLunar([int]$sy, [int]$sm, [int]$sd) {
    $offset = [int](([DateTime]::new($sy, $sm, $sd) - [DateTime]::new(1900, 1, 31)).TotalDays)
    $temp = 0
    for ($i = 1900; $i -lt 2101 -and $offset -gt 0; $i++) { $temp = LYearDays $i; $offset -= $temp }
    if ($offset -lt 0) { $offset += $temp; $i-- }
    $lyear  = $i
    $leap   = LeapMonth $lyear
    $isLeap = $false
    for ($j = 1; $j -lt 13 -and $offset -gt 0; $j++) {
        if ($leap -gt 0 -and $j -eq ($leap + 1) -and -not $isLeap) {
            $j--; $isLeap = $true; $temp = LeapDays $lyear
        } else {
            $temp = MonthDays $lyear $j
        }
        if ($isLeap -and $j -eq ($leap + 1)) { $isLeap = $false }
        $offset -= $temp
    }
    if ($offset -eq 0 -and $leap -gt 0 -and $j -eq ($leap + 1)) {
        if ($isLeap) { $isLeap = $false } else { $isLeap = $true; $j-- }
    }
    if ($offset -lt 0) { $offset += $temp; $j-- }
    return @{ y = $lyear; m = $j; d = ($offset + 1); leap = $isLeap }
}
function LunarDayLabel([int]$y, [int]$m, [int]$d) {
    $l = SolarToLunar $y $m $d
    if ($l.d -eq 1) {
        $nm = $LMonNames[$l.m - 1]
        if ($l.leap) { return ("闰" + $nm) }
        return $nm
    }
    return $LDays[$l.d - 1]
}

# 渲染单个自然月日历网格（周一为一周起点）
function RenderMonthGrid([string]$ym, [int]$idx, [hashtable]$st, [string]$today, [string]$startDate) {
    $y = [int]$ym.Substring(0, 4); $m = [int]$ym.Substring(5, 2)
    $dims   = [DateTime]::DaysInMonth($y, $m)
    $offset = (([int]([DateTime]::new($y, $m, 1)).DayOfWeek) + 6) % 7   # 周一为一周起点
    $cells = @()
    for ($i = 0; $i -lt $offset; $i++) { $cells += '<td class="c-blank"></td>' }
    for ($d = 1; $d -le $dims; $d++) {
        $ds  = ("{0:D4}-{1:D2}-{2:D2}" -f $y, $m, $d)
        $cls = "day c-future"; $mk = ""
        $isPre = (($startDate -ne "") -and ($ds -lt $startDate))
        if ($isPre) {
            # 「任务开始前」：早于首条记录日期 -> 当时签到任务尚未建立，浅灰显示，不计入「未签到」
            $cls = "day c-pre"
        }
        elseif ($ds -le $today) {
            $v = ""
            if ($st.ContainsKey($ds)) { $v = $st[$ds] }
            if     ($v -eq "ok")  { $cls = "day c-ok";   $mk = $Chk }
            elseif ($v -eq "bad") { $cls = "day c-bad";  $mk = $Xmk }
            else                  { $cls = "day c-none"; $mk = "" }
        }
        if ($ds -eq $today) { $cls = $cls + " today" }
        $lun = LunarDayLabel $y $m $d
        $cells += '<td class="' + $cls + '"><span class="mk">' + $mk + '</span><span class="dn">' + $d + '</span><span class="lun">' + $lun + '</span></td>'
    }
    while ($cells.Count % 7 -ne 0) { $cells += '<td class="c-blank"></td>' }

    $g = New-Object System.Text.StringBuilder
    [void]$g.AppendLine('<div class="calmonth m-' + $idx + '" data-ym="' + $ym + '">')
    [void]$g.AppendLine('<table class="cal">')
    [void]$g.AppendLine('<thead><tr><th>一</th><th>二</th><th>三</th><th>四</th><th>五</th><th>六</th><th>日</th></tr></thead>')
    [void]$g.AppendLine('<tbody>')
    for ($i = 0; $i -lt $cells.Count; $i += 7) {
        [void]$g.AppendLine('<tr>' + (($cells[$i..($i + 6)]) -join '') + '</tr>')
    }
    [void]$g.AppendLine('</tbody></table>')
    [void]$g.AppendLine('</div>')
    return $g.ToString()
}

# 纯静态切换（不依赖 JS）：隐藏单选按钮 cm-N 控制「显示哪个月」，上下月按钮为 label
$MName = @("一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月")
$calMonthsHtml = ""
$calNavHtml    = ""
$calRadioHtml  = ""
$calMonthCss   = New-Object System.Text.StringBuilder
for ($ci = 0; $ci -lt $calMonths.Count; $ci++) {
    $ymk = [string]$calMonths[$ci]
    $calMonthsHtml += (RenderMonthGrid $ymk $ci $dayStatus $todayDate $firstRecDate)

    $ck = ""
    if ($ci -eq $curIdx) { $ck = " checked" }
    $calRadioHtml += '<input type="radio" name="calm" id="cm-' + $ci + '" class="cmr"' + $ck + '>'

    $prevHtml = '<span class="navbtn disabled">&#8249; 上一月</span>'
    if ($ci -gt 0) { $prevHtml = '<label class="navbtn" for="cm-' + ($ci - 1) + '">&#8249; 上一月</label>' }
    $nextHtml = '<span class="navbtn disabled">下一月 &#8250;</span>'
    if ($ci -lt ($calMonths.Count - 1)) { $nextHtml = '<label class="navbtn" for="cm-' + ($ci + 1) + '">下一月 &#8250;</label>' }

    $mno = [int]$ymk.Substring(5, 2)
    # 侧栏纵向顺序：月份标题 -> 上一月 -> 下一月
    $calNavHtml += '<div class="navpair p-' + $ci + '">' +
                   '<div class="mtitle">' + $MName[$mno - 1] + '</div>' + $prevHtml + $nextHtml + '</div>'

    [void]$calMonthCss.AppendLine('  #cm-' + $ci + ':checked ~ .calmain .m-' + $ci + ' { display:block; }')
    [void]$calMonthCss.AppendLine('  #cm-' + $ci + ':checked ~ .calside .p-' + $ci + ' { display:flex; }')
}

# ---------- 渲染：Markdown + 彩色 HTML ----------
# 分类：成功(含"签到成功") -> 绿对号；失败(含"失败") -> 红叉号；其余(跳过/已签到) -> 整行灰色
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# " + $Title)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## 一 签到统计")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| 指标 | 数量 |")
[void]$sb.AppendLine("| --- | --- |")
[void]$sb.AppendLine("| 总计执行 | " + $nTotal + " 次 |")
[void]$sb.AppendLine("| " + $Chk + " 本周签到成功 | " + $nWeekOk + " 次 |")
[void]$sb.AppendLine("| " + $Xmk + " 签到失败 | " + $nBad + " 次 |")
[void]$sb.AppendLine("| 本周已领取积分 | " + $sumWeekCredit + " |")
[void]$sb.AppendLine("| 累计已领取积分 | " + $sumCredit + " |")
[void]$sb.AppendLine("| 最近一次签到成功 | " + $lastOkStamp + "； 领取积分：" + $lastOkCredit + " |")
[void]$sb.AppendLine("| 本周范围（周一=第1天，周日=第7天） | " + $weekRangeStr + " |")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**二 签到日历（" + (Get-Date).ToString("yyyy年M月") + "）**：已签 " + $cmOk + " 天 · 失败 " + $cmBad + " 天 · 未签 " + $cmNone + " 天 · 任务开始前 " + $cmPre + " 天（未来日不计；勾选式视觉日历见 HTML 版）")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## 三 签到明细")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| 序号 | 执行时间 | 执行结果 | 执行结论 | 令牌状态 | 守卫脚本判定 | 积分/连签 | 备注 |")
[void]$sb.AppendLine("| --- | --- | --- | --- | --- | --- | --- | --- |")

$sh = New-Object System.Text.StringBuilder
[void]$sh.AppendLine('<!DOCTYPE html>')
[void]$sh.AppendLine('<html lang="zh-CN">')
[void]$sh.AppendLine('<head>')
[void]$sh.AppendLine('<meta charset="utf-8">')
[void]$sh.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
[void]$sh.AppendLine('<title>' + (Esc $Title) + '</title>')
[void]$sh.AppendLine('<style>')
[void]$sh.AppendLine('  body { font-family: "Microsoft YaHei","PingFang SC","Segoe UI",Arial,sans-serif; background:#ffffff; color:#202124; margin:22px; }')
[void]$sh.AppendLine('  h1 { font-size:20px; margin:0 0 6px 0; }')
[void]$sh.AppendLine('  table { border-collapse:collapse; width:100%; }')
[void]$sh.AppendLine('  th,td { border:1px solid #dadce0; padding:7px 10px; font-size:13px; text-align:left; vertical-align:top; }')
[void]$sh.AppendLine('  th { background:#f1f3f4; font-weight:600; white-space:nowrap; }')
[void]$sh.AppendLine('  td.num { text-align:center; }')
[void]$sh.AppendLine('  .ok { color:#1e8e3e; font-weight:700; }')
[void]$sh.AppendLine('  .bad { color:#d93025; font-weight:700; }')
[void]$sh.AppendLine('  tr.skip td { color:#9aa0a6; }')
[void]$sh.AppendLine('  .gen { color:#9aa0a6; font-size:12px; margin-top:12px; }')
[void]$sh.AppendLine('  .trunc { color:#8a8f94; font-size:12px; margin:0 0 6px 2px; }')
[void]$sh.AppendLine('  h2 { font-size:15px; margin:18px 0 10px 0; padding:8px 14px; border-radius:8px; font-weight:600; border-left:4px solid #1a73e8; background:linear-gradient(90deg,#e8f0fe 0%,#f4f8ff 55%,#ffffff 100%); color:#174ea6; }')
[void]$sh.AppendLine('  h2.h-stat { border-left-color:#1a73e8; background:linear-gradient(90deg,#e8f0fe 0%,#f4f8ff 55%,#ffffff 100%); color:#174ea6; }')
[void]$sh.AppendLine('  h2.h-cal  { border-left-color:#1e8e3e; background:linear-gradient(90deg,#e6f4ea 0%,#f3faf5 55%,#ffffff 100%); color:#137333; }')
[void]$sh.AppendLine('  h2.h-det  { border-left-color:#c8922b; background:linear-gradient(90deg,#fdf3e0 0%,#fefaf1 55%,#ffffff 100%); color:#8a6415; }')
[void]$sh.AppendLine('  .summary { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:4px; }')
[void]$sh.AppendLine('  .card { border:1px solid #dadce0; border-radius:6px; padding:6px 10px; font-size:13px; background:#fafafa; }')
[void]$sh.AppendLine('  .card b { font-size:15px; }')
[void]$sh.AppendLine('  .ok-card { color:#1e8e3e; border-color:#c6e6cd; background:#eef8f0; }')
[void]$sh.AppendLine('  .bad-card { color:#d93025; border-color:#f3c9c4; background:#fdeeec; }')
[void]$sh.AppendLine('  .skip-card { color:#5f6368; border-color:#e0e0e0; background:#f5f5f5; }')
[void]$sh.AppendLine('  .week-card { color:#b07f22; border-color:#f0dfb8; background:#fdf6e7; }')
[void]$sh.AppendLine('  /* ---- 签到日历 ---- */')
[void]$sh.AppendLine('  .calwrap { position:relative; display:flex; align-items:flex-start; gap:18px; flex-wrap:wrap; margin:6px 0 8px 0; }')
[void]$sh.AppendLine('  .calmain { flex:0 0 auto; }')
[void]$sh.AppendLine('  .cmr { position:absolute; width:0; height:0; opacity:0; pointer-events:none; }')
[void]$sh.AppendLine('  .calmonth { display:none; }')
[void]$sh.AppendLine('  .calside { flex:0 0 auto; width:103px; margin-top:30px; display:flex; flex-direction:column; gap:10px; padding:12px 10px; border:1px solid #e8eaed; border-radius:10px; background:#fafbfc; }')
[void]$sh.AppendLine('  .navpair { display:none; flex-direction:column; gap:8px; margin-bottom:12px; }')
[void]$sh.AppendLine('  .navbtn { display:block; text-align:center; font-size:12px; padding:6px 4px; border:1px solid #dadce0; background:#fff; border-radius:6px; color:#202124; cursor:pointer; -webkit-user-select:none; user-select:none; white-space:nowrap; }')
[void]$sh.AppendLine('  .navbtn:hover { background:#f1f3f4; }')
[void]$sh.AppendLine('  .navbtn.disabled { color:#bdc1c6; cursor:default; }')
[void]$sh.AppendLine('  .navbtn.disabled:hover { background:#fff; }')
[void]$sh.AppendLine('  .mtitle { text-align:center; font-size:17px; font-weight:700; color:#1a73e8; padding:1px 0 2px 0; letter-spacing:1px; }')
[void]$sh.AppendLine('  .callegend { display:flex; flex-direction:column; gap:8px; border-top:1px solid #eceff1; padding-top:10px; }')
[void]$sh.AppendLine('  .callegend .lgrow { display:flex; align-items:center; gap:8px; font-size:12px; color:#5f6368; white-space:nowrap; }')
[void]$sh.AppendLine('  .callegend .sw { width:28px; height:20px; border-radius:5px; border:1px solid #e8eaed; display:inline-flex; align-items:center; justify-content:center; font-size:10px; line-height:1; flex:0 0 auto; }')
[void]$sh.AppendLine('  .callegend .sw.c-ok { background:#eef8f0; border-color:#c6e6cd; color:#1e8e3e; }')
[void]$sh.AppendLine('  .callegend .sw.c-bad { background:#fdeeec; border-color:#f3c9c4; color:#d93025; }')
[void]$sh.AppendLine('  .callegend .sw.c-none { background:#fdf6e7; border-color:#f0dfb8; }')
[void]$sh.AppendLine('  .callegend .sw.c-future { background:#ffffff; border-color:#e8eaed; }')
[void]$sh.AppendLine('  .callegend .sw.c-pre { background:#f5f6f7; border-color:#ecf0f1; }')
[void]$sh.AppendLine('  table.cal { border-collapse:separate; border-spacing:6px; width:auto; margin:0 0 0 -6px; }')
[void]$sh.AppendLine('  table.cal th { background:transparent; border:none; color:#5f6368; font-weight:600; font-size:12px; text-align:center; padding:0; height:18px; line-height:18px; white-space:normal; }')
[void]$sh.AppendLine('  table.cal td.day { width:68px; height:64px; border:1px solid #e8eaed; border-radius:9px; text-align:center; vertical-align:middle; padding:3px 2px; position:relative; }')
[void]$sh.AppendLine('  table.cal td .dn { display:block; font-size:18px; font-weight:600; line-height:1.05; color:#202124; }')
[void]$sh.AppendLine('  table.cal td .lun { display:block; font-size:11px; line-height:1.2; margin-top:2px; color:#9aa0a6; }')
[void]$sh.AppendLine('  table.cal td .mk { position:absolute; top:3px; right:5px; font-size:12px; line-height:1; }')
[void]$sh.AppendLine('  table.cal td.c-ok { background:#eef8f0; border-color:#c6e6cd; }')
[void]$sh.AppendLine('  table.cal td.c-ok .dn { color:#1e8e3e; }')
[void]$sh.AppendLine('  table.cal td.c-ok .lun { color:#7fb98d; }')
[void]$sh.AppendLine('  table.cal td.c-bad { background:#fdeeec; border-color:#f3c9c4; }')
[void]$sh.AppendLine('  table.cal td.c-bad .dn { color:#d93025; }')
[void]$sh.AppendLine('  table.cal td.c-bad .lun { color:#e39a92; }')
[void]$sh.AppendLine('  table.cal td.c-none { background:#fdf6e7; border-color:#f0dfb8; }')
[void]$sh.AppendLine('  table.cal td.c-none .dn { color:#c8922b; }')
[void]$sh.AppendLine('  table.cal td.c-none .lun { color:#cbb078; }')
[void]$sh.AppendLine('  table.cal td.c-future .dn { color:#bdc1c6; }')
[void]$sh.AppendLine('  table.cal td.c-future .lun { color:#dadce0; }')
[void]$sh.AppendLine('  table.cal td.c-pre { background:#f5f6f7; border-color:#ecf0f1; }')
[void]$sh.AppendLine('  table.cal td.c-pre .dn { color:#c4c8cc; }')
[void]$sh.AppendLine('  table.cal td.c-pre .lun { color:#dcdfe2; }')
[void]$sh.AppendLine('  table.cal td.c-blank { border:none; background:transparent; padding:0; }')
[void]$sh.AppendLine('  table.cal td.today { box-shadow:0 0 0 2px #1a73e8 inset; border-color:#1a73e8; }')
[void]$sh.Append($calMonthCss.ToString())
[void]$sh.AppendLine('</style>')
[void]$sh.AppendLine('</head>')
[void]$sh.AppendLine('<body>')
[void]$sh.AppendLine('<h1>' + (Esc $Title) + '</h1>')
[void]$sh.AppendLine('<h2 class="h-stat">一 签到统计</h2>')
[void]$sh.AppendLine('<div class="trunc">本周范围（周一 = 第 1 天，周日 = 第 7 天）：' + $weekRangeStr + '</div>')
[void]$sh.AppendLine('<div class="summary">')
[void]$sh.AppendLine('  <span class="card">总计执行 <b>' + $nTotal + '</b> 次</span>')
[void]$sh.AppendLine('  <span class="card ok-card">' + $Chk + ' 本周签到成功 <b>' + $nWeekOk + '</b> 次</span>')
[void]$sh.AppendLine('  <span class="card bad-card">' + $Xmk + ' 签到失败 <b>' + $nBad + '</b> 次</span>')
[void]$sh.AppendLine('  <span class="card week-card">本周已领取积分 <b>' + $sumWeekCredit + '</b></span>')
[void]$sh.AppendLine('  <span class="card">累计已领取积分 <b>' + $sumCredit + '</b></span>')
[void]$sh.AppendLine('  <span class="card">最近一次签到成功：' + (Esc $lastOkStamp) + '； 领取积分：' + (Esc $lastOkCredit) + '</span>')
[void]$sh.AppendLine('</div>')
[void]$sh.AppendLine('<h2 class="h-cal">二 签到日历</h2>')
[void]$sh.AppendLine('<div class="calwrap">')
[void]$sh.AppendLine($calRadioHtml)
[void]$sh.AppendLine('<div class="calmain">')
[void]$sh.AppendLine($calMonthsHtml)
[void]$sh.AppendLine('</div>')
[void]$sh.AppendLine('<aside class="calside">')
[void]$sh.AppendLine($calNavHtml)
[void]$sh.AppendLine('  <div class="callegend">')
[void]$sh.AppendLine('    <div class="lgrow"><span class="sw c-ok">' + $Chk + '</span>已签到</div>')
[void]$sh.AppendLine('    <div class="lgrow"><span class="sw c-bad">' + $Xmk + '</span>失败</div>')
[void]$sh.AppendLine('    <div class="lgrow"><span class="sw c-none"></span>未签到</div>')
[void]$sh.AppendLine('    <div class="lgrow"><span class="sw c-pre"></span>任务开始前</div>')
[void]$sh.AppendLine('    <div class="lgrow"><span class="sw c-future"></span>未来日</div>')
[void]$sh.AppendLine('  </div>')
[void]$sh.AppendLine('</aside>')
[void]$sh.AppendLine('</div>')
[void]$sh.AppendLine('<h2 class="h-det">三 签到明细</h2>')
# HTML 版瘦身：明细表只显示最近 60 条，CSV / MD 仍保留全部历史。
$htmlMax  = 60
$htmlFrom = 0
if ($nTotal -gt $htmlMax) {
    $htmlFrom = $nTotal - $htmlMax
    [void]$sh.AppendLine('<div class="trunc">仅显示最近 ' + $htmlMax + ' 条（共 ' + $nTotal + ' 条；完整历史见 checkin-records.csv / checkin-records.md）</div>')
}
[void]$sh.AppendLine('<table>')
[void]$sh.AppendLine('<thead><tr><th>序号</th><th>执行时间</th><th>执行结果</th><th>执行结论</th><th>令牌状态</th><th>守卫脚本判定</th><th>积分/连签</th><th>备注</th></tr></thead>')
[void]$sh.AppendLine('<tbody>')

$ri = -1
foreach ($r in $rows) {
    $ri++
    $res  = [string]$r."执行结果"
    $ok   = ($res -match "签到成功")
    $bad  = ($res -match "失败")
    $skip = (-not $ok) -and (-not $bad)

    $resText = $res
    $resHtml = Esc $res
    if ($ok) {
        $resText = $Chk + " " + $res
        $resHtml = '<span class="ok">' + $Chk + '</span> ' + (Esc $res)
    }
    elseif ($bad) {
        $resText = $Xmk + " " + $res
        $resHtml = '<span class="bad">' + $Xmk + '</span> ' + (Esc $res)
    }

    # --- Markdown 行 ---
    if ($skip) {
        $vals = @($r."序号", $r."执行时间", $resText, $r."执行结论", $r."令牌状态", $r."守卫脚本判定", $r."积分/连签", $r."备注")
        $spans = @()
        foreach ($v in $vals) { $spans += ('<span style="color:' + $Gray + '">' + (Esc ([string]$v)) + '</span>') }
        [void]$sb.AppendLine("| " + ($spans -join " | ") + " |")
    }
    else {
        [void]$sb.AppendLine("| " + $r."序号" + " | " + $r."执行时间" + " | " + $resText + " | " + $r."执行结论" + " | " + $r."令牌状态" + " | " + $r."守卫脚本判定" + " | " + $r."积分/连签" + " | " + $r."备注" + " |")
    }

    # --- HTML 行（只渲染最近 $htmlMax 条；MD 行已在上面全部写完）---
    if ($ri -lt $htmlFrom) { continue }
    $trClass = ""
    if ($skip) { $trClass = ' class="skip"' }
    [void]$sh.AppendLine('<tr' + $trClass + '><td class="num">' + (Esc $r."序号") + '</td><td>' + (Esc $r."执行时间") + '</td><td>' + $resHtml + '</td><td>' + (Esc $r."执行结论") + '</td><td>' + (Esc $r."令牌状态") + '</td><td>' + (Esc $r."守卫脚本判定") + '</td><td>' + (Esc $r."积分/连签") + '</td><td>' + (Esc $r."备注") + '</td></tr>')
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("_最近生成：" + $stamp + "_")
[System.IO.File]::WriteAllText($MdFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

[void]$sh.AppendLine('</tbody>')
[void]$sh.AppendLine('</table>')
[void]$sh.AppendLine('<div class="gen">最近生成：' + $stamp + '</div>')
[void]$sh.AppendLine('</body>')
[void]$sh.AppendLine('</html>')
[System.IO.File]::WriteAllText($HtmlFile, $sh.ToString(), (New-Object System.Text.UTF8Encoding($true)))

# ---------- 输出 ----------
if ($RebuildOnly) {
    Write-Output ("REBUILT rows=" + $rows.Count)
} else {
    Write-Output $summary
    Write-Output ("ROW=" + $seq)
}
Write-Output ("HTML=" + $HtmlFile)
