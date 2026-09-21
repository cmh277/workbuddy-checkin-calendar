# ============================================================
# WorkBuddy daily check-in - guard wrapper
#
# Purpose:
#   After any successful check-in on a given day (including the idempotent
#   "already signed today" response), write a date marker file.
#   Later makeup tasks on the same day detect the marker == today and SKIP
#   entirely (no API call), avoiding redundant check-in requests.
#   The marker rolls over naturally by date (next day auto-expires).
#   On failure (token expired / network error) the marker is NOT written,
#   so later makeup points still retry.
#
# Implementation: run checkin.ps1 inside an in-process Runspace to isolate its
#   internal `exit` statements (which would otherwise kill this wrapper) and to
#   avoid spawning a child process (works even in restricted environments).
#
# Match patterns use \u escapes for Chinese so the script source stays pure
# ASCII and is immune to file-encoding/codepage issues.
# ============================================================
$ErrorActionPreference = "Continue"
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

$GuardDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Marker   = Join-Path $GuardDir "last_success.txt"
$DebugLog = Join-Path $GuardDir "guard_debug.log"
$Today    = (Get-Date -Format "yyyy-MM-dd")

function Log($m) {
    $line = "$(Get-Date -Format 'HH:mm:ss') $m"
    Write-Output $line
    try { [System.IO.File]::AppendAllText($DebugLog, $line + "`r`n", [System.Text.Encoding]::UTF8) } catch {}
}

Log "=== guard start today=$Today ==="

# ---------- Guard: if already signed today, skip ----------
if (Test-Path $Marker) {
    $last = (Get-Content $Marker -Raw -ErrorAction SilentlyContinue).Trim()
    if ($last -eq $Today) {
        Log "today already signed -> SKIP (no API call)"
        exit 0
    }
}
Log "not signed today -> run checkin"

# ---------- Set Node runtime (needed by token decrypt) ----------
# PORTABILITY: do NOT hard-code an absolute user path here. Reuse the caller's
# WB_CHECKIN_NODE when it is valid; otherwise probe this machine's managed Node
# runtime dir, then fall back to `node` on PATH. (A hard-coded path from another
# machine silently overrides the correct value and breaks the decrypt chain.)
if (-not ($env:WB_CHECKIN_NODE -and (Test-Path $env:WB_CHECKIN_NODE))) {
    $nodeHit = ""
    if ($env:USERPROFILE) {
        $nodeBase = Join-Path $env:USERPROFILE ".workbuddy\binaries\node\versions"
        if (Test-Path $nodeBase) {
            $nodeFound = @(Get-ChildItem $nodeBase -Directory -ErrorAction SilentlyContinue |
                           Where-Object { Test-Path (Join-Path $_.FullName "node.exe") } |
                           Sort-Object Name -Descending)
            if ($nodeFound.Count -gt 0) { $nodeHit = Join-Path $nodeFound[0].FullName "node.exe" }
        }
    }
    if (-not $nodeHit) {
        try { $nc = Get-Command node -ErrorAction SilentlyContinue; if ($nc) { $nodeHit = $nc.Source } } catch {}
    }
    if ($nodeHit) { $env:WB_CHECKIN_NODE = $nodeHit }
}

# ---------- Re-establish user-profile env vars ----------
# The automation scheduler launches this script in a stripped environment where
# LOCALAPPDATA / APPDATA / USERPROFILE are often empty, so decrypt-token.js cannot
# locate workbuddy-desktop.info and the check-in fails. Prefer the real profile,
# else derive it from the managed Node path (6 levels up = user profile).
try {
    $prof = $env:USERPROFILE
    if (-not ($prof -and (Test-Path $prof))) {
        $prof = $env:WB_CHECKIN_NODE
        for ($i = 0; $i -lt 6; $i++) { $prof = Split-Path -Parent $prof }
    }
    if ($prof -and (Test-Path $prof)) {
        $env:USERPROFILE  = $prof
        $env:HOME         = $prof
        $env:LOCALAPPDATA = Join-Path $prof "AppData\Local"
        $env:APPDATA      = Join-Path $prof "AppData\Roaming"
    }
} catch {}

# ---------- Run checkin.ps1 in an isolated Runspace ----------
$RealScript = Join-Path $GuardDir "scripts\checkin.ps1"
try {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript("& '$($RealScript -replace "'","''")'") | Out-Null
    $results = $ps.Invoke()
    $out = ($results | ForEach-Object { $_.ToString() }) -join "`n"
    $errs = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
    $ps.Dispose(); $rs.Close()
} catch {
    $out = ""; $errs = "RUNSPACE_ERR: $($_.Exception.Message)"
}
Log "CHILD_OUT: $($out.Trim())"
if ($errs) { Log "CHILD_ERR: $($errs.Trim())" }

# ---------- Decide: signed today? -> write marker so later points skip ----------
# Chinese patterns (ASCII-safe \u escapes):
#   "today already signed" = \u4eca\u65e5\u5df2\u7b7e\u5230
#   "sign success"          = \u7b7e\u5230\u6210\u529f  (also yields "credit=")
$signed = ($out -match "\u4eca\u65e5\u5df2\u7b7e\u5230") -or ($out -match "\u7b7e\u5230\u6210\u529f") -or ($out -match "credit=")
if ($signed) {
    [System.IO.File]::WriteAllText($Marker, $Today, [System.Text.Encoding]::UTF8)
    Log "marker written for $Today (today done)"
    exit 0
} else {
    Log "not signed (token/network issue) -> marker NOT written, makeup points will retry"
    exit 1
}
