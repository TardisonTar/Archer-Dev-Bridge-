Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:SingleInstanceMutex = $null
try {
    [bool]$createdNew = $false
    $script:SingleInstanceMutex = [System.Threading.Mutex]::new($true, "Local\ArcherDevBridgeCore", [ref]$createdNew)
    if (-not $createdNew) {
        [System.Windows.Forms.MessageBox]::Show("Archer Dev Bridge уже запущен.", "Archer Dev Bridge", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        exit 0
    }
} catch {}

$BridgeVersion = "0.6.13"
$RunSchemaVersion = 2
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDataDir = Join-Path $env:LOCALAPPDATA "ArcherDevBridge"
$SettingsPath = Join-Path $AppDataDir "settings.json"
$LegacySettingsPaths = @((Join-Path $AppDataDir "settings-v0.2.json"),(Join-Path $AppDataDir "settings-v0.1.json"))
$RunsDir = Join-Path $AppDataDir "runs"
$GateStatePath = Join-Path $AppDataDir "last-gate.json"
$TaskQueuePath = Join-Path $AppDataDir "task-queue.json"
$RunLockPath = Join-Path $AppDataDir "active-run.lock.json"
$DiagnosticsDir = Join-Path $AppDataDir "diagnostics"
$LauncherDir = Join-Path $AppDataDir "launcher"
$UiReadyPath = Join-Path $LauncherDir "ui-ready.json"
$CancelShutdownPath = Join-Path $LauncherDir "cancel-self-destruct.flag"
$ShutdownGuardPath = Join-Path $LauncherDir "shutdown-guard.json"
$AgentProfileDir = Join-Path $env:USERPROFILE ".codex\agents"
$FallbackContextPath = Join-Path $ScriptDir "PROJECT_CONTEXT.md"
$AssetDir = Join-Path $ScriptDir "assets"
$LampGreenPath = Join-Path $AssetDir "lamp-green.png"
$LampYellowPath = Join-Path $AssetDir "lamp-yellow.png"
$LampRedPath = Join-Path $AssetDir "lamp-red.png"
$script:StatusLampSmall = @{}
$script:StatusLampLarge = @{}
$script:CodexPath = ""
$script:GitPath = ""
$script:DotNetPath = ""
$script:SystemReady = $false
$script:LastCyclePass = $false
$script:LastCycleSafetyStop = $false
$script:CountryInfo = $null
$script:LastCycleRunDir = ""
$script:LastCycleFailureStage = ""
$script:LastCycleStatus = "NO_DATA"
$script:StopRequested = $false
$script:ActiveProcess = $null
$script:ActiveStage = ""
$script:IsBusy = $false
$script:QueueInProgress = $false
$script:DevelopmentInProgress = $false
$script:GateInProgress = $false
$script:PlanInProgress = $false
$script:LastBusyChange = [DateTime]::MinValue
$script:CurrentParentTaskId = ""
$script:CurrentTaskType = "NORMAL"
$script:CurrentInheritedWorkingTree = $false
$script:SelfDestructSeconds = 30
$script:SelfDestructCancelled = $false
$script:SelfDestructEverCancelled = $false
$script:SelfDestructDeadline = (Get-Date).AddSeconds($script:SelfDestructSeconds)
$script:SelfDestructBlink = $false
$script:CompletionSignalActive = $false
$script:CompletionSignalKind = ""
$script:CompletionSignalTaskId = ""
$script:CompletionSignalBlink = $false

New-Item -ItemType Directory -Force -Path $AppDataDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunsDir | Out-Null
New-Item -ItemType Directory -Force -Path $DiagnosticsDir | Out-Null
New-Item -ItemType Directory -Force -Path $LauncherDir | Out-Null
try { if (Test-Path -LiteralPath $UiReadyPath) { Remove-Item -LiteralPath $UiReadyPath -Force -ErrorAction SilentlyContinue } } catch {}
try { if (Test-Path -LiteralPath $CancelShutdownPath) { Remove-Item -LiteralPath $CancelShutdownPath -Force -ErrorAction SilentlyContinue } } catch {}

function Load-LampBitmap {
    param([string]$Path,[int]$Width=16,[int]$Height=16)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $src = [System.Drawing.Image]::FromFile($Path)
        try {
            $bmp = New-Object System.Drawing.Bitmap $Width, $Height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawImage($src, 0, 0, $Width, $Height)
            } finally { $g.Dispose() }
            return $bmp
        } finally { $src.Dispose() }
    } catch { return $null }
}

function Initialize-LampAssets {
    if ($script:StatusLampSmall.Count -gt 0 -and $script:StatusLampLarge.Count -gt 0) { return }
    $script:StatusLampSmall['green'] = Load-LampBitmap $LampGreenPath 16 16
    $script:StatusLampSmall['yellow'] = Load-LampBitmap $LampYellowPath 16 16
    $script:StatusLampSmall['red'] = Load-LampBitmap $LampRedPath 16 16
    $script:StatusLampLarge['green'] = Load-LampBitmap $LampGreenPath 22 22
    $script:StatusLampLarge['yellow'] = Load-LampBitmap $LampYellowPath 22 22
    $script:StatusLampLarge['red'] = Load-LampBitmap $LampRedPath 22 22
}

function Get-StatusLampImage {
    param([string]$State,[switch]$Large)
    Initialize-LampAssets
    $key = ([string]$State).ToLowerInvariant()
    if ($Large) {
        if ($script:StatusLampLarge.ContainsKey($key)) { return $script:StatusLampLarge[$key] }
    } else {
        if ($script:StatusLampSmall.ContainsKey($key)) { return $script:StatusLampSmall[$key] }
    }
    return $null
}

function Add-Log {
    param([string]$Text)
    if ($null -eq $Text) { return }
    $stamp = Get-Date -Format "HH:mm:ss"
    if ($null -ne $txtLog) {
        $txtLog.AppendText("[$stamp] $Text`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Write-Utf8File {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ($null -eq $Text) { $Text = "" }
    [IO.File]::WriteAllText($Path,[string]$Text,(New-Object System.Text.UTF8Encoding($false)))
}

function Get-ConfiguredToolPath {
    param([string]$Name)
    switch ($Name.ToLowerInvariant()) {
        "codex"  { return $script:CodexPath }
        "git"    { return $script:GitPath }
        "dotnet" { return $script:DotNetPath }
        default   { return "" }
    }
}

function Set-ConfiguredToolPath {
    param([string]$Name, [string]$Path)
    switch ($Name.ToLowerInvariant()) {
        "codex"  { $script:CodexPath = $Path }
        "git"    { $script:GitPath = $Path }
        "dotnet" { $script:DotNetPath = $Path }
    }
}

function Refresh-ProcessPathFromRegistry {
    try {
        $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $user = [Environment]::GetEnvironmentVariable("Path", "User")
        $all = New-Object System.Collections.Generic.List[string]
        foreach ($raw in @($machine, $user, $env:Path)) {
            foreach ($part in @([string]$raw -split ';')) {
                $v = $part.Trim()
                if ($v -and -not $all.Contains($v)) { $all.Add($v) }
            }
        }
        $env:Path = ($all -join ';')
        return $true
    } catch { return $false }
}

function Resolve-ExecutablePath {
    param([string]$Name, [string]$ConfiguredPath = "")
    if (-not $Name) { return "" }

    foreach ($candidate in @($ConfiguredPath, (Get-ConfiguredToolPath $Name))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            try { return (Resolve-Path -LiteralPath $candidate).Path } catch { return $candidate }
        }
    }

    try {
        $cmd = Get-Command $Name -ErrorAction Stop | Select-Object -First 1
        $src = [string]$cmd.Source
        if (-not $src -and $cmd.Path) { $src = [string]$cmd.Path }
        if ($src -and (Test-Path -LiteralPath $src -PathType Leaf)) { return $src }
    } catch {}

    try {
        $where = Join-Path $env:SystemRoot "System32\\where.exe"
        if (Test-Path -LiteralPath $where) {
            $found = @(& $where $Name 2>$null | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
            if ($found.Count -gt 0) { return [string]$found[0] }
        }
    } catch {}

    $pf = [Environment]::GetFolderPath('ProgramFiles')
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $candidates = @()
    switch ($Name.ToLowerInvariant()) {
        "git" {
            $candidates += @(
                (Join-Path $pf "Git\\cmd\\git.exe"),
                (Join-Path $pf "Git\\bin\\git.exe"),
                (Join-Path $pf86 "Git\\cmd\\git.exe"),
                (Join-Path $env:LOCALAPPDATA "Programs\\Git\\cmd\\git.exe")
            )
        }
        "dotnet" {
            $candidates += @(
                (Join-Path $pf "dotnet\\dotnet.exe"),
                (Join-Path $pf86 "dotnet\\dotnet.exe")
            )
        }
        "codex" {
            $candidates += @(
                (Join-Path $env:USERPROFILE ".codex\\bin\\codex.exe"),
                (Join-Path $env:LOCALAPPDATA "Codex\\codex.exe"),
                (Join-Path $env:LOCALAPPDATA "Programs\\Codex\\codex.exe"),
                (Join-Path $env:LOCALAPPDATA "Microsoft\\WinGet\\Links\\codex.exe"),
                (Join-Path $env:USERPROFILE "scoop\\shims\\codex.exe")
            )
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return ""
}

function Resolve-AndPersistTool {
    param([string]$Name)
    $path = Resolve-ExecutablePath -Name $Name
    if ($path) { Set-ConfiguredToolPath -Name $Name -Path $path }
    return $path
}

function Invoke-ProcessCaptured {
    param(
        [Parameter(Mandatory=$true)][string]$FileName,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$StdInText = $null,
        [int]$TimeoutSeconds = 3600,
        [string]$StageName = ""
    )

    if ($FileName -in @("codex", "git", "dotnet")) {
        $resolvedTool = Resolve-ExecutablePath -Name $FileName
        if ($resolvedTool) { $FileName = $resolvedTool }
    }

    $p = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FileName
        $psi.Arguments = $Arguments
        if ($WorkingDirectory -and (Test-Path $WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($null -ne $StdInText) { $psi.RedirectStandardInput = $true }
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $script:ActiveProcess = $p
        if ($StageName) { $script:ActiveStage = $StageName }

        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        if ($null -ne $StdInText) {
            # IMPORTANT: Windows PowerShell 5.1 StreamWriter may encode redirected stdin using
            # the active OEM/ANSI code page. Codex CLI requires UTF-8. Write raw UTF-8 bytes
            # directly to the redirected stdin stream so Russian/non-ASCII prompts are lossless.
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $stdinBytes = $utf8NoBom.GetBytes([string]$StdInText)
            $stdinStream = $p.StandardInput.BaseStream
            $stdinStream.Write($stdinBytes,0,$stdinBytes.Length)
            $stdinStream.Flush()
            $stdinStream.Close()
        }

        $aborted = $false
        $timedOut = $false
        while (-not $p.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:StopRequested) {
                $aborted = $true
                Stop-ActiveProcessTree -Process $p
                break
            }
            if ($TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Stop-ActiveProcessTree -Process $p
                break
            }
            Start-Sleep -Milliseconds 150
        }
        try { $p.WaitForExit() } catch {}
        try { [void]$stdoutTask.Wait(5000) } catch {}
        try { [void]$stderrTask.Wait(5000) } catch {}
        $stdout = try { [string]$stdoutTask.Result } catch { "" }
        $stderr = try { [string]$stderrTask.Result } catch { "" }
        if ($aborted) { return [pscustomobject]@{ ExitCode=-3; StdOut=$stdout; StdErr="Остановлено пользователем."; Aborted=$true; TimedOut=$false; DurationSeconds=[math]::Round($sw.Elapsed.TotalSeconds,1) } }
        if ($timedOut) { return [pscustomobject]@{ ExitCode=-2; StdOut=$stdout; StdErr="Watchdog: превышен тайм-аут ${TimeoutSeconds} сек. Этап: $StageName"; Aborted=$false; TimedOut=$true; DurationSeconds=[math]::Round($sw.Elapsed.TotalSeconds,1) } }
        return [pscustomobject]@{ ExitCode=$p.ExitCode; StdOut=$stdout; StdErr=$stderr; Aborted=$false; TimedOut=$false; DurationSeconds=[math]::Round($sw.Elapsed.TotalSeconds,1) }
    }
    catch {
        return [pscustomobject]@{ ExitCode=-1; StdOut=""; StdErr=$_.Exception.Message; Aborted=$false; TimedOut=$false; DurationSeconds=[math]::Round($sw.Elapsed.TotalSeconds,1) }
    }
    finally {
        $sw.Stop()
        if ($null -ne $script:ActiveProcess -and $null -ne $p) {
            try { if ($script:ActiveProcess.Id -eq $p.Id) { $script:ActiveProcess = $null; $script:ActiveStage = "" } } catch { $script:ActiveProcess = $null; $script:ActiveStage = "" }
        }
    }
}

function Get-OpenAIResponseText {
    param($Response)
    if ($null -eq $Response) { return "" }
    if (($Response.PSObject.Properties.Name -contains "output_text") -and $Response.output_text) {
        return [string]$Response.output_text
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Response.output)) {
        foreach ($content in @($item.content)) {
            if ($content.type -eq "output_text" -and $content.text) {
                $parts.Add([string]$content.text)
            }
        }
    }
    return ($parts -join "`r`n")
}

function Invoke-OpenAIPlanner {
    param(
        [string]$ApiKey,
        [string]$Model,
        [string]$Effort,
        [string]$Instructions,
        [string]$InputText
    )
    if (-not $ApiKey) { throw "OPENAI_API_KEY не задан." }
    if (-not $Model) { $Model = "gpt-5.6-sol" }
    if (-not $Effort) { $Effort = "medium" }

    $body = @{
        model = $Model
        instructions = $Instructions
        input = $InputText
        reasoning = @{ effort = $Effort }
    } | ConvertTo-Json -Depth 10

    $headers = @{ Authorization = "Bearer $ApiKey" }
    $response = Invoke-RestMethod -Method Post -Uri "https://api.openai.com/v1/responses" -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
    return Get-OpenAIResponseText $response
}

function Get-ApiKey {
    $key = $txtApiKey.Text.Trim()
    if ($key) { return $key }
    $processKey = [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "Process")
    if ($processKey) { return $processKey }
    return [Environment]::GetEnvironmentVariable("OPENAI_API_KEY", "User")
}

function Get-ComboValue {
    param($Combo, [string]$Fallback = "")
    $v = [string]$Combo.Text
    if (-not $v) { return $Fallback }
    return $v.Trim()
}

function Get-OperatorMode {
    if ($null -eq $cmbOperatorMode) { return "ONE_CODEX" }
    $v = [string]$cmbOperatorMode.Text
    if ($v -match "AI TEAM") { return "AI_TEAM" }
    return "ONE_CODEX"
}

function Update-OperatorModeUi {
    $mode = Get-OperatorMode
    if ($null -ne $btnRun) {
        if ($mode -eq "AI_TEAM") {
            $btnRun.Text = "ASTRA: ЗАПУСТИТЬ ЗАДАЧУ → AI TEAM → STRICT GATE"
        } else {
            $btnRun.Text = "ASTRA: ЗАПУСТИТЬ ЗАДАЧУ → ONE CODEX → STRICT GATE"
        }
    }
    if ($null -ne $btnRunQueue) {
        $btnRunQueue.Text = $(if($mode -eq "AI_TEAM"){"ЗАПУСТИТЬ ОЧЕРЕДЬ • AI TEAM"}else{"ЗАПУСТИТЬ ОЧЕРЕДЬ • ONE CODEX"})
    }
}

# --- Archer 0.6 operator helpers -------------------------------------------------
$script:CountryCheckedAt = [DateTime]::MinValue

function Convert-CountryCodeToName {
    param([string]$Code)
    if (-not $Code -or $Code -notmatch '^[A-Za-z]{2}$') { return "Не определена" }
    $normalized = $Code.ToUpperInvariant()
    try {
        $ri = New-Object System.Globalization.RegionInfo($normalized)
        if ($ri.DisplayName) { return [string]$ri.DisplayName }
    } catch {}
    return $normalized
}

function Get-InternetCountryInfo {
    param([switch]$Force)

    if (-not $Force -and $null -ne $script:CountryInfo -and $script:CountryCheckedAt -ne [DateTime]::MinValue) {
        $age = ((Get-Date) - $script:CountryCheckedAt).TotalMinutes
        if ($age -lt 15) { return $script:CountryInfo }
    }

    $headers = @{ "User-Agent" = "ArcherDevBridge/$BridgeVersion" }
    $code = ""
    $source = ""
    $errors = New-Object System.Collections.Generic.List[string]

    # Primary service: returns external IP + ISO country code. We discard the IP immediately.
    try {
        $r = Invoke-RestMethod -Method Get -Uri "https://api.country.is/" -Headers $headers -TimeoutSec 5
        if ($null -ne $r -and $r.country) { $code = ([string]$r.country).Trim().ToUpperInvariant(); $source = "api.country.is / внешний IP" }
    } catch { $errors.Add("api.country.is: " + $_.Exception.Message) }

    # Fallback service: plain ISO country code. No coordinates are requested.
    if ($code -notmatch '^[A-Z]{2}$') {
        try {
            $r2 = Invoke-WebRequest -UseBasicParsing -Method Get -Uri "https://ipapi.co/country/" -Headers $headers -TimeoutSec 5
            $candidate = ([string]$r2.Content).Trim().ToUpperInvariant()
            if ($candidate -match '^[A-Z]{2}$') { $code = $candidate; $source = "ipapi.co / внешний IP" }
        } catch { $errors.Add("ipapi.co: " + $_.Exception.Message) }
    }

    if ($code -match '^[A-Z]{2}$') {
        $info = [pscustomobject]@{
            State  = "green"
            Code   = $code
            Name   = (Convert-CountryCodeToName $code)
            Source = $source
            Detail = "Определено через интернет по внешнему IP. Координаты/GPS не запрашиваются и не сохраняются. VPN/proxy может изменить отображаемую страну."
            Path   = ""
            NameKey = "Country"
        }
    } else {
        $detail = "Страна не определена: интернет или сервис IP-геолокации недоступен. Регион Windows не используется."
        if ($errors.Count -gt 0) { $detail += " Ошибки: " + (($errors | Select-Object -First 2) -join " | ") }
        $info = [pscustomobject]@{ State="yellow"; Code=""; Name="Не определена"; Source="Интернет/IP"; Detail=$detail; Path=""; NameKey="Country" }
    }

    $script:CountryInfo = $info
    $script:CountryCheckedAt = Get-Date
    return $info
}

function Get-CodexAuthInfo {
    $path = Resolve-AndPersistTool "codex"
    if (-not $path) { return [pscustomobject]@{ State="missing"; Mode="unknown"; Detail="Codex CLI не найден"; Raw="" } }
    $r = Invoke-ProcessCaptured -FileName $path -Arguments "login status" -TimeoutSeconds 30
    $raw = (($r.StdOut + " " + $r.StdErr).Trim())
    if ($r.ExitCode -ne 0) { return [pscustomobject]@{ State="unknown"; Mode="unknown"; Detail="Не удалось подтвердить авторизацию Codex"; Raw=$raw } }
    if ($raw -match '(?i)api[ -]?key|OPENAI_API_KEY|api key') {
        return [pscustomobject]@{ State="ok"; Mode="api"; Detail="API key — отдельная API-тарификация"; Raw=$raw }
    }
    return [pscustomobject]@{ State="ok"; Mode="chatgpt"; Detail=$(if($raw){$raw}else{"ChatGPT account"}); Raw=$raw }
}

function Test-CodexAuthAllowed {
    $auth = Get-CodexAuthInfo
    if ($auth.State -ne "ok") { return [pscustomobject]@{ Allowed=$false; Auth=$auth; Reason=$auth.Detail } }
    if ($auth.Mode -eq "api" -and -not $chkAllowApiAuth.Checked) {
        return [pscustomobject]@{ Allowed=$false; Auth=$auth; Reason="Codex авторизован через API key. В 0.6 это блокируется по умолчанию, чтобы не создавать отдельные API-расходы." }
    }
    return [pscustomobject]@{ Allowed=$true; Auth=$auth; Reason="OK" }
}

function Get-CodexSemVer {
    $path = Resolve-AndPersistTool "codex"
    if (-not $path) { return $null }
    $r = Invoke-ProcessCaptured -FileName $path -Arguments "--version" -TimeoutSeconds 30
    if ($r.ExitCode -ne 0) { return $null }
    $m = [regex]::Match(($r.StdOut + " " + $r.StdErr), '(\d+\.\d+\.\d+)')
    if (-not $m.Success) { return $null }
    try { return [version]$m.Groups[1].Value } catch { return $null }
}

function Get-AgentProfilePaths {
    return [pscustomobject]@{
        Explorer = Join-Path $AgentProfileDir "archer_explorer.toml"
        Worker = Join-Path $AgentProfileDir "archer_worker.toml"
        Reviewer = Join-Path $AgentProfileDir "archer_reviewer.toml"
    }
}

function Ensure-AstraAgentProfiles {
    param([switch]$Repair)
    $paths = Get-AgentProfilePaths
    if ($Repair -and -not (Test-Path $AgentProfileDir)) { New-Item -ItemType Directory -Force -Path $AgentProfileDir | Out-Null }
    $profiles = @{
        Explorer = @'
name = "archer_explorer"
description = "Read-only Archer codebase explorer. Maps execution paths and architecture before implementation."
model = "gpt-5.6-terra"
model_reasoning_effort = "medium"
sandbox_mode = "read-only"
developer_instructions = """
Stay read-only. Inspect the selected repository and mandatory PROJECT_RULES.md, ARCHITECTURE.md and AGENTS.md. Trace real execution paths, identify affected files/symbols, architecture boundaries, and likely regression risks. Do not edit files. Return concise evidence to the parent Astra operator.
"""
'@
        Worker = @'
name = "archer_worker"
description = "Archer implementation worker for focused code changes and repairs."
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
sandbox_mode = "workspace-write"
developer_instructions = """
Implement only the task delegated by the parent Astra operator. Respect repository rules and server-authoritative boundaries. Make the smallest coherent change. Do not commit, push, reset, rebase, clean, or modify unrelated files. Run relevant safe checks and report exact files changed and remaining risks.
"""
'@
        Reviewer = @'
name = "archer_reviewer"
description = "Independent read-only reviewer for correctness, architecture, safety and missing tests."
model = "gpt-5.6-terra"
model_reasoning_effort = "high"
sandbox_mode = "read-only"
developer_instructions = """
Review the worker result like a repository owner. Prioritize correctness, architecture violations, security/safety, behavior regressions and missing tests. Use repository evidence. Do not edit files. End with exactly REVIEW_RESULT: PASS or REVIEW_RESULT: NEEDS_FIX and concrete reasons.
"""
'@
    }
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($key in @("Explorer","Worker","Reviewer")) {
        $path = [string]$paths.$key
        $expected = [string]$profiles[$key]
        $needs = $true
        if (Test-Path $path) {
            try { $needs = ((Get-Content -Raw -Encoding UTF8 $path).Trim() -ne $expected.Trim()) } catch { $needs = $true }
        }
        if ($Repair -and $needs) { Write-Utf8File $path $expected; $changed.Add($path) }
    }
    $ok = (Test-Path $paths.Explorer) -and (Test-Path $paths.Worker) -and (Test-Path $paths.Reviewer)
    return [pscustomobject]@{ Ready=$ok; Paths=$paths; Changed=$changed }
}

function Get-AstraCompatibilityHealth {
    $ver = Get-CodexSemVer
    if ($null -eq $ver) { return (New-HealthResult "red" "Astra" "Версия Codex CLI не определена") }
    if ($ver -lt [version]"0.153.0") { return (New-HealthResult "red" "Astra" ("Codex CLI {0}; для Astra требуется 0.153.0+" -f $ver)) }
    $model = Get-ComboValue $cmbCodexModel "gpt-6-astra"
    if ($model -ne "gpt-6-astra") { return (New-HealthResult "yellow" "Astra" ("CLI совместим; выбран альтернативный operator model: " + $model)) }
    return (New-HealthResult "green" "Astra" ("Operator gpt-6-astra; Codex CLI " + $ver))
}

function Test-ManualReleaseReviewBlocker {
    param([string]$Blocker)
    if ([string]::IsNullOrWhiteSpace($Blocker)) { return $false }
    $code = $Blocker.Trim().ToUpperInvariant()
    return ($code -in @(
        'EXPORTED_UI_PROFILE_GATE_UNAVAILABLE',
        'EXPORTED_PLAYABLE_SMOKE_UNAVAILABLE',
        'DESKTOP_AUTOMATION_UNAVAILABLE',
        'MANUAL_RELEASE_CHECK_REQUIRED'
    ))
}

function Get-OperatorDecision {
    param([string]$Text)

    $result = "UNKNOWN"
    $review = "UNKNOWN"
    $sourceStatus = "UNKNOWN"
    $releaseStatus = "UNKNOWN"
    $blocker = "NONE"
    $repairSource = $null
    $environmentBlocked = $false
    $manualReleaseReview = $false
    $hasExplicitResult = $false
    $hasExplicitReview = $false
    $hasExplicitSourceStatus = $false
    $hasExplicitReleaseStatus = $false
    $hasExplicitBlocker = $false
    $hasExplicitRepairSource = $false

    if ($Text) {
        $m = [regex]::Match($Text, '(?im)^\s*OPERATOR_RESULT\s*:\s*(READY_FOR_GATE|NEEDS_REVIEW|BLOCKED_ENVIRONMENT|BLOCKED)\b')
        if ($m.Success) { $result = $m.Groups[1].Value.ToUpperInvariant(); $hasExplicitResult = $true }

        $m = [regex]::Match($Text, '(?im)^\s*OPERATOR_REVIEW\s*:\s*(PASS|NEEDS_FIX|NEEDS_REVIEW)\b')
        if ($m.Success) { $review = $m.Groups[1].Value.ToUpperInvariant(); $hasExplicitReview = $true }
        else {
            $m = [regex]::Match($Text, '(?im)^\s*REVIEW_RESULT\s*:\s*(PASS|NEEDS_FIX|NEEDS_REVIEW)\b')
            if ($m.Success) { $review = $m.Groups[1].Value.ToUpperInvariant(); $hasExplicitReview = $true }
        }

        $m = [regex]::Match($Text, '(?im)^\s*SOURCE_STATUS\s*:\s*(PASS|NEEDS_FIX|UNKNOWN)\b')
        if ($m.Success) { $sourceStatus = $m.Groups[1].Value.ToUpperInvariant(); $hasExplicitSourceStatus = $true }

        $m = [regex]::Match($Text, '(?im)^\s*RELEASE_STATUS\s*:\s*(READY|BLOCKED_ENVIRONMENT|BLOCKED|NEEDS_REVIEW|UNKNOWN)\b')
        if ($m.Success) { $releaseStatus = $m.Groups[1].Value.ToUpperInvariant(); $hasExplicitReleaseStatus = $true }

        $m = [regex]::Match($Text, '(?im)^\s*BLOCKER\s*:\s*([^\r\n]+)')
        if ($m.Success) { $blocker = $m.Groups[1].Value.Trim(); $hasExplicitBlocker = $true }

        $m = [regex]::Match($Text, '(?im)^\s*REPAIR_SOURCE\s*:\s*(TRUE|FALSE)\b')
        if ($m.Success) { $repairSource = ($m.Groups[1].Value.ToUpperInvariant() -eq 'TRUE'); $hasExplicitRepairSource = $true }

        # 0.6.12 precedence rule: a structured final marker is authoritative. Historical
        # stderr/report text must never overwrite an explicit current BLOCKER/RELEASE_STATUS.
        $manualReleaseReview = (Test-ManualReleaseReviewBlocker $blocker)
        if ($manualReleaseReview) {
            $environmentBlocked = $false
            $releaseStatus = 'NEEDS_REVIEW'
            if ($result -eq 'BLOCKED_ENVIRONMENT' -or $result -eq 'BLOCKED') { $result = 'NEEDS_REVIEW' }
            if ($review -eq 'UNKNOWN') { $review = 'NEEDS_REVIEW' }
            if ($null -eq $repairSource) { $repairSource = $false }
        } elseif ($result -eq 'BLOCKED_ENVIRONMENT' -or $releaseStatus -eq 'BLOCKED_ENVIRONMENT') {
            $environmentBlocked = $true
        }

        # Heuristics are fallback-only. They may classify unstructured tool output, but they
        # cannot supersede an explicit structured blocker/release decision from Astra.
        $allowEnvironmentHeuristics = ((-not $hasExplicitReleaseStatus) -or $releaseStatus -eq 'UNKNOWN') -and ((-not $hasExplicitBlocker) -or $blocker -eq 'NONE')
        if ($allowEnvironmentHeuristics -and -not $manualReleaseReview) {
            if ($Text -match '(?i)\bNU1301\b') {
                $environmentBlocked = $true
                $releaseStatus = 'BLOCKED_ENVIRONMENT'
                $blocker = 'WINDOWS_EXPORT_NU1301'
            } elseif ($Text -match '(?i)unable to load the service index for source|runtime (nuget )?packs?.{0,80}(missing|absent|unavailable)|environment blocker|publish dependenc(?:y|ies).{0,80}(missing|unavailable)') {
                $environmentBlocked = $true
                if ($releaseStatus -eq 'UNKNOWN') { $releaseStatus = 'BLOCKED_ENVIRONMENT' }
                if ($blocker -eq 'NONE') { $blocker = 'ENVIRONMENT_DEPENDENCY_BLOCKER' }
            }
        }
    }

    $hasStructuredDecision = ($hasExplicitResult -or $hasExplicitReview -or $hasExplicitSourceStatus -or $hasExplicitReleaseStatus -or $hasExplicitBlocker -or $hasExplicitRepairSource)
    return [pscustomobject]@{
        Result = $result
        Review = $review
        SourceStatus = $sourceStatus
        ReleaseStatus = $releaseStatus
        Blocker = $blocker
        RepairSource = $repairSource
        EnvironmentBlocked = $environmentBlocked
        ManualReleaseReview = $manualReleaseReview
        HasStructuredDecision = $hasStructuredDecision
        ReviewPass = ($review -eq 'PASS')
        NeedsFix = ($review -eq 'NEEDS_FIX')
        NeedsReview = ($manualReleaseReview -or $review -eq 'NEEDS_REVIEW' -or $result -eq 'NEEDS_REVIEW')
        Blocked = (-not $manualReleaseReview -and $result -in @('BLOCKED','BLOCKED_ENVIRONMENT'))
    }
}

function Get-OperatorReviewPass {
    param([string]$Text)
    return [bool](Get-OperatorDecision $Text).ReviewPass
}

function Save-Settings {
    try {
        $obj = @{
            schemaVersion=7; bridgeVersion=$BridgeVersion;
            projectPath=$txtProject.Text.Trim(); godotPath=$txtGodot.Text.Trim();
            codexPath=$script:CodexPath; gitPath=$script:GitPath; dotnetPath=$script:DotNetPath;
            codexModel=(Get-ComboValue $cmbCodexModel "gpt-6-astra");
            codexReasoning=(Get-ComboValue $cmbCodexReasoning "medium");
            operatorMode=(Get-ComboValue $cmbOperatorMode "ASTRA + ONE CODEX");
            allowApiAuth=$chkAllowApiAuth.Checked;
            plannerApiModel=$txtApiModel.Text.Trim(); plannerApiReasoning=(Get-ComboValue $cmbApiReasoning "medium");
            usePlanner=$chkPlanner.Checked; autoRepair=$chkAutoRepair.Checked;
            requireCleanStart=$chkRequireClean.Checked; runProjectTests=$chkTests.Checked; runGodotSmoke=$chkGodotSmoke.Checked;
            watchdogMinutes=$(if($null -ne $numWatchdog){[int]$numWatchdog.Value}else{30});
            maxRuns=$(if($null -ne $numMaxRuns){[int]$numMaxRuns.Value}else{100});
            maxRunGB=$(if($null -ne $numMaxRunGB){[decimal]$numMaxRunGB.Value}else{5})
            roadmapDependency=$(if($null -ne $chkRoadmapDependency){[bool]$chkRoadmapDependency.Checked}else{$false})
            completionSignalEnabled=$(if($null -ne $chkCompletionSignal){[bool]$chkCompletionSignal.Checked}else{$true})
        }
        $tmp=$SettingsPath+".tmp"; $obj | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $tmp; Move-Item -Force $tmp $SettingsPath
    } catch { Add-Log "Не удалось сохранить настройки: $($_.Exception.Message)" }
}

function Load-Settings {
    $source=$SettingsPath
    if (-not (Test-Path $source)) { foreach($legacy in $LegacySettingsPaths){ if(Test-Path $legacy){$source=$legacy; break} } }
    if (-not (Test-Path $source)) { return }
    try {
        $s=Get-Content -Raw -Encoding UTF8 $source | ConvertFrom-Json
        if($s.projectPath){$txtProject.Text=[string]$s.projectPath}; if($s.godotPath){$txtGodot.Text=[string]$s.godotPath}
        if($s.codexPath){$script:CodexPath=[string]$s.codexPath}; if($s.gitPath){$script:GitPath=[string]$s.gitPath}; if($s.dotnetPath){$script:DotNetPath=[string]$s.dotnetPath}
        $legacyBridge = ([string]$s.bridgeVersion -like '0.4*') -or (-not $s.schemaVersion) -or ([int]$s.schemaVersion -lt 3)
        $cm=if($legacyBridge){"gpt-6-astra"}elseif($s.codexModel){[string]$s.codexModel}else{"gpt-6-astra"}; $cmbCodexModel.Text=$cm
        $cr=if($legacyBridge){"medium"}elseif($s.codexReasoning){[string]$s.codexReasoning}else{"medium"}; $cmbCodexReasoning.SelectedItem=$cr
        if(-not $cmbCodexReasoning.SelectedItem){$cmbCodexReasoning.SelectedItem="medium"}
        $om=if($s.operatorMode){[string]$s.operatorMode}else{"ASTRA + ONE CODEX"}; $cmbOperatorMode.SelectedItem=$om
        if(-not $cmbOperatorMode.SelectedItem){$cmbOperatorMode.SelectedItem="ASTRA + ONE CODEX"}
        Update-OperatorModeUi
        if($null -ne $s.allowApiAuth){$chkAllowApiAuth.Checked=[bool]$s.allowApiAuth}else{$chkAllowApiAuth.Checked=$false}
        $am=if($s.plannerApiModel){[string]$s.plannerApiModel}elseif($s.model){[string]$s.model}else{"gpt-5.6-sol"}; $txtApiModel.Text=$am
        $ar=if($s.plannerApiReasoning){[string]$s.plannerApiReasoning}else{"medium"}; $cmbApiReasoning.SelectedItem=$ar; if(-not $cmbApiReasoning.SelectedItem){$cmbApiReasoning.SelectedItem="medium"}
        if($null -ne $s.usePlanner){$chkPlanner.Checked=[bool]$s.usePlanner}else{$chkPlanner.Checked=$false}
        if($null -ne $s.autoRepair){$chkAutoRepair.Checked=[bool]$s.autoRepair}else{$chkAutoRepair.Checked=$true}
        if($null -ne $s.requireCleanStart){$chkRequireClean.Checked=[bool]$s.requireCleanStart}
        if($null -ne $s.runProjectTests){$chkTests.Checked=[bool]$s.runProjectTests}
        if($null -ne $s.runGodotSmoke){$chkGodotSmoke.Checked=[bool]$s.runGodotSmoke}
        if($null -ne $numWatchdog -and $null -ne $s.watchdogMinutes){$numWatchdog.Value=[Math]::Max($numWatchdog.Minimum,[Math]::Min($numWatchdog.Maximum,[decimal]$s.watchdogMinutes))}
        if($null -ne $numMaxRuns -and $null -ne $s.maxRuns){$numMaxRuns.Value=[Math]::Max($numMaxRuns.Minimum,[Math]::Min($numMaxRuns.Maximum,[decimal]$s.maxRuns))}
        if($null -ne $numMaxRunGB -and $null -ne $s.maxRunGB){$numMaxRunGB.Value=[Math]::Max($numMaxRunGB.Minimum,[Math]::Min($numMaxRunGB.Maximum,[decimal]$s.maxRunGB))}
        if($null -ne $chkRoadmapDependency -and $null -ne $s.roadmapDependency){$chkRoadmapDependency.Checked=[bool]$s.roadmapDependency}
        if($null -ne $chkCompletionSignal){
            if($null -ne $s.completionSignalEnabled){$chkCompletionSignal.Checked=[bool]$s.completionSignalEnabled}else{$chkCompletionSignal.Checked=$true}
        }
        if($source -ne $SettingsPath -or $legacyBridge -or -not $s.schemaVersion -or [int]$s.schemaVersion -lt 7){Save-Settings; Add-Log "Настройки мигрированы в схему Archer Dev Bridge 0.6.12."}
    } catch { Add-Log "Не удалось прочитать настройки: $($_.Exception.Message)" }
}

function Get-CSharpProjectFile {
    param([string]$ProjectDir)
    $rootMatches = @(Get-ChildItem -Path $ProjectDir -Filter *.csproj -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "[\\/]Tests[\\/]" })
    if ($rootMatches.Count -gt 0) { return $rootMatches[0].FullName }
    $all = @(Get-ChildItem -Path $ProjectDir -Filter *.csproj -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "[\\/](bin|obj|\.godot)[\\/]" -and $_.FullName -notmatch "[\\/]Tests[\\/]" } |
        Sort-Object FullName)
    if ($all.Count -gt 0) { return $all[0].FullName }
    return $null
}

function Get-TestProjectFile {
    param([string]$ProjectDir)
    $preferred = Join-Path $ProjectDir "Tests\Tests.csproj"
    if (Test-Path $preferred) { return $preferred }
    $all = @(Get-ChildItem -Path $ProjectDir -Filter *.csproj -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "[\\/]Tests?[\\/]" -and $_.FullName -notmatch "[\\/](bin|obj)[\\/]" } |
        Sort-Object FullName)
    if ($all.Count -gt 0) { return $all[0].FullName }
    return $null
}

function Get-GitBaseInfo {
    param([string]$ProjectDir)
    $branch = Invoke-ProcessCaptured -FileName "git" -Arguments "branch --show-current" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    $head = Invoke-ProcessCaptured -FileName "git" -Arguments "rev-parse HEAD" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    $subject = Invoke-ProcessCaptured -FileName "git" -Arguments "log -1 --pretty=%s" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    $status = Invoke-ProcessCaptured -FileName "git" -Arguments "status --short" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    return [pscustomobject]@{
        Branch = $branch.StdOut.Trim()
        Head = $head.StdOut.Trim()
        Subject = $subject.StdOut.Trim()
        Status = $status.StdOut
        HasGit = ($head.ExitCode -eq 0)
    }
}


function Get-GitWorkingTreeDetails {
    param([string]$ProjectDir)
    $gitPath = Resolve-AndPersistTool "git"
    if (-not $gitPath -or -not $ProjectDir -or -not (Test-Path -LiteralPath $ProjectDir)) {
        return [pscustomobject]@{ HasGit=$false; Dirty=$false; Total=0; Staged=0; Unstaged=0; Untracked=0; Deleted=0; Renamed=0; Conflict=0; Items=@(); Raw=""; Summary="Git/project unavailable" }
    }
    $r = Invoke-ProcessCaptured -FileName $gitPath -Arguments "status --porcelain=v1 -uall" -WorkingDirectory $ProjectDir -TimeoutSeconds 60
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ HasGit=$false; Dirty=$false; Total=0; Staged=0; Unstaged=0; Untracked=0; Deleted=0; Renamed=0; Conflict=0; Items=@(); Raw=($r.StdOut+$r.StdErr); Summary="git status failed" }
    }
    $items = @()
    $staged=0; $unstaged=0; $untracked=0; $deleted=0; $renamed=0; $conflict=0
    foreach($line in @($r.StdOut -split "`r?`n" | Where-Object { $_ -and $_.Length -ge 3 })) {
        $xy=$line.Substring(0,2)
        $path=$line.Substring(3).Trim()
        if($path -match ' -> '){$path=($path -split ' -> ')[-1].Trim();$renamed++}
        if($path.StartsWith('"') -and $path.EndsWith('"')){$path=$path.Trim('"')}
        $kind="MODIFIED"
        if($xy -eq '??'){$kind="UNTRACKED";$untracked++}
        else {
            if($xy[0] -ne ' ' -and $xy[0] -ne '?'){$staged++}
            if($xy[1] -ne ' ' -and $xy[1] -ne '?'){$unstaged++}
            if($xy -match '[DU]'){$deleted++}
            if($xy -match '^(DD|AU|UD|UA|DU|AA|UU)$'){$conflict++;$kind="CONFLICT"}
            elseif($xy -match 'R'){$kind="RENAMED"}
            elseif($xy -match 'D'){$kind="DELETED"}
            elseif($xy -match 'A'){$kind="ADDED"}
        }
        $items += [pscustomobject]@{Code=$xy;Kind=$kind;Path=$path}
    }
    $summary = if($items.Count -eq 0){"working tree clean"}else{"DIRTY: $($items.Count) item(s); staged=$staged; unstaged=$unstaged; untracked=$untracked; conflicts=$conflict"}
    return [pscustomobject]@{ HasGit=$true; Dirty=($items.Count -gt 0); Total=$items.Count; Staged=$staged; Unstaged=$unstaged; Untracked=$untracked; Deleted=$deleted; Renamed=$renamed; Conflict=$conflict; Items=$items; Raw=$r.StdOut; Summary=$summary }
}

function Format-GitWorkingTreeDetails {
    param($Details,[int]$MaxItems=200)
    if($null -eq $Details){return "Git details unavailable."}
    $lines=New-Object System.Collections.Generic.List[string]
    $lines.Add("GIT WORKING TREE")
    $lines.Add("Summary: $($Details.Summary)")
    $lines.Add("")
    $count=0
    foreach($it in @($Details.Items)){
        if($count -ge $MaxItems){$lines.Add("... ещё $($Details.Total-$MaxItems) item(s)");break}
        $lines.Add(("{0,-2}  {1,-10}  {2}" -f $it.Code,$it.Kind,$it.Path));$count++
    }
    return ($lines -join "`r`n")
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + $Value.Replace('"','\"') + '"'
}

function Show-GitDiffWindow {
    param([string]$ProjectDir,$Item,$Owner)
    if($null -eq $Item){[System.Windows.Forms.MessageBox]::Show("Выберите файл в списке.","Git Diff")|Out-Null;return}
    $gitPath=Resolve-AndPersistTool "git"
    if(-not $gitPath){[System.Windows.Forms.MessageBox]::Show("Git не найден.","Git Diff")|Out-Null;return}
    $path=[string]$Item.Path
    $arg=Quote-ProcessArgument $path
    $unstaged=Invoke-ProcessCaptured -FileName $gitPath -Arguments ("diff --no-ext-diff --unified=5 -- " + $arg) -WorkingDirectory $ProjectDir -TimeoutSeconds 60
    $staged=Invoke-ProcessCaptured -FileName $gitPath -Arguments ("diff --cached --no-ext-diff --unified=5 -- " + $arg) -WorkingDirectory $ProjectDir -TimeoutSeconds 60
    $parts=@()
    if($staged.StdOut){$parts += "===== STAGED =====`r`n$($staged.StdOut)"}
    if($unstaged.StdOut){$parts += "===== UNSTAGED =====`r`n$($unstaged.StdOut)"}
    if($Item.Kind -eq "UNTRACKED"){
        $full=Join-Path $ProjectDir $path
        if(Test-Path -LiteralPath $full){$parts += "===== UNTRACKED FILE CONTENT =====`r`n$(Get-SafeTextFileContent -Path $full -MaxChars 60000)"}
    }
    if($parts.Count -eq 0){$parts += "Git не вернул текстовый diff для этого элемента."}
    $f=New-Object System.Windows.Forms.Form
    $f.Text="Archer Dev Bridge — Git Diff — $path"
    $f.Size=New-Object System.Drawing.Size(1050,720);$f.StartPosition="CenterParent"
    $f.BackColor=[System.Drawing.Color]::FromArgb(15,21,29);$f.ForeColor=[System.Drawing.Color]::FromArgb(232,238,245)
    $tb=New-Object System.Windows.Forms.TextBox
    $tb.Location=New-Object System.Drawing.Point(12,12);$tb.Size=New-Object System.Drawing.Size(1010,620)
    $tb.Multiline=$true;$tb.ReadOnly=$true;$tb.ScrollBars=[System.Windows.Forms.ScrollBars]::Both;$tb.WordWrap=$false
    $tb.Font=New-Object System.Drawing.Font("Consolas",9);$tb.BackColor=[System.Drawing.Color]::FromArgb(7,12,18);$tb.ForeColor=[System.Drawing.Color]::FromArgb(220,230,238)
    $tb.Text=($parts -join "`r`n`r`n");$f.Controls.Add($tb)
    $btn=New-Object System.Windows.Forms.Button;$btn.Text="ЗАКРЫТЬ";$btn.Location=New-Object System.Drawing.Point(892,642);$btn.Size=New-Object System.Drawing.Size(130,34);Style-ArcherButton $btn;$btn.Add_Click({$f.Close()});$f.Controls.Add($btn)
    [void]$f.ShowDialog($Owner)
}

function New-GitBaselineCommit {
    param([string]$ProjectDir,$Owner)
    $gitPath=Resolve-AndPersistTool "git"
    if(-not $gitPath){[System.Windows.Forms.MessageBox]::Show("Git не найден.","BASE commit")|Out-Null;return $false}
    $d=Get-GitWorkingTreeDetails $ProjectDir
    if(-not $d.Dirty){
        $headClean=Invoke-ProcessCaptured -FileName $gitPath -Arguments "rev-parse --short HEAD" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
        $roadmapClean=Confirm-RoadmapBaseCommit -Head $headClean.StdOut.Trim()
        if($roadmapClean){
            $u=if(@($roadmapClean.Unlocked).Count -gt 0){(@($roadmapClean.Unlocked) -join ', ')}else{'нет зависимых задач'}
            [System.Windows.Forms.MessageBox]::Show("Git уже CLEAN. Текущий HEAD принят как BASE для $($roadmapClean.TaskId).`r`n`r`nРазблокировано: $u","BASE / ROADMAP")|Out-Null
        } else {[System.Windows.Forms.MessageBox]::Show("Рабочее дерево уже чистое. BASE commit не требуется.","BASE commit")|Out-Null}
        return $true
    }
    if($d.Conflict -gt 0){[System.Windows.Forms.MessageBox]::Show("Есть Git-конфликты. BASE commit заблокирован до их разрешения.","BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return $false}
    if($d.Staged -gt 0){[System.Windows.Forms.MessageBox]::Show("В Git уже есть staged-изменения. Чтобы Bridge не изменил существующий staging, BASE commit заблокирован. Сначала завершите текущий staging в Git-клиенте.","BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return $false}
    $base=Get-GitBaseInfo $ProjectDir
    if(-not $base.Branch){[System.Windows.Forms.MessageBox]::Show("Git находится в detached HEAD. BASE commit в этом состоянии заблокирован.","BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return $false}
    $ident=Invoke-ProcessCaptured -FileName $gitPath -Arguments "var GIT_AUTHOR_IDENT" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    if($ident.ExitCode -ne 0){[System.Windows.Forms.MessageBox]::Show("Git user.name/user.email не настроены для этого репозитория. Bridge не будет менять credentials автоматически.`r`n`r`n$($ident.StdErr)","BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return $false}
    $names=@($d.Items | Select-Object -First 15 | ForEach-Object { "• $($_.Path) [$($_.Kind)]" })
    $more=if($d.Total -gt 15){"`r`n...и ещё $($d.Total-15)"}else{""}
    $msg="Создать BASE commit текущего состояния?`r`n`r`nВ commit войдут ВСЕ текущие изменения рабочей копии ($($d.Total)).`r`nЭто явное действие пользователя; Bridge никогда не делает commit автоматически.`r`n`r`n$($names -join "`r`n")$more`r`n`r`nПосле успешного commit Git должен стать CLEAN."
    $ans=[System.Windows.Forms.MessageBox]::Show($msg,"Archer Dev Bridge — BASE commit",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $add=Invoke-ProcessCaptured -FileName $gitPath -Arguments "add -A" -WorkingDirectory $ProjectDir -TimeoutSeconds 120 -StageName "GIT_BASE"
    if($add.ExitCode -ne 0){
        [void](Invoke-ProcessCaptured -FileName $gitPath -Arguments "restore --staged ." -WorkingDirectory $ProjectDir -TimeoutSeconds 60)
        [System.Windows.Forms.MessageBox]::Show("Не удалось подготовить BASE commit.`r`n`r`n$($add.StdErr)","BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null;return $false
    }
    $stamp=Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $message="BASE before Archer task $stamp"
    $commit=Invoke-ProcessCaptured -FileName $gitPath -Arguments ("commit -m " + (Quote-ProcessArgument $message)) -WorkingDirectory $ProjectDir -TimeoutSeconds 180 -StageName "GIT_BASE"
    if($commit.ExitCode -ne 0){
        [void](Invoke-ProcessCaptured -FileName $gitPath -Arguments "restore --staged ." -WorkingDirectory $ProjectDir -TimeoutSeconds 60)
        [System.Windows.Forms.MessageBox]::Show("BASE commit не создан. Staging возвращён в исходное пустое состояние; файлы рабочей копии не удалялись.`r`n`r`n$($commit.StdErr)","BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null;return $false
    }
    $head=Invoke-ProcessCaptured -FileName $gitPath -Arguments "rev-parse --short HEAD" -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    $headText=$head.StdOut.Trim()
    Add-Log "Git BASE commit создан пользователем: $headText — $message"
    $roadmap=Confirm-RoadmapBaseCommit -Head $headText
    $roadmapText=""
    if($roadmap){
        $u=if(@($roadmap.Unlocked).Count -gt 0){(@($roadmap.Unlocked) -join ', ')}else{'нет зависимых задач'}
        $roadmapText="`r`n`r`nROADMAP: $($roadmap.TaskId) подтверждена как BASE.`r`nРазблокировано: $u"
    }
    [System.Windows.Forms.MessageBox]::Show("BASE commit создан.`r`n`r`nCommit: $headText`r`n$message$roadmapText","Archer Dev Bridge — BASE commit",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
    Update-SystemHealth | Out-Null
    return $true
}

function Restore-GitSelectedItem {
    param([string]$ProjectDir,$Item,$Owner)
    if($null -eq $Item){[System.Windows.Forms.MessageBox]::Show("Выберите файл в списке.","Git Restore")|Out-Null;return $false}
    $code=[string]$Item.Code
    if($Item.Kind -in @("UNTRACKED","ADDED","RENAMED","CONFLICT") -or ($code.Length -gt 0 -and $code[0] -ne ' ')){
        [System.Windows.Forms.MessageBox]::Show("Для этого типа изменения автоматическое восстановление отключено. Bridge не будет удалять новые файлы, затрагивать staged-состояние, rename или conflict.","Git Restore",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return $false
    }
    $ans=[System.Windows.Forms.MessageBox]::Show("Восстановить '$($Item.Path)' из текущего HEAD?`r`n`r`nЛокальные НЕЗАСТЕЙДЖЕННЫЕ изменения выбранного файла будут потеряны. Другие файлы не затрагиваются.","Archer Dev Bridge — Restore selected",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return $false}
    $gitPath=Resolve-AndPersistTool "git";$arg=Quote-ProcessArgument ([string]$Item.Path)
    $r=Invoke-ProcessCaptured -FileName $gitPath -Arguments ("restore --worktree -- " + $arg) -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_RESTORE"
    if($r.ExitCode -ne 0){[System.Windows.Forms.MessageBox]::Show("Не удалось восстановить файл.`r`n`r`n$($r.StdErr)","Git Restore",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null;return $false}
    Add-Log "Git Inspector: пользователь восстановил файл из HEAD: $($Item.Path)"
    Update-SystemHealth | Out-Null
    return $true
}

function Show-GitWorkingTreeDetails {
    $project=$txtProject.Text.Trim()
    if(-not $project -or -not(Test-Path -LiteralPath $project)){[System.Windows.Forms.MessageBox]::Show("Сначала выберите проект.","Git Inspector")|Out-Null;return}
    $f=New-Object System.Windows.Forms.Form
    $f.Text="Archer Dev Bridge — Git Inspector / Diff / BASE"
    $f.Size=New-Object System.Drawing.Size(1060,680)
    $f.StartPosition="CenterParent"
    $f.BackColor=[System.Drawing.Color]::FromArgb(15,21,29);$f.ForeColor=[System.Drawing.Color]::FromArgb(232,238,245)
    $head=New-Object System.Windows.Forms.Label
    $head.Location=New-Object System.Drawing.Point(16,14);$head.Size=New-Object System.Drawing.Size(1010,54);$f.Controls.Add($head)
    $grid=New-Object System.Windows.Forms.ListView
    $grid.Location=New-Object System.Drawing.Point(16,76);$grid.Size=New-Object System.Drawing.Size(1010,480)
    $grid.View=[System.Windows.Forms.View]::Details;$grid.FullRowSelect=$true;$grid.GridLines=$true;$grid.MultiSelect=$false
    [void]$grid.Columns.Add("CODE",70);[void]$grid.Columns.Add("TYPE",120);[void]$grid.Columns.Add("FILE",790);$f.Controls.Add($grid)
    $scriptBlockRefresh={
        $grid.Items.Clear();$d=Get-GitWorkingTreeDetails $project
        if($d.Dirty){$head.Text="Git исправен. Жёлтый статус вызван изменениями рабочей копии.`r`n$($d.Summary)";$head.ForeColor=[System.Drawing.Color]::FromArgb(255,193,7)}else{$head.Text="Git исправен. Рабочее дерево чистое.`r`nМожно запускать задачу при включённом строгом Clean Git.";$head.ForeColor=[System.Drawing.Color]::FromArgb(46,230,135)}
        foreach($it in @($d.Items)){$row=New-Object System.Windows.Forms.ListViewItem([string]$it.Code);[void]$row.SubItems.Add([string]$it.Kind);[void]$row.SubItems.Add([string]$it.Path);$row.Tag=$it;[void]$grid.Items.Add($row)}
        # BASE is an explicit human action, not merely a "dirty tree" action.
        # On a CLEAN ROADMAP boundary the same button confirms the current HEAD as BASE
        # without creating an empty commit, so it must remain clickable.
        $btnBase.Enabled=$true
        $btnBase.Text=if($d.Dirty){"СОЗДАТЬ BASE COMMIT"}else{"ПОДТВЕРДИТЬ BASE"}
        $btnDiff.Enabled=$grid.Items.Count -gt 0;$btnOpen.Enabled=$grid.Items.Count -gt 0;$btnRestore.Enabled=$grid.Items.Count -gt 0
    }
    $getSelected={if($grid.SelectedItems.Count -gt 0){return $grid.SelectedItems[0].Tag};return $null}
    $btnDiff=New-Object System.Windows.Forms.Button;$btnDiff.Text="СРАВНИТЬ";$btnDiff.Location=New-Object System.Drawing.Point(16,570);$btnDiff.Size=New-Object System.Drawing.Size(130,36);Style-ArcherButton $btnDiff;$btnDiff.Add_Click({$it=& $getSelected;Show-GitDiffWindow -ProjectDir $project -Item $it -Owner $f});$f.Controls.Add($btnDiff)
    $btnOpen=New-Object System.Windows.Forms.Button;$btnOpen.Text="ОТКРЫТЬ ФАЙЛ";$btnOpen.Location=New-Object System.Drawing.Point(156,570);$btnOpen.Size=New-Object System.Drawing.Size(145,36);Style-ArcherButton $btnOpen;$btnOpen.Add_Click({$it=& $getSelected;if($null -eq $it){[System.Windows.Forms.MessageBox]::Show("Выберите файл.")|Out-Null;return};$full=Join-Path $project ([string]$it.Path);if(Test-Path -LiteralPath $full){Start-Process -FilePath $full}else{[System.Windows.Forms.MessageBox]::Show("Файл сейчас отсутствует в рабочей копии.")|Out-Null}});$f.Controls.Add($btnOpen)
    $btnRestore=New-Object System.Windows.Forms.Button;$btnRestore.Text="ВОССТАНОВИТЬ";$btnRestore.Location=New-Object System.Drawing.Point(311,570);$btnRestore.Size=New-Object System.Drawing.Size(145,36);Style-ArcherButton $btnRestore;$btnRestore.Add_Click({$it=& $getSelected;if(Restore-GitSelectedItem -ProjectDir $project -Item $it -Owner $f){& $scriptBlockRefresh}});$f.Controls.Add($btnRestore)
    $btnBase=New-Object System.Windows.Forms.Button;$btnBase.Text="СОЗДАТЬ BASE COMMIT";$btnBase.Location=New-Object System.Drawing.Point(466,570);$btnBase.Size=New-Object System.Drawing.Size(190,36);Style-ArcherButton $btnBase;$btnBase.BackColor=[System.Drawing.Color]::FromArgb(135,82,0);$btnBase.Add_Click({if(New-GitBaselineCommit -ProjectDir $project -Owner $f){& $scriptBlockRefresh}});$f.Controls.Add($btnBase)
    $note=New-Object System.Windows.Forms.Label;$note.Location=New-Object System.Drawing.Point(16,616);$note.Size=New-Object System.Drawing.Size(810,32);$note.Text="Commit создаётся только по явному нажатию BASE. Bridge никогда не commit/push автоматически и не использует git reset --hard.";$note.ForeColor=[System.Drawing.Color]::FromArgb(190,205,220);$f.Controls.Add($note)
    $btn=New-Object System.Windows.Forms.Button;$btn.Text="ЗАКРЫТЬ";$btn.Location=New-Object System.Drawing.Point(896,570);$btn.Size=New-Object System.Drawing.Size(130,36);Style-ArcherButton $btn;$btn.Add_Click({$f.Close()});$f.Controls.Add($btn)
    $grid.Add_DoubleClick({$it=& $getSelected;if($it){Show-GitDiffWindow -ProjectDir $project -Item $it -Owner $f}})
    & $scriptBlockRefresh
    [void]$f.ShowDialog($form)
}

function Get-SafeTextFileContent {
    param([string]$Path, [int]$MaxChars = 12000)
    try {
        $fi = Get-Item $Path -ErrorAction Stop
        if ($fi.Length -gt 1048576) { return "[skipped: file larger than 1 MB]" }
        $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
        $allowed = @(".cs", ".md", ".txt", ".json", ".tscn", ".tres", ".godot", ".csproj", ".sln", ".xml", ".yml", ".yaml", ".toml", ".cfg", ".ini", ".props", ".targets", ".ps1", ".cmd")
        if ($allowed -notcontains $ext -and [System.IO.Path]::GetFileName($Path) -notin @("project.godot", ".gitignore", ".gitattributes", ".editorconfig")) {
            return "[skipped: non-text or unsupported extension]"
        }
        $text = Get-Content -Raw -Encoding UTF8 $Path -ErrorAction Stop
        if ($text.Length -gt $MaxChars) { return $text.Substring(0, $MaxChars) + "`r`n...[truncated]" }
        return $text
    }
    catch {
        return "[unable to read: $($_.Exception.Message)]"
    }
}

function Get-ProjectContextBundle {
    param([string]$ProjectDir)

    $parts = New-Object System.Collections.Generic.List[string]
    $instructionFiles = @("PROJECT_RULES.md", "ARCHITECTURE.md", "AGENTS.md", "PROJECT_CONTEXT.md")
    foreach ($name in $instructionFiles) {
        $path = Join-Path $ProjectDir $name
        if (Test-Path $path) {
            $content = Get-SafeTextFileContent -Path $path -MaxChars 30000
            $parts.Add("===== $name (repository) =====`r`n$content")
        }
    }

    if ($parts.Count -eq 0 -and (Test-Path $FallbackContextPath)) {
        $fallback = Get-Content -Raw -Encoding UTF8 $FallbackContextPath
        $parts.Add("===== PROJECT_CONTEXT.md (bridge fallback) =====`r`n$fallback")
    }

    $git = Get-GitBaseInfo $ProjectDir
    $parts.Add(@"
===== REPOSITORY BASE =====
Branch: $($git.Branch)
HEAD: $($git.Head)
Commit: $($git.Subject)
Working tree before task:
$($git.Status)
"@)

    $treeCmd = 'ls-files "*.cs" "*.tscn" "*.tres" "*.godot" "*.csproj" "*.md" "*.json"'
    $tree = Invoke-ProcessCaptured -FileName "git" -Arguments $treeCmd -WorkingDirectory $ProjectDir -TimeoutSeconds 30
    if ($tree.ExitCode -eq 0) {
        $lines = @($tree.StdOut -split "`r?`n" | Where-Object { $_ })
        if ($lines.Count -gt 300) { $lines = $lines[0..299] + "...[file list truncated]" }
        $parts.Add("===== RELEVANT TRACKED FILES =====`r`n" + ($lines -join "`r`n"))
    }

    $all = ($parts -join "`r`n`r`n")
    if ($all.Length -gt 100000) { $all = $all.Substring(0, 100000) + "`r`n...[context truncated by ArcherDevBridge]" }
    return $all
}

function Get-GitSnapshot {
    param([string]$ProjectDir)

    $status = Invoke-ProcessCaptured -FileName "git" -Arguments "status --short" -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_CHECK"
    # Compare against HEAD so staged + unstaged tracked changes are both reviewed.
    $stat = Invoke-ProcessCaptured -FileName "git" -Arguments "diff HEAD --stat" -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_CHECK"
    $diff = Invoke-ProcessCaptured -FileName "git" -Arguments "diff HEAD --no-ext-diff --unified=3" -WorkingDirectory $ProjectDir -TimeoutSeconds 120 -StageName "GIT_CHECK"
    $diffCheck = Invoke-ProcessCaptured -FileName "git" -Arguments "diff HEAD --check" -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_CHECK"
    $staged = Invoke-ProcessCaptured -FileName "git" -Arguments "diff --cached --name-status" -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_CHECK"
    $changedNames = Invoke-ProcessCaptured -FileName "git" -Arguments "diff HEAD --name-only" -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_CHECK"
    $untracked = Invoke-ProcessCaptured -FileName "git" -Arguments "ls-files --others --exclude-standard" -WorkingDirectory $ProjectDir -TimeoutSeconds 60 -StageName "GIT_CHECK"

    $diffText = $diff.StdOut
    if ($diffText.Length -gt 80000) { $diffText = $diffText.Substring(0, 80000) + "`r`n...[tracked diff truncated by ArcherDevBridge]" }

    $allChanged=@($changedNames.StdOut -split "`r?`n" | Where-Object { $_ }) + @($untracked.StdOut -split "`r?`n" | Where-Object { $_ })
    $sensitivePaths=@($allChanged | Where-Object { Test-SensitivePath ([string]$_) } | Select-Object -Unique)

    $untrackedReview = New-Object System.Collections.Generic.List[string]
    $totalChars = 0
    foreach ($rel in @($untracked.StdOut -split "`r?`n" | Where-Object { $_ })) {
        if ($totalChars -gt 50000) {
            $untrackedReview.Add("...[untracked review truncated]")
            break
        }
        $full = Join-Path $ProjectDir $rel
        if (Test-Path $full -PathType Leaf) {
            $content = Get-SafeTextFileContent -Path $full -MaxChars 10000
            $block = "===== UNTRACKED: $rel =====`r`n$content"
            $untrackedReview.Add($block)
            $totalChars += $block.Length
        }
    }

    return [pscustomobject]@{
        Status = $status.StdOut
        Stat = $stat.StdOut
        Diff = $diffText
        DiffCheckExit = $diffCheck.ExitCode
        DiffCheckOut = ($diffCheck.StdOut + $diffCheck.StdErr)
        Staged = $staged.StdOut
        SensitivePaths = $sensitivePaths
        Untracked = $untracked.StdOut
        UntrackedReview = ($untrackedReview -join "`r`n`r`n")
    }
}

function Invoke-ManualReleaseAcceptanceGate {
    param([string]$ProjectDir, [string]$RunDir)
    $reasons = New-Object System.Collections.Generic.List[string]
    $git = Get-GitSnapshot $ProjectDir
    if ($git.DiffCheckExit -ne 0) { $reasons.Add('git diff HEAD --check failed') }
    if ($git.Staged) { $reasons.Add('Git index contains staged changes') }
    if (@($git.SensitivePaths).Count -gt 0) { $reasons.Add('Sensitive File Guard: ' + ($git.SensitivePaths -join ', ')) }

    $package = $null
    $builds = Join-Path $ProjectDir 'Builds'
    if (Test-Path -LiteralPath $builds -PathType Container) {
        $candidates = @(Get-ChildItem -LiteralPath $builds -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'AmericasGame.exe')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'AmericasGame.pck')) } |
            Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -gt 0) { $package = $candidates[0].FullName }
    }
    if (-not $package) { $reasons.Add('No complete exported package with manifest/EXE/PCK was found under Builds') }

    $verifiedFiles = 0
    $manifestPath = ''
    if ($package) {
        $manifestPath = Join-Path $package 'manifest.json'
        try {
            $manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
            $boundary = [IO.Path]::GetFullPath($package) + [IO.Path]::DirectorySeparatorChar
            foreach ($f in @($manifest.files)) {
                if (-not $f.path) { continue }
                $full = [IO.Path]::GetFullPath((Join-Path $package ([string]$f.path)))
                if (-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)) { $reasons.Add('Manifest path escaped package: ' + [string]$f.path); continue }
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $reasons.Add('Manifest file missing: ' + [string]$f.path); continue }
                $item = Get-Item -LiteralPath $full
                if ($null -ne $f.bytes -and [int64]$f.bytes -ne [int64]$item.Length) { $reasons.Add('Manifest size mismatch: ' + [string]$f.path); continue }
                if ($f.sha256) {
                    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
                    if ($hash -ne ([string]$f.sha256).ToUpperInvariant()) { $reasons.Add('Manifest hash mismatch: ' + [string]$f.path); continue }
                }
                $verifiedFiles++
            }
            if (@($manifest.files).Count -eq 0) { $reasons.Add('Manifest contains no payload inventory') }
            $forbidden = @(Get-ChildItem -LiteralPath $package -Recurse -File | Where-Object { $_.Extension -in '.cs','.pdb','.key','.pem','.pfx','.log' -or $_.Name -in '.env','secrets.json','credentials.json' })
            if ($forbidden.Count -gt 0) { $reasons.Add('Forbidden/private/debug files found in package') }
        } catch { $reasons.Add('Manifest verification error: ' + $_.Exception.Message) }
    }

    $summary = @"
Archer Dev Bridge v$BridgeVersion manual release acceptance gate
Package: $package
Manifest: $manifestPath
Manifest payload files verified: $verifiedFiles
Git diff check exit: $($git.DiffCheckExit)
Git staged: $([bool]$git.Staged)
Sensitive paths: $(@($git.SensitivePaths).Count)
Result: $(if($reasons.Count -eq 0){'PASS'}else{'FAIL'})
Reasons:
$($reasons -join "`r`n")
"@
    Write-Utf8File (Join-Path $RunDir 'manual-release-gate.txt') $summary
    return [pscustomobject]@{ Pass=($reasons.Count -eq 0); Reasons=@($reasons); Git=$git; Package=$package; Manifest=$manifestPath; VerifiedFiles=$verifiedFiles; Summary=$summary }
}

function Confirm-ManualReleaseChecklist {
    param($Diagnostic)
    $message = @"
Перед принятием $($Diagnostic.TaskId) подтвердите, что ВРУЧНУЮ проверили экспортированный EXE:

1. Полный игровой цикл в экспортированном билде.
2. Save -> Exit -> новый запуск -> Continue.
3. Управление и потерю/возврат фокуса окна.
4. Звук: UI / combat / vehicle / ambience / mute-volume.
5. UI/HUD минимум в 1280x720, 1920x1080 и 2560x1440.

Нажимайте ДА только если эти пункты действительно проверены.
Bridge затем выполнит только Git + manifest/package safety gate; полный 312-test suite повторно не запускается.
"@
    $ans=[System.Windows.Forms.MessageBox]::Show($message,'Archer Dev Bridge — Manual Release Check',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    return ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Get-WatchdogSeconds {
    param([int]$FallbackSeconds=1800)
    try{if($null -ne $numWatchdog){return [Math]::Max(300,([int]$numWatchdog.Value*60))}}catch{}
    return $FallbackSeconds
}

function Invoke-DotNetBuild {
    param([string]$ProjectDir)
    $csproj = Get-CSharpProjectFile $ProjectDir
    if (-not $csproj) {
        return [pscustomobject]@{ ExitCode = 0; StdOut = "C# project file (*.csproj) not found; dotnet build skipped."; StdErr = ""; Skipped = $true }
    }
    $arg = 'build "' + $csproj + '" --nologo'
    $r = Invoke-ProcessCaptured -FileName "dotnet" -Arguments $arg -WorkingDirectory $ProjectDir -TimeoutSeconds (Get-WatchdogSeconds 1800) -StageName "DOTNET_BUILD"
    return [pscustomobject]@{ ExitCode=$r.ExitCode; StdOut=$r.StdOut; StdErr=$r.StdErr; Skipped=$false; Aborted=$r.Aborted; TimedOut=$r.TimedOut }
}

function Invoke-ProjectTests {
    param([string]$ProjectDir)
    $testProj = Get-TestProjectFile $ProjectDir
    if (-not $testProj) {
        return [pscustomobject]@{ ExitCode = 0; StdOut = "Tests project not found; project tests skipped."; StdErr = ""; Skipped = $true }
    }

    $content = ""
    try { $content = Get-Content -Raw -Encoding UTF8 $testProj } catch {}
    $isDotnetTest = ($content -match "Microsoft\.NET\.Test\.Sdk") -or ($content -match "<IsTestProject>\s*true\s*</IsTestProject>")
    if ($isDotnetTest) {
        $arg = 'test "' + $testProj + '" --nologo'
    } else {
        $arg = 'run --project "' + $testProj + '"'
    }
    $r = Invoke-ProcessCaptured -FileName "dotnet" -Arguments $arg -WorkingDirectory $ProjectDir -TimeoutSeconds (Get-WatchdogSeconds 1800) -StageName "TESTS"
    return [pscustomobject]@{ ExitCode=$r.ExitCode; StdOut=$r.StdOut; StdErr=$r.StdErr; Skipped=$false; Aborted=$r.Aborted; TimedOut=$r.TimedOut }
}

function Find-GodotExecutable {
    param([string]$ConfiguredPath)
    if ($ConfiguredPath -and (Test-Path $ConfiguredPath)) { return $ConfiguredPath }

    $known = @(
        "C:\Tools\Godot\godot.exe",
        "C:\Tools\Godot\Godot.exe"
    )
    foreach ($p in $known) { if (Test-Path $p) { return $p } }

    try {
        $cmd = Get-Command godot -ErrorAction Stop
        if ($cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }
    } catch {}

    try {
        $proc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "Godot*" -and $_.Path } | Select-Object -First 1
        if ($proc -and $proc.Path -and (Test-Path $proc.Path)) { return $proc.Path }
    } catch {}

    return ""
}

function Invoke-GodotEditorCheck {
    param([string]$ProjectDir, [string]$GodotExe)
    if (-not $GodotExe) { return [pscustomobject]@{ ExitCode = 0; StdOut = "Godot executable unavailable; editor check skipped."; StdErr = ""; Skipped = $true } }
    $arg = '--headless --path "' + $ProjectDir + '" --editor --quit'
    $r = Invoke-ProcessCaptured -FileName $GodotExe -Arguments $arg -WorkingDirectory $ProjectDir -TimeoutSeconds (Get-WatchdogSeconds 900) -StageName "GODOT_EDITOR"
    return [pscustomobject]@{ ExitCode=$r.ExitCode; StdOut=$r.StdOut; StdErr=$r.StdErr; Skipped=$false; Aborted=$r.Aborted; TimedOut=$r.TimedOut }
}

function Invoke-GodotClientSmoke {
    param([string]$ProjectDir, [string]$GodotExe)
    if (-not $GodotExe) { return [pscustomobject]@{ ExitCode = 0; StdOut = "Godot executable unavailable; client smoke-test skipped."; StdErr = ""; Skipped = $true } }
    $arg = '--headless --path "' + $ProjectDir + '" --quit-after 3'
    $r = Invoke-ProcessCaptured -FileName $GodotExe -Arguments $arg -WorkingDirectory $ProjectDir -TimeoutSeconds (Get-WatchdogSeconds 900) -StageName "GODOT_CLIENT"
    return [pscustomobject]@{ ExitCode=$r.ExitCode; StdOut=$r.StdOut; StdErr=$r.StdErr; Skipped=$false; Aborted=$r.Aborted; TimedOut=$r.TimedOut }
}

function Invoke-GodotServerSmoke {
    param([string]$ProjectDir, [string]$GodotExe)
    if (-not $GodotExe) { return [pscustomobject]@{ ExitCode = 0; StdOut = "Godot executable unavailable; server smoke-test skipped."; StdErr = ""; Skipped = $true } }
    $arg = '--headless --path "' + $ProjectDir + '" --server --quit-after 3'
    $r = Invoke-ProcessCaptured -FileName $GodotExe -Arguments $arg -WorkingDirectory $ProjectDir -TimeoutSeconds (Get-WatchdogSeconds 900) -StageName "GODOT_SERVER"
    return [pscustomobject]@{ ExitCode=$r.ExitCode; StdOut=$r.StdOut; StdErr=$r.StdErr; Skipped=$false; Aborted=$r.Aborted; TimedOut=$r.TimedOut }
}

function Build-CodexPrompt {
    param([string]$UserTask, [string]$PlannerSpec, [string]$Context, [string]$OperatorMode="ONE_CODEX")
    $orchestration = if($OperatorMode -eq "AI_TEAM") {
@"
MANDATORY ORCHESTRATION MODE: ASTRA + AI TEAM
1. Before code edits, delegate repository mapping to subagent `archer_explorer` when available.
2. Delegate implementation/fixes to `archer_worker` when available. Keep scope narrow.
3. After implementation, delegate an independent read-only review to `archer_reviewer`.
4. Use the reviewer findings to decide whether one focused correction is needed before returning control to Archer Dev Bridge.
5. Do not claim tests passed unless you actually ran them. Archer Dev Bridge will independently run the final Quality Gate after you finish.
"@
    } else {
@"
MANDATORY ORCHESTRATION MODE: ASTRA + ONE CODEX
1. You are the sole coding agent for this task. Do NOT spawn, delegate to, or invoke subagents.
2. Personally inspect the repository and mandatory architecture documents before editing.
3. Personally plan the smallest coherent implementation, implement it, run relevant safe checks, and self-review the result.
4. Keep the requested roadmap scope narrow; do not add future-stage systems.
5. Do not claim tests passed unless you actually ran them. Archer Dev Bridge will independently run the final Quality Gate after you finish.
6. In the final marker always report `SUBAGENTS_USED: NONE`.
"@
    }
    return @"
You are ASTRA OPERATOR, the lead orchestration agent for the selected Godot 4 .NET/C# repository.

$orchestration

MANDATORY SAFETY / WORKFLOW RULES:
- Work only inside the selected repository.
- PROJECT_RULES.md, ARCHITECTURE.md and AGENTS.md are mandatory when present.
- Do NOT commit, push, reset, rebase, clean, checkout unrelated branches, or delete unrelated user files.
- Do NOT use --dangerously-bypass-approvals-and-sandbox or equivalent behavior.
- Preserve multiplayer-ready server-authoritative boundaries.
- Client/UI/presentation must not mutate authoritative state directly.
- Inspect existing code before editing.
- Prefer the smallest coherent change that fully solves the task.
- Do not silently introduce systems outside the requested roadmap stage.
- Leave the repository uncommitted for human review.
- Do not stage files (`git add`) or modify credential/secret material (.env, *.key, *.pem, *.pfx, secrets.json, credentials.json).

FINAL RESPONSE FORMAT (mandatory):
OPERATOR_RESULT: READY_FOR_GATE, NEEDS_REVIEW, or BLOCKED
OPERATOR_REVIEW: PASS, NEEDS_FIX, or NEEDS_REVIEW
SOURCE_STATUS: PASS, NEEDS_FIX, or UNKNOWN
RELEASE_STATUS: READY, BLOCKED_ENVIRONMENT, BLOCKED, NEEDS_REVIEW, or UNKNOWN
BLOCKER: short machine-readable blocker code or NONE
REPAIR_SOURCE: TRUE or FALSE
SUBAGENTS_USED: comma-separated names or NONE
FILES_CHANGED: concise list
CHECKS_RUN: concise list with real results only
RISKS: concise remaining risks or NONE
SUMMARY: concise behavior change

Classification rules:
- NEEDS_FIX means a concrete source/project defect was found that can be repaired in the repository.
- NEEDS_REVIEW means evidence is insufficient or a human/reviewer decision is needed; it MUST NOT be used as a synonym for NEEDS_FIX.
- For toolchain/network/package/publish-environment failures (for example NU1301 while source checks pass), use SOURCE_STATUS: PASS, RELEASE_STATUS: BLOCKED_ENVIRONMENT, REPAIR_SOURCE: FALSE and a concrete BLOCKER code.
- BLOCKED is not itself permission to modify source. Set REPAIR_SOURCE: TRUE only when a concrete source defect was identified.

PROJECT / REPOSITORY CONTEXT:
$Context

USER REQUEST:
$UserTask

ARCHITECT SPEC / LEGACY PLANNER SPEC:
$PlannerSpec
"@
}

function Invoke-CodexTask {
    param([string]$ProjectDir,[string]$Prompt,[string]$RunDir,[string]$Label,[string]$Model,[string]$ReasoningEffort,[string]$Sandbox="workspace-write",[int]$TimeoutSeconds=0)
    $last=Join-Path $RunDir ($Label+"-codex-final.txt"); $hasGit=Test-Path (Join-Path $ProjectDir ".git")
    $args='exec --cd "'+$ProjectDir+'" --sandbox '+$Sandbox+' --output-last-message "'+$last+'" '
    if($Model){$args+='-m "'+$Model+'" '}
    if($ReasoningEffort){$args+='-c "model_reasoning_effort=' + "'" + $ReasoningEffort + "'" + '" '}
    if(-not $hasGit){$args+='--skip-git-repo-check '}; $args+='-'
    $codexExe = Resolve-AndPersistTool "codex"
    $displayExe = if($codexExe){$codexExe}else{"codex"}
    Write-Utf8File (Join-Path $RunDir ($Label+"-codex-command.txt")) ("Executable: $displayExe`r`nArguments: $args`r`nWorkingDirectory: $ProjectDir`r`nSandbox: $Sandbox`r`nPrompt source: UTF-8 raw bytes via redirected STDIN")
    Add-Log "Запуск Codex ($Label): model=$Model, reasoning=$ReasoningEffort, sandbox=$Sandbox"
    $watchdog = if($TimeoutSeconds -gt 0){$TimeoutSeconds}else{Get-WatchdogSeconds 1800}
    $r=Invoke-ProcessCaptured -FileName "codex" -Arguments $args -WorkingDirectory $ProjectDir -StdInText $Prompt -TimeoutSeconds $watchdog -StageName ("CODEX:"+$Label)
    Write-Utf8File (Join-Path $RunDir ($Label+"-codex-stdout.txt")) ([string]$r.StdOut)
    Write-Utf8File (Join-Path $RunDir ($Label+"-codex-stderr.txt")) ([string]$r.StdErr)
    Write-Utf8File (Join-Path $RunDir ($Label+"-codex-exit.txt")) ("ExitCode: $($r.ExitCode)`r`nAborted: $($r.Aborted)`r`nTimedOut: $($r.TimedOut)`r`nDurationSeconds: $($r.DurationSeconds)`r`nFinished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    if($r.StdOut){Add-Log ($r.StdOut.Trim())}; if($r.StdErr){Add-Log ("Codex stderr: "+$r.StdErr.Trim())}
    $final=""; if(Test-Path $last){$final=Get-Content -Raw -Encoding UTF8 $last}else{Write-Utf8File $last ""}
    return [pscustomobject]@{ExitCode=$r.ExitCode;StdOut=$r.StdOut;StdErr=$r.StdErr;Final=$final;CommandFile=(Join-Path $RunDir ($Label+"-codex-command.txt"));Aborted=$r.Aborted;TimedOut=$r.TimedOut;DurationSeconds=$r.DurationSeconds}
}

function Get-VerificationStepState {
    param($Result, [bool]$Required = $true)
    if ($null -eq $Result) { return $(if($Required){"NOT_AVAILABLE"}else{"SKIPPED"}) }
    if ($Result.Skipped) { return $(if($Required){"NOT_AVAILABLE"}else{"SKIPPED"}) }
    if ($Result.ExitCode -eq 0) { return "PASS" }
    return "FAIL"
}

function Invoke-FullVerification {
    param([string]$ProjectDir, [string]$GodotExe, [string]$RunDir, [string]$Prefix)

    Add-Log "=== Verification: dotnet build ==="
    $build = Invoke-DotNetBuild $ProjectDir
    $buildState = Get-VerificationStepState $build $true
    Add-Log "dotnet build state=$buildState exit=$($build.ExitCode)"
    if ($build.StdOut) { Add-Log $build.StdOut.Trim() }
    if ($build.StdErr) { Add-Log $build.StdErr.Trim() }
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-dotnet-build.txt")) ($build.StdOut + "`r`n" + $build.StdErr)

    $testsRequired = [bool]$chkTests.Checked
    $tests = [pscustomobject]@{ ExitCode=0; StdOut="Project tests disabled in UI."; StdErr=""; Skipped=$true }
    if ($testsRequired) {
        Add-Log "=== Verification: project tests ==="
        $tests = Invoke-ProjectTests $ProjectDir
        if ($tests.StdOut) { Add-Log $tests.StdOut.Trim() }
        if ($tests.StdErr) { Add-Log $tests.StdErr.Trim() }
    }
    $testsState = Get-VerificationStepState $tests $testsRequired
    Add-Log "tests state=$testsState exit=$($tests.ExitCode)"
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-tests.txt")) ($tests.StdOut + "`r`n" + $tests.StdErr)

    $godotRequired = [bool]$chkGodotSmoke.Checked
    $editor = [pscustomobject]@{ ExitCode=0; StdOut="Godot checks disabled in UI."; StdErr=""; Skipped=$true }
    $client = [pscustomobject]@{ ExitCode=0; StdOut="Godot checks disabled in UI."; StdErr=""; Skipped=$true }
    $server = [pscustomobject]@{ ExitCode=0; StdOut="Godot checks disabled in UI."; StdErr=""; Skipped=$true }
    if ($godotRequired) {
        Add-Log "=== Verification: Godot editor check ==="
        $editor = Invoke-GodotEditorCheck $ProjectDir $GodotExe
        if ($editor.StdOut) { Add-Log $editor.StdOut.Trim() }; if ($editor.StdErr) { Add-Log $editor.StdErr.Trim() }
        Add-Log "=== Verification: Godot client smoke ==="
        $client = Invoke-GodotClientSmoke $ProjectDir $GodotExe
        if ($client.StdOut) { Add-Log $client.StdOut.Trim() }; if ($client.StdErr) { Add-Log $client.StdErr.Trim() }
        Add-Log "=== Verification: Godot --server smoke ==="
        $server = Invoke-GodotServerSmoke $ProjectDir $GodotExe
        if ($server.StdOut) { Add-Log $server.StdOut.Trim() }; if ($server.StdErr) { Add-Log $server.StdErr.Trim() }
    }
    $editorState = Get-VerificationStepState $editor $godotRequired
    $clientState = Get-VerificationStepState $client $godotRequired
    $serverState = Get-VerificationStepState $server $godotRequired
    Add-Log "Godot states: editor=$editorState client=$clientState server=$serverState"

    Write-Utf8File (Join-Path $RunDir ($Prefix + "-godot-editor.txt")) ($editor.StdOut + "`r`n" + $editor.StdErr)
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-godot-client.txt")) ($client.StdOut + "`r`n" + $client.StdErr)
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-godot-server.txt")) ($server.StdOut + "`r`n" + $server.StdErr)

    $git = Get-GitSnapshot $ProjectDir
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-git-status.txt")) $git.Status
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-git-diff-stat.txt")) $git.Stat
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-git-diff.txt")) $git.Diff
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-git-untracked.txt")) $git.UntrackedReview
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-git-diff-check.txt")) $git.DiffCheckOut
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-git-staged.txt")) $git.Staged
    Write-Utf8File (Join-Path $RunDir ($Prefix + "-sensitive-files.txt")) ($git.SensitivePaths -join "`r`n")
    $gitState = if ($git.DiffCheckExit -eq 0) { "PASS" } else { "FAIL" }

    $states = @($buildState,$testsState,$editorState,$clientState,$serverState,$gitState)
    $blocking = New-Object System.Collections.Generic.List[string]
    if ($buildState -in @("FAIL","NOT_AVAILABLE")) { $blocking.Add("dotnet build=$buildState") }
    if ($testsRequired -and $testsState -in @("FAIL","NOT_AVAILABLE")) { $blocking.Add("tests=$testsState") }
    if ($godotRequired -and $editorState -in @("FAIL","NOT_AVAILABLE")) { $blocking.Add("Godot editor=$editorState") }
    if ($godotRequired -and $clientState -in @("FAIL","NOT_AVAILABLE")) { $blocking.Add("Godot client=$clientState") }
    if ($godotRequired -and $serverState -in @("FAIL","NOT_AVAILABLE")) { $blocking.Add("Godot server=$serverState") }
    if ($gitState -eq "FAIL") { $blocking.Add("git diff HEAD --check=FAIL") }
    if ($git.Staged) { $blocking.Add("Git index содержит staged changes — Bridge/Codex не должен stage изменения") }
    if(@($git.SensitivePaths).Count -gt 0){$blocking.Add("Sensitive File Guard: "+($git.SensitivePaths -join ", "))}

    return [pscustomobject]@{
        Pass = ($blocking.Count -eq 0)
        BlockingReasons = @($blocking)
        Build = $build; BuildState=$buildState
        Tests = $tests; TestsState=$testsState
        GodotEditor = $editor; GodotEditorState=$editorState
        GodotClient = $client; GodotClientState=$clientState
        GodotServer = $server; GodotServerState=$serverState
        Git = $git; GitState=$gitState
    }
}

function Get-VerificationSummary {
    param($Verification)
    return @"
DOTNET BUILD: $($Verification.BuildState), exit=$($Verification.Build.ExitCode), skipped=$($Verification.Build.Skipped)
$($Verification.Build.StdOut)
$($Verification.Build.StdErr)

PROJECT TESTS: $($Verification.TestsState), exit=$($Verification.Tests.ExitCode), skipped=$($Verification.Tests.Skipped)
$($Verification.Tests.StdOut)
$($Verification.Tests.StdErr)

GODOT EDITOR CHECK: $($Verification.GodotEditorState), exit=$($Verification.GodotEditor.ExitCode), skipped=$($Verification.GodotEditor.Skipped)
$($Verification.GodotEditor.StdOut)
$($Verification.GodotEditor.StdErr)

GODOT CLIENT SMOKE: $($Verification.GodotClientState), exit=$($Verification.GodotClient.ExitCode), skipped=$($Verification.GodotClient.Skipped)
$($Verification.GodotClient.StdOut)
$($Verification.GodotClient.StdErr)

GODOT SERVER SMOKE: $($Verification.GodotServerState), exit=$($Verification.GodotServer.ExitCode), skipped=$($Verification.GodotServer.Skipped)
$($Verification.GodotServer.StdOut)
$($Verification.GodotServer.StdErr)

GIT DIFF CHECK: $($Verification.GitState), exit=$($Verification.Git.DiffCheckExit)
$($Verification.Git.DiffCheckOut)

GIT STAGED CHANGES (must be empty):
$($Verification.Git.Staged)

BLOCKING REASONS:
$($Verification.BlockingReasons -join "`r`n")
"@
}

function Get-ReviewPass {
    param([string]$Review)
    if (-not $Review) { return $true }
    if ($Review -match "(?im)^\s*RESULT\s*:\s*PASS\b") { return $true }
    if ($Review -match "(?im)^\s*RESULT\s*:\s*NEEDS_FIX\b") { return $false }
    return $false
}

function Save-LastGate {
    param([string]$ProjectDir, [bool]$Pass, [string]$RunDir, [string]$Reason, [string]$Status="", [string]$Stage="")
    if(-not $Status){$Status=if($Pass){"DONE"}else{"FAIL"}}
    $obj = [ordered]@{
        bridgeVersion = $BridgeVersion
        runSchema = $RunSchemaVersion
        runKind = "task"
        project = $ProjectDir
        pass = $Pass
        status = $Status
        stage = $Stage
        runDir = $RunDir
        reason = $Reason
        timestamp = (Get-Date).ToString("o")
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $GateStatePath
}

function Write-RunState {
    param([string]$RunDir,[string]$Task,[string]$TaskId,[string]$Stage,[string]$Status,[string]$Reason="",[string]$Project="",[string]$RunKind="task",[string]$RetryOf="")
    if (-not $RunDir) { return }
    try {
        $existingStarted = ""
        $statePath=Join-Path $RunDir "run-state.json"
        if(Test-Path $statePath){try{$old=Get-Content -Raw -Encoding UTF8 $statePath|ConvertFrom-Json;$existingStarted=[string]$old.started}catch{}}
        if(-not $existingStarted){$existingStarted=(Get-Date).ToString("o")}
        $obj = [ordered]@{
            schemaVersion = $RunSchemaVersion
            bridgeVersion = $BridgeVersion
            runKind = $RunKind
            taskId = $TaskId
            task = $Task
            project = $Project
            stage = $Stage
            status = $Status
            reason = $Reason
            retryOf = $RetryOf
            parentTaskId = [string]$script:CurrentParentTaskId
            taskType = [string]$script:CurrentTaskType
            inheritedWorkingTree = [bool]$script:CurrentInheritedWorkingTree
            runDir = $RunDir
            pid = $PID
            started = $existingStarted
            updated = (Get-Date).ToString("o")
        }
        $obj | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $statePath
    } catch {}
}

function Get-LatestRunDiagnostic {
    $result = [ordered]@{ State="yellow"; HasData=$false; Pass=$null; Status="NO_DATA"; Stage="NO_DATA"; Reason="Нет современного task-run"; RunDir=""; Detail="После перехода на run schema v2 ещё не было task-run"; ArtifactSummary=""; Task=""; TaskId=""; Project=""; LegacyCount=0 }
    try {
        $legacy=0
        $modern=@()
        if(Test-Path $RunsDir){
            foreach($dir in @(Get-ChildItem -LiteralPath $RunsDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)){
                $sp=Join-Path $dir.FullName "run-state.json"
                if(-not (Test-Path $sp)){ if($dir.Name -match "-(diagnose|verify|plan)$"){continue}; $legacy++; continue }
                try{
                    $rs=Get-Content -Raw -Encoding UTF8 $sp|ConvertFrom-Json
                    $schema=0; if($null -ne $rs.schemaVersion){$schema=[int]$rs.schemaVersion}
                    if($schema -ge $RunSchemaVersion){if([string]$rs.runKind -eq "task"){$modern += [pscustomobject]@{Dir=$dir;State=$rs}}else{continue}}else{$legacy++}
                }catch{$legacy++}
            }
        }
        $result.LegacyCount=$legacy
        if($modern.Count -eq 0){
            if($legacy -gt 0){$result.Detail="Современных task-run нет. Legacy/history: $legacy (не влияет на готовность системы)."}
            return [pscustomobject]$result
        }
        $entry=$modern[0]; $rs=$entry.State
        $result.HasData=$true; $result.RunDir=$entry.Dir.FullName; $result.Stage=[string]$rs.stage; $result.Status=[string]$rs.status; $result.Reason=[string]$rs.reason; $result.Task=[string]$rs.task; $result.TaskId=[string]$rs.taskId; $result.Project=[string]$rs.project
        $result.Pass=($result.Status -in @("PASS","DONE"))
        $result.State=if($result.Pass){"green"}elseif($result.Status -in @("ABORTED","INTERRUPTED","BLOCKED","BLOCKED_ENVIRONMENT","NEEDS_REVIEW")){"yellow"}else{"red"}
        $candidates=$(if($result.Status -eq "NEEDS_REVIEW"){@((Join-Path $result.RunDir "needs-review-summary.txt"),(Join-Path $result.RunDir "gate-summary.txt"),(Join-Path $result.RunDir "main-codex-stderr.txt"))}else{@((Join-Path $result.RunDir "failure-summary.txt"),(Join-Path $result.RunDir "main-codex-stderr.txt"),(Join-Path $result.RunDir "main-codex-stdout.txt"),(Join-Path $result.RunDir "gate-summary.txt"))})
        foreach($fp in $candidates){if(Test-Path $fp){try{$txt=(Get-Content -Raw -Encoding UTF8 $fp).Trim();if($txt){$result.ArtifactSummary=$txt;break}}catch{}}}
        $result.Detail="Последний современный цикл: $($result.Status), этап $($result.Stage). $($result.Reason)"
        return [pscustomobject]$result
    } catch {
        $result.State="yellow"; $result.Status="READ_ERROR"; $result.Stage="READ_ERROR"; $result.Reason=$_.Exception.Message; $result.Detail="Не удалось прочитать историю run"
        return [pscustomobject]$result
    }
}


function Get-SelectedQueueTaskInfo {
    try {
        if ($null -eq $lstQueue -or $lstQueue.SelectedItems.Count -eq 0) { return $null }
        $it=$lstQueue.SelectedItems[0]
        return [pscustomobject]@{
            Item=$it
            Id=[string]$it.Text
            Status=[string]$it.SubItems[1].Text
            Task=[string]$it.SubItems[2].Text
            Meta=(Get-QueueItemMeta $it)
        }
    } catch { return $null }
}

function Get-LatestFailedRunForQueueTask {
    param([string]$TaskId,[string]$Task)
    try {
        if(-not(Test-Path $RunsDir)){return $null}
        foreach($dir in @(Get-ChildItem -LiteralPath $RunsDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)){
            $sp=Join-Path $dir.FullName "run-state.json"
            if(-not(Test-Path $sp)){continue}
            try {
                $rs=Get-Content -Raw -Encoding UTF8 $sp | ConvertFrom-Json
                $schema=0;if($null -ne $rs.schemaVersion){$schema=[int]$rs.schemaVersion}
                if($schema -lt $RunSchemaVersion -or [string]$rs.runKind -ne "task"){continue}
                $status=[string]$rs.status
                if($status -in @("PASS","DONE","RUNNING")){continue}
                $id=[string]$rs.taskId;$rt=[string]$rs.task
                if(($TaskId -and $id -eq $TaskId) -or ($Task -and $rt -eq $Task)){
                    return [pscustomobject]@{RunDir=$dir.FullName;TaskId=$id;Task=$rt;Stage=[string]$rs.stage;Status=$status;Reason=[string]$rs.reason;Project=[string]$rs.project}
                }
            } catch {}
        }
    } catch {}
    return $null
}

function Update-RetryButtonState {
    if($null -eq $btnRetryStage){return}
    if($script:IsBusy){$btnRetryStage.Enabled=$false;return}
    $q=Get-SelectedQueueTaskInfo
    if($q -and $q.Status -in @("FAIL","BLOCKED","BLOCKED_ENVIRONMENT","INTERRUPTED","ABORTED","NEEDS_REVIEW","REVIEW_NEEDS_FIX")){
        $btnRetryStage.Text="ПОВТОРИТЬ ЗАДАЧУ"
        $btnRetryStage.Enabled=$true
        return
    }
    $btnRetryStage.Text="ПОВТОРИТЬ ЭТАП"
    try{$d=Get-LatestRunDiagnostic;$btnRetryStage.Enabled=($d.HasData -and -not $d.Pass)}catch{$btnRetryStage.Enabled=$false}
}

function Retry-SelectedQueueTask {
    if(-not (Assert-SelfDestructCancelled)){return}
    $q=Get-SelectedQueueTaskInfo
    if(-not $q -or $q.Status -notin @("FAIL","BLOCKED","BLOCKED_ENVIRONMENT","INTERRUPTED","ABORTED","NEEDS_REVIEW","REVIEW_NEEDS_FIX")){
        Retry-LastFailedStage
        return
    }
    $source=Get-LatestFailedRunForQueueTask -TaskId $q.Id -Task $q.Task
    if($source -and ($source.Status -eq "SAFETY_STOP" -or $source.Stage -eq "SAFETY_STOP")){
        [System.Windows.Forms.MessageBox]::Show("После SAFETY STOP повтор заблокирован до ручной проверки Git.")|Out-Null
        return
    }
    $project=$txtProject.Text.Trim()
    $dirty=""
    try{$gd=Get-GitWorkingTreeDetails $project;if($gd.Dirty){$dirty="`r`n`r`nGit сейчас DIRTY: $($gd.Summary)`r`nДля retry выбранной $($q.Id) это допускается: Bridge сохранит существующие изменения и не будет делать reset/clean."}}catch{}
    $msg="Повторить задачу $($q.Id) поверх незавершённых изменений предыдущей попытки?`r`n`r`nCodex получит указание сначала проверить уже сделанную работу, сохранить корректные изменения и завершить только эту задачу.$dirty"
    $ans=[System.Windows.Forms.MessageBox]::Show($msg,"Archer Dev Bridge — Retry Task",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
    $q.Item.SubItems[1].Text="RETRY";Save-TaskQueue;Update-RetryButtonState;[System.Windows.Forms.Application]::DoEvents()
    $retryNote=@"
RETRY / CONTINUE SAME TASK:
The working tree contains unfinished changes from the previous attempt of this same task. Treat them as in-progress work belonging to $($q.Id). Inspect and preserve valid changes. Do NOT reset, clean, discard, or overwrite correct work just to start from scratch. Complete the requested scope, then run the full verification gate.

ORIGINAL TASK:
$($q.Task)
"@
    $retryId=$q.Id+"R"+(Get-Date -Format "HHmmss")
    $retryOf=$(if($source){$source.RunDir}elseif($q.Meta -and $q.Meta.parentRunDir){[string]$q.Meta.parentRunDir}else{""})
    $lineageParent=$(if($q.Meta -and $q.Meta.parentTaskId){[string]$q.Meta.parentTaskId}else{$q.Id})
    $lineageType=$(if($q.Meta -and $q.Meta.taskType -eq "TARGETED_REPAIR"){"TARGETED_REPAIR"}else{"RETRY"})
    try {
        Run-DevelopmentCycle -TaskOverride $retryNote -TaskId $retryId -AllowDirtyStart $true -RetryOf $retryOf -ParentTaskId $lineageParent -TaskType $lineageType -InheritedWorkingTree $true
        $status=if($script:LastCycleStatus){$script:LastCycleStatus}else{if($script:LastCyclePass){"DONE"}else{"FAIL"}}
        $q.Item.SubItems[1].Text=$status
        Save-TaskQueue
    } finally {
        Force-UiIdle -Reason "selected task retry finished"
        try{[void](Update-SystemHealth)}catch{}
        Update-RetryButtonState
    }
}


function Set-QueueTaskStatusById {
    param([string]$TaskId,[string]$Status)
    if(-not $TaskId -or $null -eq $lstQueue){return}
    foreach($it in $lstQueue.Items){
        if([string]$it.Text -eq $TaskId){$it.SubItems[1].Text=$Status;Save-TaskQueue;break}
    }
}

# 0.6.13: retry run IDs (for example T020R091856) are not queue IDs.
# Resolve an accepted retry back to its canonical ROADMAP row before changing status.
function Resolve-QueueTaskIdForDiagnostic {
    param($Diagnostic)
    if($null -eq $Diagnostic){return ''}
    $candidates=New-Object System.Collections.Generic.List[string]
    try {
        $tid=[string]$Diagnostic.TaskId
        if($tid){$candidates.Add($tid)}
        $statePath=Join-Path ([string]$Diagnostic.RunDir) 'run-state.json'
        if(Test-Path -LiteralPath $statePath){
            $rs=Get-Content -Raw -Encoding UTF8 $statePath|ConvertFrom-Json
            $parent=[string]$rs.parentTaskId
            if($parent -and -not $candidates.Contains($parent)){$candidates.Add($parent)}
        }
        if($tid -match '^(T[0-9]+)R[0-9]{6}$'){
            $root=[string]$Matches[1]
            if($root -and -not $candidates.Contains($root)){$candidates.Add($root)}
        }
    } catch {}
    foreach($candidate in $candidates){
        if($null -ne (Find-QueueItemById $candidate)){return $candidate}
    }
    return ''
}

function Set-RoadmapDoneWaitBaseForDiagnostic {
    param($Diagnostic,[string]$Reason='Manual Gate accepted')
    if($null -eq $Diagnostic -or $null -eq $lstQueue){return $false}
    $queueId=Resolve-QueueTaskIdForDiagnostic $Diagnostic
    if(-not $queueId){return $false}
    $item=Find-QueueItemById $queueId
    if($null -eq $item){return $false}
    $meta=Get-QueueItemMeta $item
    if([bool]$meta.baseConfirmed){
        $item.SubItems[1].Text='DONE'
    } else {
        $item.SubItems[1].Text='DONE_WAIT_BASE'
        $meta.baseConfirmed=$false
    }
    $item.Tag=$meta
    Save-TaskQueue
    Add-Log ("ROADMAP MANUAL GATE: {0} -> {1}. {2}" -f $queueId,[string]$item.SubItems[1].Text,$Reason)
    return $true
}

function Promote-LatestManualAcceptedRoadmapState {
    try {
        $d=Get-LatestRunDiagnostic
        if(-not $d.HasData -or $d.Status -notin @('DONE','PASS') -or $d.Stage -ne 'MANUAL_RELEASE_ACCEPTED'){return}
        $queueId=Resolve-QueueTaskIdForDiagnostic $d
        if(-not $queueId){return}
        $item=Find-QueueItemById $queueId
        if($null -eq $item){return}
        $meta=Get-QueueItemMeta $item
        if([bool]$meta.baseConfirmed){return}
        if([string]$item.SubItems[1].Text -ne 'DONE_WAIT_BASE'){
            if(Set-RoadmapDoneWaitBaseForDiagnostic -Diagnostic $d -Reason '0.6.13 startup reconcile of an already accepted 0.6.12 Manual Release Gate'){
                Add-Log ("0.6.13 migration: accepted retry {0} reconciled to ROADMAP {1} = DONE_WAIT_BASE. Повтор task не требуется." -f $d.TaskId,$queueId)
            }
        }
    } catch { Add-Log "Manual Gate ROADMAP reconcile warning: $($_.Exception.Message)" }
}

function Test-VerifiedTimeoutGateText {
    param([string]$GateText)
    if(-not $GateText){return $false}
    $checks=@(
        'Codex exit:\s*-2',
        'Build:\s*PASS',
        'Tests:\s*PASS',
        'Godot editor:\s*PASS',
        'Godot client:\s*PASS',
        'Godot server:\s*PASS',
        'Git diff check:\s*PASS',
        'Safety stop:\s*False'
    )
    foreach($pat in $checks){if($GateText -notmatch $pat){return $false}}
    return $true
}

function Promote-LatestVerifiedTimeoutRun {
    try {
        $d=Get-LatestRunDiagnostic
        if(-not $d.HasData -or $d.Status -ne 'FAIL'){return}
        $gatePath=Join-Path $d.RunDir 'gate-summary.txt'
        if(-not(Test-Path $gatePath)){return}
        $gate=Get-Content -Raw -Encoding UTF8 $gatePath
        $stderrPath=Join-Path $d.RunDir 'main-codex-stderr.txt'
        $stderr=if(Test-Path $stderrPath){Get-Content -Raw -Encoding UTF8 $stderrPath}else{''}
        if((Test-VerifiedTimeoutGateText $gate) -and $stderr -match '(?i)Watchdog|тайм-аут'){
            $reason='Codex watchdog timeout; local Build/Tests/Godot/Git verification PASS. Требуется ручное принятие или review-only.'
            Write-RunState -RunDir $d.RunDir -Task $d.Task -TaskId $d.TaskId -Stage 'CODEX_TIMEOUT_VERIFIED' -Status 'NEEDS_REVIEW' -Reason $reason -Project $d.Project
            Save-LastGate -ProjectDir $d.Project -Pass $false -RunDir $d.RunDir -Reason $reason -Status 'NEEDS_REVIEW' -Stage 'CODEX_TIMEOUT_VERIFIED'
            Write-Utf8File (Join-Path $d.RunDir 'verified-timeout.txt') ("Promoted by ArcherDevBridge $BridgeVersion at $(Get-Date -Format s)`r`n$reason")
            Add-Log "История: последний watchdog FAIL переклассифицирован в NEEDS_REVIEW, потому что локальный gate прошёл полностью."
        }
    } catch { Add-Log "Verified-timeout migration warning: $($_.Exception.Message)" }
}

function Promote-LatestStructuredManualReviewRun {
    try {
        $d=Get-LatestRunDiagnostic
        if(-not $d.HasData -or $d.Status -notin @('FAIL','BLOCKED','BLOCKED_ENVIRONMENT')){return}
        $finalPath=Join-Path $d.RunDir 'main-codex-final.txt'
        if(-not(Test-Path -LiteralPath $finalPath)){return}
        $text=Get-Content -Raw -Encoding UTF8 $finalPath
        $decision=Get-OperatorDecision $text
        if(-not $decision.ManualReleaseReview){return}
        if($decision.SourceStatus -ne 'PASS' -or ($null -ne $decision.RepairSource -and [bool]$decision.RepairSource)){return}
        $reason="Manual release verification required: $($decision.Blocker). Structured Astra final markers supersede stale historical environment evidence."
        Write-RunState -RunDir $d.RunDir -Task $d.Task -TaskId $d.TaskId -Stage 'WAITING_MANUAL_RELEASE_CHECK' -Status 'NEEDS_REVIEW' -Reason $reason -Project $d.Project
        Save-LastGate -ProjectDir $d.Project -Pass $false -RunDir $d.RunDir -Reason $reason -Status 'NEEDS_REVIEW' -Stage 'WAITING_MANUAL_RELEASE_CHECK'
        Write-Utf8File (Join-Path $d.RunDir 'structured-manual-review-promotion.txt') ("Promoted by ArcherDevBridge $BridgeVersion at $(Get-Date -Format s)`r`nBlocker: $($decision.Blocker)`r`nSourceStatus: $($decision.SourceStatus)`r`n$reason")
        Set-QueueTaskStatusById -TaskId $d.TaskId -Status 'NEEDS_REVIEW'
        Add-Log ("0.6.12 migration: {0} переклассифицирован из {1} в NEEDS_REVIEW / WAITING_MANUAL_RELEASE_CHECK. Повтор T020 не требуется." -f $d.TaskId,$d.Status)
    } catch { Add-Log "Structured manual-review migration warning: $($_.Exception.Message)" }
}

function Mark-VerifiedTimeoutDone {
    param($Diagnostic,[string]$Reason)
    if($null -eq $Diagnostic -or -not $Diagnostic.HasData){return}
    $manual = ($Diagnostic.Stage -eq 'WAITING_MANUAL_RELEASE_CHECK')
    $acceptedStage = if($manual){'MANUAL_RELEASE_ACCEPTED'}else{'VERIFIED_ACCEPTED'}
    Write-RunState -RunDir $Diagnostic.RunDir -Task $Diagnostic.Task -TaskId $Diagnostic.TaskId -Stage $acceptedStage -Status 'DONE' -Reason $Reason -Project $Diagnostic.Project
    Save-LastGate -ProjectDir $Diagnostic.Project -Pass $true -RunDir $Diagnostic.RunDir -Reason $Reason -Status 'DONE' -Stage $acceptedStage
    Write-Utf8File (Join-Path $Diagnostic.RunDir 'verified-accept.txt') ("Accepted: $(Get-Date -Format s)`r`nStage: $acceptedStage`r`n$Reason")
    if($manual){
        if(-not (Set-RoadmapDoneWaitBaseForDiagnostic -Diagnostic $Diagnostic -Reason $Reason)){
            Set-QueueTaskStatusById -TaskId $Diagnostic.TaskId -Status 'DONE'
        }
    } else {
        Set-QueueTaskStatusById -TaskId $Diagnostic.TaskId -Status 'DONE'
    }
    $script:LastCyclePass=$true;$script:LastCycleStatus='DONE';$script:LastCycleFailureStage=''
    Add-Log ("{0} принят: {1}" -f $acceptedStage,$Reason)
}

function Accept-VerifiedTimeoutGate {
    $d=Get-LatestRunDiagnostic
    if(-not $d.HasData -or $d.Status -ne 'NEEDS_REVIEW'){return}
    $manualRelease = ($d.Stage -eq 'WAITING_MANUAL_RELEASE_CHECK')
    if($manualRelease){
        if(-not (Confirm-ManualReleaseChecklist $d)){return}
    } else {
        $ans=[System.Windows.Forms.MessageBox]::Show("Принять $($d.TaskId) по результатам локального Gate?`r`n`r`nBridge повторно выполнит Build/Tests/Godot/Git Safety перед принятием. Commit/push не выполняются.","Archer Dev Bridge — принять Gate",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
    }
    Set-UiBusy $true
    try {
        $project=$d.Project
        $baseHead='';$bp=Join-Path $d.RunDir 'baseline.json';if(Test-Path $bp){try{$b=Get-Content -Raw -Encoding UTF8 $bp|ConvertFrom-Json;$baseHead=[string]$b.head}catch{}}
        $now=Get-GitBaseInfo $project;$headOk=(-not $baseHead -or $now.Head -eq $baseHead)
        if($manualRelease){
            $confirmation=[ordered]@{confirmedAt=(Get-Date).ToString('o');taskId=$d.TaskId;stage=$d.Stage;checks=@('exported gameplay','save-exit-relaunch-continue','input-focus','audio','1280x720 1920x1080 2560x1440');bridgeVersion=$BridgeVersion}
            Write-Utf8File (Join-Path $d.RunDir 'manual-release-confirmation.json') ($confirmation|ConvertTo-Json -Depth 5)
            $v=Invoke-ManualReleaseAcceptanceGate -ProjectDir $project -RunDir $d.RunDir
            $safe=($v.Pass -and $headOk)
            if($safe){
                Mark-VerifiedTimeoutDone -Diagnostic $d -Reason 'Manual exported-build checklist confirmed by user; Git + manifest/package safety gate PASS.'
                [System.Windows.Forms.MessageBox]::Show("Manual Release Gate принят. Git/manifest/package проверены. ROADMAP переведён в DONE_WAIT_BASE и готов к ручному BASE.","Archer Dev Bridge",0,64)|Out-Null
            } else {
                $reason='Manual release acceptance failed Git/manifest/package safety gate: '+($v.Reasons -join '; ')
                Write-RunState -RunDir $d.RunDir -Task $d.Task -TaskId $d.TaskId -Stage 'MANUAL_RELEASE_ACCEPT_GATE' -Status 'NEEDS_REVIEW' -Reason $reason -Project $project
                Save-LastGate -ProjectDir $project -Pass $false -RunDir $d.RunDir -Reason $reason -Status 'NEEDS_REVIEW' -Stage 'MANUAL_RELEASE_ACCEPT_GATE'
                [System.Windows.Forms.MessageBox]::Show("Ручная проверка подтверждена, но Git/manifest/package safety gate не прошёл. NEEDS_REVIEW сохранён.`r`n`r`n$reason","Archer Dev Bridge",0,48)|Out-Null
            }
        } else {
            $godot=Find-GodotExecutable $txtGodot.Text.Trim()
            $v=Invoke-FullVerification -ProjectDir $project -GodotExe $godot -RunDir $d.RunDir -Prefix 'manual-accept'
            $safe=(-not $v.Git.Staged -and @($v.Git.SensitivePaths).Count -eq 0 -and $headOk)
            Write-Utf8File (Join-Path $d.RunDir 'manual-accept-summary.txt') (Get-VerificationSummary $v)
            if($v.Pass -and $safe){
                Mark-VerifiedTimeoutDone -Diagnostic $d -Reason 'Manual accept after NEEDS_REVIEW; repeated local verification PASS.'
                [System.Windows.Forms.MessageBox]::Show("Gate повторно прошёл. Задача отмечена DONE.","Archer Dev Bridge",0,64)|Out-Null
            } else {
                $reason='Manual accept verification failed or Git safety changed.'
                Write-RunState -RunDir $d.RunDir -Task $d.Task -TaskId $d.TaskId -Stage 'MANUAL_ACCEPT_GATE' -Status 'FAIL' -Reason $reason -Project $project
                Save-LastGate -ProjectDir $project -Pass $false -RunDir $d.RunDir -Reason $reason -Status 'FAIL' -Stage 'MANUAL_ACCEPT_GATE'
                Set-QueueTaskStatusById -TaskId $d.TaskId -Status 'FAIL'
                [System.Windows.Forms.MessageBox]::Show("Повторный Gate не прошёл. Задача оставлена FAIL.","Archer Dev Bridge",0,48)|Out-Null
            }
        }
    } finally { Force-UiIdle -Reason 'needs-review accept';try{[void](Update-SystemHealth)}catch{} }
}

function Review-VerifiedTimeoutGate {
    $d=Get-LatestRunDiagnostic
    if(-not $d.HasData -or $d.Status -ne 'NEEDS_REVIEW'){return}
    $ans=[System.Windows.Forms.MessageBox]::Show("Запустить только read-only Codex review для $($d.TaskId)?`r`nФайлы изменяться не будут.","Archer Dev Bridge — Review Only",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
    Set-UiBusy $true
    try {
        $context=Get-ProjectContextBundle $d.Project;$git=Get-GitSnapshot $d.Project
        $gatePath=Join-Path $d.RunDir 'gate-summary.txt';$gate=if(Test-Path $gatePath){Get-Content -Raw -Encoding UTF8 $gatePath}else{''}
        $prompt=@"
You are ASTRA OPERATOR in REVIEW-ONLY mode. Do not modify, create, delete, rename, stage or commit files. Review the current working tree against the original task and mandatory repository architecture. The coding process timed out, but local verification passed. Inspect the repository and existing changes. First line MUST be exactly OPERATOR_REVIEW: PASS or OPERATOR_REVIEW: NEEDS_FIX. Then provide concise findings and risks.

ORIGINAL TASK:
$($d.Task)

CONTEXT:
$context

LOCAL GATE:
$gate

TRACKED DIFF:
$($git.Diff)

UNTRACKED REVIEW:
$($git.UntrackedReview)
"@
        $model=Get-ComboValue $cmbCodexModel 'gpt-6-astra';$effort=Get-ComboValue $cmbCodexReasoning 'medium'
        $timeout=[Math]::Min(900,(Get-WatchdogSeconds 1800))
        $r=Invoke-CodexTask -ProjectDir $d.Project -Prompt $prompt -RunDir $d.RunDir -Label 'timeout-review' -Model $model -ReasoningEffort $effort -Sandbox 'read-only' -TimeoutSeconds $timeout
        if($r.ExitCode -eq 0 -and (Get-OperatorReviewPass $r.Final)){
            if($d.Stage -eq 'WAITING_MANUAL_RELEASE_CHECK'){
                Write-Utf8File (Join-Path $d.RunDir 'manual-release-readonly-review.txt') ([string]$r.Final)
                Add-Log 'Review-only PASS, но Manual Release Check остаётся обязательным; NEEDS_REVIEW сохранён.'
                [System.Windows.Forms.MessageBox]::Show("Review исходников PASS. Но экспортированный UI/profile check нельзя заменить read-only review.`r`nПроверьте EXE вручную и нажмите ПРИНЯТЬ GATE.","Archer Dev Bridge",0,64)|Out-Null
            } else {
                $godot=Find-GodotExecutable $txtGodot.Text.Trim();$v=Invoke-FullVerification -ProjectDir $d.Project -GodotExe $godot -RunDir $d.RunDir -Prefix 'review-accept'
                if($v.Pass -and -not $v.Git.Staged -and @($v.Git.SensitivePaths).Count -eq 0){
                    Mark-VerifiedTimeoutDone -Diagnostic $d -Reason 'Read-only Codex review PASS after NEEDS_REVIEW; local verification PASS.'
                    [System.Windows.Forms.MessageBox]::Show("Review PASS. Задача отмечена DONE.","Archer Dev Bridge",0,64)|Out-Null
                } else {[System.Windows.Forms.MessageBox]::Show("Review PASS, но повторный локальный Gate не прошёл. Статус не принят.","Archer Dev Bridge",0,48)|Out-Null}
            }
        } elseif($r.ExitCode -eq 0){
            $reason='Read-only Codex review returned NEEDS_FIX.'
            Write-RunState -RunDir $d.RunDir -Task $d.Task -TaskId $d.TaskId -Stage 'REVIEW_NEEDS_FIX' -Status 'FAIL' -Reason $reason -Project $d.Project
            Save-LastGate -ProjectDir $d.Project -Pass $false -RunDir $d.RunDir -Reason $reason -Status 'FAIL' -Stage 'REVIEW_NEEDS_FIX'
            Set-QueueTaskStatusById -TaskId $d.TaskId -Status 'FAIL'
            [System.Windows.Forms.MessageBox]::Show("Review обнаружил проблемы. Задача отмечена FAIL и может быть повторена.","Archer Dev Bridge",0,48)|Out-Null
        } else {
            Add-Log "Review-only Codex не завершился успешно. NEEDS_REVIEW сохранён."
            [System.Windows.Forms.MessageBox]::Show("Review-only не завершился. Статус NEEDS_REVIEW сохранён.","Archer Dev Bridge",0,48)|Out-Null
        }
    } finally { Force-UiIdle -Reason 'verified timeout review';try{[void](Update-SystemHealth)}catch{} }
}

function Reject-VerifiedTimeoutGate {
    $d=Get-LatestRunDiagnostic
    if(-not $d.HasData -or $d.Status -ne 'NEEDS_REVIEW'){return}
    $ans=[System.Windows.Forms.MessageBox]::Show("Отклонить verified-timeout результат $($d.TaskId)?`r`nИзменения НЕ удаляются. Задача станет FAIL и её можно будет повторить/откатить вручную.","Archer Dev Bridge — отклонить",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
    $reason='User rejected CODEX_TIMEOUT_VERIFIED result.'
    Write-RunState -RunDir $d.RunDir -Task $d.Task -TaskId $d.TaskId -Stage 'USER_REJECTED' -Status 'FAIL' -Reason $reason -Project $d.Project
    Save-LastGate -ProjectDir $d.Project -Pass $false -RunDir $d.RunDir -Reason $reason -Status 'FAIL' -Stage 'USER_REJECTED'
    Set-QueueTaskStatusById -TaskId $d.TaskId -Status 'FAIL'
    Add-Log "Verified-timeout result отклонён пользователем."
    [void](Update-SystemHealth)
}

function Update-VerifiedTimeoutUi {
    if($null -eq $btnAcceptVerified){return}
    $enable=$false
    try{$d=Get-LatestRunDiagnostic;$enable=($d.HasData -and $d.Status -eq 'NEEDS_REVIEW' -and -not $script:IsBusy)}catch{}
    foreach($b in @($btnAcceptVerified,$btnReviewVerified,$btnRejectVerified)){if($null -ne $b){$b.Enabled=$enable}}
}

function Show-LastRunDetails {
    $d = Get-LatestRunDiagnostic
    if (-not $d.HasData) {
        [System.Windows.Forms.MessageBox]::Show("Нет сохранённых данных о предыдущем цикле.","Archer Dev Bridge — последний цикл") | Out-Null
        return
    }
    $extra = ""
    if ($d.ArtifactSummary) {
        $text=[string]$d.ArtifactSummary
        if ($text.Length -gt 1800) { $text=$text.Substring(0,1800)+"`r`n...[обрезано]" }
        $extra="`r`n`r`nДИАГНОСТИКА:`r`n"+$text
    }
    $msg="Статус: $($d.Status)`r`nЭтап: $($d.Stage)`r`nПричина: $($d.Reason)`r`nКаталог: $($d.RunDir)`r`nLegacy/history: $($d.LegacyCount)$extra"
    if ($d.RunDir -and (Test-Path -LiteralPath $d.RunDir)) {
        $msg += "`r`n`r`nОткрыть каталог run?"
        $ans=[System.Windows.Forms.MessageBox]::Show($msg,"Archer Dev Bridge — последний цикл",[System.Windows.Forms.MessageBoxButtons]::YesNo,$(if($d.Pass){[System.Windows.Forms.MessageBoxIcon]::Information}else{[System.Windows.Forms.MessageBoxIcon]::Warning}))
        if($ans -eq [System.Windows.Forms.DialogResult]::Yes){Start-Process explorer.exe $d.RunDir}
    } else {
        [System.Windows.Forms.MessageBox]::Show($msg,"Archer Dev Bridge — последний цикл",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

function Update-LastRunUi {
    if ($null -eq $lblLastRun) { return }
    $d=Get-LatestRunDiagnostic
    if (-not $d.HasData) {
        $state="yellow"; $lblLastRun.Text="ПОСЛЕДНИЙ ЦИКЛ: ЕЩЁ НЕ БЫЛО В 0.6"; $tip=$d.Detail
    } elseif ($d.Pass) {
        $state="green"; $lblLastRun.Text="ПОСЛЕДНИЙ ЦИКЛ: $($d.Status)"; $tip=$d.Detail
    } else {
        $state=$d.State; $lblLastRun.Text="ПОСЛЕДНИЙ ЦИКЛ: $($d.Status) — $($d.Stage)"; $tip=$d.Detail
    }
    $lblLastRun.ForeColor = $(if($state -eq 'green'){[System.Drawing.Color]::FromArgb(61,220,132)}elseif($state -eq 'yellow'){[System.Drawing.Color]::FromArgb(255,200,87)}else{[System.Drawing.Color]::FromArgb(255,91,91)})
    if($null -ne $picLastRun){$picLastRun.Image=Get-StatusLampImage $state}
    if($null -ne $toolTipHealth){$toolTipHealth.SetToolTip($lblLastRun,$tip);if($null -ne $picLastRun){$toolTipHealth.SetToolTip($picLastRun,$tip)}}
    if($null -ne $btnLastRunDetails){$btnLastRunDetails.Enabled=$d.HasData}
    if($null -ne $btnRetryStage -and -not $script:IsBusy){Update-RetryButtonState}
    Update-VerifiedTimeoutUi
    Update-RunMetrics
}

function Confirm-PreviousGate {
    param([string]$ProjectDir)
    $d=Get-LatestRunDiagnostic
    if(-not $d.HasData){return $true}
    if($d.Project -eq $ProjectDir -and $d.Status -eq "NEEDS_REVIEW"){
        [System.Windows.Forms.MessageBox]::Show("Последний цикл ожидает решения: ПРИНЯТЬ GATE / REVIEW ONLY / ОТКЛОНИТЬ. Сначала завершите этот цикл.","Archer Dev Bridge — NEEDS REVIEW",0,48)|Out-Null
        return $false
    }
    if($d.Project -eq $ProjectDir -and -not $d.Pass -and $d.Status -notin @("ABORTED","INTERRUPTED","BLOCKED")){
        $msg="Последний современный цикл для этого проекта завершился $($d.Status).`r`n`r`nЭтап: $($d.Stage)`r`nПричина: $($d.Reason)`r`n`r`nЗапустить новую задачу всё равно?"
        $ans=[System.Windows.Forms.MessageBox]::Show($msg,"Archer Dev Bridge — last cycle",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
    }
    return $true
}

function New-HealthResult {
    param([string]$State, [string]$Name, [string]$Detail, [string]$Path = "")
    return [pscustomobject]@{ State=$State; Name=$Name; Detail=$Detail; Path=$Path }
}

function Get-SystemHealth {
    $project = $txtProject.Text.Trim()

    $codexPath = Resolve-AndPersistTool "codex"
    if ($codexPath) {
        $cv = Invoke-ProcessCaptured -FileName $codexPath -Arguments "--version" -TimeoutSeconds 30
        if ($cv.ExitCode -eq 0) { $codex = New-HealthResult "green" "Codex" $cv.StdOut.Trim() $codexPath }
        else { $codex = New-HealthResult "red" "Codex" ("Найден, но не запускается: " + $cv.StdErr.Trim()) $codexPath }
    } else { $codex = New-HealthResult "red" "Codex" "Codex CLI не найден" }

    $authInfo = Get-CodexAuthInfo
    if ($authInfo.State -ne "ok") { $auth = New-HealthResult "red" "Auth" $authInfo.Detail }
    elseif ($authInfo.Mode -eq "api" -and -not $chkAllowApiAuth.Checked) { $auth = New-HealthResult "red" "Auth" "API key заблокирован настройкой 0.6; войдите через ChatGPT или разрешите API-auth вручную" }
    elseif ($authInfo.Mode -eq "api") { $auth = New-HealthResult "yellow" "Auth" "API key разрешён пользователем — отдельная API-тарификация" }
    else { $auth = New-HealthResult "green" "Auth" "ChatGPT account / plan usage" }

    $gitPath = Resolve-AndPersistTool "git"
    if ($gitPath) {
        $gv = Invoke-ProcessCaptured -FileName $gitPath -Arguments "--version" -TimeoutSeconds 30
        if ($gv.ExitCode -eq 0) {
            $git = New-HealthResult "green" "Git" $gv.StdOut.Trim() $gitPath
            if ($project -and (Test-Path $project)) {
                $ginfo = Get-GitBaseInfo $project
                if (-not $ginfo.HasGit) { $git = New-HealthResult "red" "Git" (($gv.StdOut.Trim()) + "; выбранный проект не Git-репозиторий") $gitPath }
                elseif ($ginfo.Status) {
                    try {
                        $gd=Get-GitWorkingTreeDetails $project
                        $detail=(($gv.StdOut.Trim()) + "; " + $gd.Summary)
                    } catch {
                        $detail=(($gv.StdOut.Trim()) + "; working tree DIRTY; Git Inspector parser error: " + $_.Exception.Message)
                        Add-Log "Git Inspector parser fallback: $($_.Exception.Message)"
                    }
                    if($chkRequireClean.Checked){$detail += "; strict Clean Git включён — task будет заблокирован"}
                    $git = New-HealthResult "yellow" "Git" $detail $gitPath
                }
            }
        } else { $git = New-HealthResult "red" "Git" ("Найден, но не запускается: " + $gv.StdErr.Trim()) $gitPath }
    } else { $git = New-HealthResult "red" "Git" "Git не найден" }

    $dotnetPath = Resolve-AndPersistTool "dotnet"
    if ($dotnetPath) {
        $dv = Invoke-ProcessCaptured -FileName $dotnetPath -Arguments "--version" -TimeoutSeconds 30
        if ($dv.ExitCode -eq 0) { $dotnet = New-HealthResult "green" ".NET" ("SDK " + $dv.StdOut.Trim()) $dotnetPath }
        else { $dotnet = New-HealthResult "red" ".NET" ("Найден, но не запускается: " + $dv.StdErr.Trim()) $dotnetPath }
    } else { $dotnet = New-HealthResult "red" ".NET" ".NET SDK не найден" }

    $godotPath = Find-GodotExecutable $txtGodot.Text.Trim()
    if ($godotPath) {
        $gver = Invoke-ProcessCaptured -FileName $godotPath -Arguments "--version" -TimeoutSeconds 30
        if ($gver.ExitCode -eq 0) { $godot = New-HealthResult "green" "Godot" $gver.StdOut.Trim() $godotPath }
        else { $godot = New-HealthResult "yellow" "Godot" "Executable найден, но версия не проверилась" $godotPath }
    } else { $godot = New-HealthResult "red" "Godot" "Godot executable не найден" }

    if (-not $project -or -not (Test-Path $project)) {
        $proj = New-HealthResult "red" "Project" "Папка проекта не найдена"
        $tests = New-HealthResult "yellow" "Tests" "Нельзя проверить без проекта"
    } else {
        $hasGodotProject = Test-Path (Join-Path $project "project.godot")
        $cs = Get-CSharpProjectFile $project
        if (-not $hasGodotProject) { $proj = New-HealthResult "red" "Project" "project.godot не найден" $project }
        elseif (-not $cs) { $proj = New-HealthResult "red" "Project" "Godot-проект найден, но C# *.csproj не найден; строгий build gate недоступен" $project }
        else { $proj = New-HealthResult "green" "Project" ("Godot + C#: " + [IO.Path]::GetFileName($cs)) $project }

        if (-not $chkTests.Checked) { $tests = New-HealthResult "yellow" "Tests" "Тесты отключены пользователем; gate будет без project tests" }
        else {
            $tp = Get-TestProjectFile $project
            if ($tp) { $tests = New-HealthResult "green" "Tests" ([IO.Path]::GetFileName($tp)) $tp }
            else { $tests = New-HealthResult "red" "Tests" "Tests project не найден, а project tests включены" }
        }
    }

    if ((Get-OperatorMode) -eq "ONE_CODEX") {
        $agents = New-HealthResult "green" "Agents" "ONE CODEX: subagents отключены и не требуются" $AgentProfileDir
    } else {
        $agentState = Ensure-AstraAgentProfiles
        if ($agentState.Ready) { $agents = New-HealthResult "green" "Agents" "AI TEAM: archer_explorer + archer_worker + archer_reviewer готовы" $AgentProfileDir }
        else { $agents = New-HealthResult "red" "Agents" "AI TEAM выбран, но профили subagents отсутствуют/повреждены; нажмите РАЗОБРАТЬСЯ" $AgentProfileDir }
    }

    $astra = Get-AstraCompatibilityHealth
    $countryInfo = Get-InternetCountryInfo
    $script:CountryInfo = $countryInfo

    return [pscustomobject]@{ Godot=$godot; Codex=$codex; Auth=$auth; Git=$git; DotNet=$dotnet; Project=$proj; Tests=$tests; Agents=$agents; Astra=$astra; Country=$countryInfo }
}

function Set-HealthIndicator {
    param($Item, $Result, [switch]$Large)
    if ($null -eq $Item -or $null -eq $Result) { return }
    $state = ([string]$Result.State).ToLowerInvariant()
    switch ($state) {
        "green"  { $fore=[System.Drawing.Color]::FromArgb(61,220,132); $word="ГОТОВ" }
        "yellow" { $fore=[System.Drawing.Color]::FromArgb(255,200,87); $word="ВНИМАНИЕ" }
        default  { $fore=[System.Drawing.Color]::FromArgb(255,91,91); $word="НЕ ГОТОВ"; $state="red" }
    }
    if ($null -ne $Item.Label) {
        if ($Large -and $Result.Name -eq "СИСТЕМА") {
            if ($state -eq "green") { $Item.Label.Text = "СИСТЕМА: ГОТОВА К РАБОТЕ" }
            elseif ($state -eq "yellow") { $Item.Label.Text = "СИСТЕМА: ОГРАНИЧЕННАЯ ГОТОВНОСТЬ" }
            else { $Item.Label.Text = "СИСТЕМА: НЕ ГОТОВА" }
        } else {
            $Item.Label.Text = "$($Result.Name): $word"
        }
        $Item.Label.ForeColor = $fore
    }
    if ($null -ne $Item.Icon) {
        $img = Get-StatusLampImage $state -Large:$Large
        $Item.Icon.Image = $img
        $Item.Icon.BackColor = [System.Drawing.Color]::Transparent
    }
    if ($null -ne $toolTipHealth) {
        $tip = $Result.Detail + $(if($Result.Path){"`r`n"+$Result.Path}else{""})
        if ($null -ne $Item.Label) { $toolTipHealth.SetToolTip($Item.Label,$tip) }
        if ($null -ne $Item.Icon) { $toolTipHealth.SetToolTip($Item.Icon,$tip) }
    }
}

function Update-SystemHealth {
    param([switch]$WriteLog)
    try {
        $h = Get-SystemHealth
        Set-HealthIndicator $uiHealthGodot $h.Godot
        Set-HealthIndicator $uiHealthCodex $h.Codex
        Set-HealthIndicator $uiHealthAuth $h.Auth
        Set-HealthIndicator $uiHealthGit $h.Git
        Set-HealthIndicator $uiHealthDotNet $h.DotNet
        Set-HealthIndicator $uiHealthProject $h.Project
        Set-HealthIndicator $uiHealthTests $h.Tests
        Set-HealthIndicator $uiHealthAgents $h.Agents
        Set-HealthIndicator $uiHealthAstra $h.Astra
        Set-HealthIndicator $uiHealthCountry $h.Country

        if ($null -ne $lblCountry) {
            $lblCountry.Text = "СТРАНА: $($h.Country.Name) $($h.Country.Code)"
            if ($h.Country.State -eq "green") { $lblCountry.ForeColor=[System.Drawing.Color]::FromArgb(61,220,132) }
            elseif ($h.Country.State -eq "yellow") { $lblCountry.ForeColor=[System.Drawing.Color]::FromArgb(255,200,87) }
            else { $lblCountry.ForeColor=[System.Drawing.Color]::FromArgb(255,91,91) }
            if ($null -ne $picCountry) { $picCountry.Image = Get-StatusLampImage $h.Country.State }
            $tipCountry = "Источник: $($h.Country.Source). $($h.Country.Detail)"
            $toolTipHealth.SetToolTip($lblCountry,$tipCountry)
            if ($null -ne $picCountry) { $toolTipHealth.SetToolTip($picCountry,$tipCountry) }
        }

        $all = @($h.Godot,$h.Codex,$h.Auth,$h.Git,$h.DotNet,$h.Project,$h.Tests,$h.Agents,$h.Astra,$h.Country)
        $hasRed = @($all | Where-Object { $_.State -eq "red" }).Count -gt 0
        $hasYellow = @($all | Where-Object { $_.State -eq "yellow" }).Count -gt 0
        $script:SystemReady = -not $hasRed
        if ($hasRed) {
            Set-HealthIndicator $uiHealthOverall ([pscustomobject]@{State="red";Name="СИСТЕМА";Detail="Есть компоненты в красном статусе";Path=""}) -Large
        } elseif ($hasYellow) {
            Set-HealthIndicator $uiHealthOverall ([pscustomobject]@{State="yellow";Name="СИСТЕМА";Detail="Есть предупреждения по компонентам";Path=""}) -Large
        } else {
            Set-HealthIndicator $uiHealthOverall ([pscustomobject]@{State="green";Name="СИСТЕМА";Detail="Все основные компоненты готовы к работе";Path=""}) -Large
        }

        if ($null -ne $btnRun -and $form.Cursor -ne [System.Windows.Forms.Cursors]::WaitCursor) { $btnRun.Enabled = $script:SystemReady }
        if ($null -ne $btnRunQueue -and $form.Cursor -ne [System.Windows.Forms.Cursors]::WaitCursor) { $btnRunQueue.Enabled = $script:SystemReady }
        Update-LastRunUi
        if ($WriteLog) {
            foreach ($r in @($h.Godot,$h.Codex,$h.Auth,$h.Git,$h.DotNet,$h.Project,$h.Tests,$h.Agents,$h.Astra)) { Add-Log ("Health {0}: {1} — {2}" -f $r.Name,$r.State.ToUpperInvariant(),$r.Detail) }
            Add-Log ("Country: {0} — {1} ({2}), source={3}" -f $h.Country.State.ToUpperInvariant(),$h.Country.Name,$h.Country.Code,$h.Country.Source)
        }
        Save-Settings
        return $h
    } catch {
        Add-Log "Ошибка Health Monitor: $($_.Exception.Message)"
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { Add-Log ("Health Monitor location: " + $_.InvocationInfo.PositionMessage.Replace("`r`n"," | ")) }
        $script:SystemReady = $false
        return $null
    }
}

function Invoke-DiagnoseAndRepair {
    [void](Sync-SelfDestructCancellationState)
    if($null -ne $btnCancelSelfDestruct){$btnCancelSelfDestruct.Enabled=$true}
    Add-Log "=== РАЗОБРАТЬСЯ: диагностика и безопасное исправление ==="
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runDir = Join-Path $RunsDir ($stamp + "-diagnose")
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $actions = New-Object System.Collections.Generic.List[string]

    if (Refresh-ProcessPathFromRegistry) {
        $actions.Add("Обновлён PATH текущего процесса из User/Machine environment. Системный PATH не изменялся.")
        Add-Log "PATH текущего Bridge обновлён из Windows environment (без изменения системы)."
    }

    foreach ($name in @("codex","git","dotnet")) {
        $before = Get-ConfiguredToolPath $name
        $found = Resolve-AndPersistTool $name
        if ($found) {
            if ($before -ne $found) { $actions.Add(("{0}: найден и сохранён путь {1}" -f $name,$found)) }
            Add-Log ("{0}: найден {1}" -f $name,$found)
        } else { $actions.Add(("{0}: автоматически найти не удалось" -f $name)); Add-Log ("{0}: не найден" -f $name) }
    }

    $godot = Find-GodotExecutable $txtGodot.Text.Trim()
    if ($godot) {
        if ($txtGodot.Text.Trim() -ne $godot) { $txtGodot.Text = $godot; $actions.Add("Godot: найден и сохранён путь $godot") }
        Add-Log "Godot: найден $godot"
    } else { $actions.Add("Godot: автоматически найти не удалось") }

    if ((Get-OperatorMode) -eq "AI_TEAM") {
        try {
            $agentRepair = Ensure-AstraAgentProfiles -Repair
            if ($agentRepair.Changed.Count -gt 0) { foreach($p in $agentRepair.Changed){$actions.Add("Astra agents: создан/обновлён $p")} }
            elseif ($agentRepair.Ready) { $actions.Add("Astra agents: профили уже готовы") }
        } catch { $actions.Add("Astra agents: не удалось подготовить профили — $($_.Exception.Message)") }
    } else {
        $actions.Add("Operator mode: ASTRA + ONE CODEX — subagents не используются и не проверяются")
    }

    $auth = Get-CodexAuthInfo
    if ($auth.Mode -eq "api" -and -not $chkAllowApiAuth.Checked) {
        $actions.Add("Codex Auth: обнаружен API key. Автоматически credentials не изменялись; для ChatGPT-входа используйте codex logout, затем codex login.")
    } elseif ($auth.State -ne "ok") { $actions.Add("Codex Auth: авторизацию подтвердить не удалось; credentials автоматически не менялись.") }

    Save-Settings
    $script:CountryInfo = Get-InternetCountryInfo -Force
    $health = Update-SystemHealth -WriteLog
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add("Archer Dev Bridge v$BridgeVersion — Diagnose/Repair")
    $report.Add("Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $report.Add("")
    $report.Add("SAFE ACTIONS:")
    foreach ($a in $actions) { $report.Add("- $a") }
    $report.Add("")
    $report.Add("RESULT:")
    if ($health) {
        foreach ($r in @($health.Godot,$health.Codex,$health.Auth,$health.Git,$health.DotNet,$health.Project,$health.Tests,$health.Agents,$health.Astra)) {
            $report.Add(("- {0}: {1} — {2}{3}" -f $r.Name,$r.State.ToUpperInvariant(),$r.Detail,$(if($r.Path){" | "+$r.Path}else{""})))
        }
        $report.Add(("- Country: {0} — {1} ({2}) — source: {3}" -f $health.Country.State.ToUpperInvariant(),$health.Country.Name,$health.Country.Code,$health.Country.Source))
        try {
            $gd=Get-GitWorkingTreeDetails $txtProject.Text.Trim()
            if($gd.Dirty){
                $report.Add("")
                $report.Add("GIT DIRTY DETAILS:")
                foreach($ln in @((Format-GitWorkingTreeDetails $gd 200) -split "`r?`n")){$report.Add($ln)}
                $report.Add("")
                $report.Add("WHY YELLOW: Git CLI работает нормально; предупреждение вызвано незакоммиченными staged/unstaged/untracked файлами. При включённом strict Clean Git Bridge блокирует начало TASK, чтобы не смешать старые изменения с новой задачей.")
            }
        } catch {}
    }
    $lastRun = Get-LatestRunDiagnostic
    $report.Add("")
    $report.Add("LAST DEVELOPMENT CYCLE:")
    if ($lastRun.HasData) {
        $report.Add(("- Status: {0}" -f $lastRun.Status))
        $report.Add(("- Stage: {0}" -f $lastRun.Stage))
        $report.Add(("- Reason: {0}" -f $lastRun.Reason))
        $report.Add(("- RunDir: {0}" -f $(if($lastRun.RunDir){$lastRun.RunDir}else{"<missing>"})))
        $report.Add(("- Legacy/history ignored: {0}" -f $lastRun.LegacyCount))
        if ($lastRun.ArtifactSummary) {
            $summary=[string]$lastRun.ArtifactSummary
            if($summary.Length -gt 4000){$summary=$summary.Substring(0,4000)+"`r`n...[truncated]"}
            $report.Add("- Failure evidence:")
            $report.Add($summary)
        } elseif (-not $lastRun.Pass) {
            $report.Add("- Failure evidence: отдельные stdout/stderr отсутствуют. Для run, созданных начиная с 0.5.2, они сохраняются автоматически.")
        }
    } else { $report.Add("- Нет сохранённого предыдущего цикла.") }
    $report.Add("")
    $report.Add("Bridge did not install/uninstall software, change system PATH, modify credentials, or rewrite Git history.")
    $reportPath = Join-Path $runDir "diagnose-report.txt"
    Write-Utf8File $reportPath ($report -join "`r`n")
    Add-Log "Диагностика завершена. Отчёт: $reportPath"

    if ($health) {
        $all=@($health.Godot,$health.Codex,$health.Auth,$health.Git,$health.DotNet,$health.Project,$health.Tests,$health.Agents,$health.Astra,$health.Country)
        $red=@($all|Where-Object {$_.State -eq 'red'}).Count
        $yellow=@($all|Where-Object {$_.State -eq 'yellow'}).Count
        $lastLine = if($lastRun.HasData){"`r`nПоследний цикл: $($lastRun.Status) / $($lastRun.Stage)`r`nПричина: $($lastRun.Reason)`r`nLegacy/history ignored: $($lastRun.LegacyCount)"}else{"`r`nПоследний цикл: нет данных"}
        $msg="Диагностика завершена.`r`n`r`nКрасных: $red`r`nЖёлтых: $yellow$lastLine`r`n`r`nБезопасные исправления выполнены автоматически.`r`nНебезопасные действия и credentials не менялись.`r`nПодробности записаны в лог."
        [System.Windows.Forms.MessageBox]::Show($msg,"Archer Dev Bridge — Разобраться",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    [void](Sync-SelfDestructCancellationState)
    if($null -ne $btnCancelSelfDestruct){$btnCancelSelfDestruct.Enabled=$true}
    Update-SelfDestructUi
}

function Set-ShutdownGuard {
    param([bool]$Active,[string]$Reason="")
    try {
        if ($Active) {
            $guard=[pscustomobject]@{pid=$PID;active=$true;stage=[string]$script:ActiveStage;reason=$Reason;time=(Get-Date).ToString("o")}
            $json=$guard|ConvertTo-Json -Depth 4
            [IO.File]::WriteAllText($ShutdownGuardPath,$json,(New-Object System.Text.UTF8Encoding($false)))
        } else {
            if(Test-Path -LiteralPath $ShutdownGuardPath){Remove-Item -LiteralPath $ShutdownGuardPath -Force -ErrorAction SilentlyContinue}
        }
    } catch { Add-Log "Shutdown guard: $($_.Exception.Message)" }
}

function Sync-SelfDestructCancellationState {
    try {
        if($script:SelfDestructEverCancelled -or $script:SelfDestructCancelled -or (Test-Path -LiteralPath $CancelShutdownPath)){
            $script:SelfDestructCancelled=$true
            $script:SelfDestructEverCancelled=$true
            return $true
        }
    } catch {}
    return $false
}

function Test-SelfDestructArmed {
    return (-not (Sync-SelfDestructCancellationState))
}

function Update-SelfDestructUi {
    try {
        $cancelled=Sync-SelfDestructCancellationState
        if($cancelled){
            if($null -ne $selfDestructTimer){$selfDestructTimer.Stop()}
            if($null -ne $picSelfDestruct){$picSelfDestruct.Visible=$true;$picSelfDestruct.Image=Get-StatusLampImage 'green' -Large}
            if($null -ne $lblSelfDestruct){$lblSelfDestruct.Text='АВТОЗАКРЫТИЕ ОТМЕНЕНО';$lblSelfDestruct.ForeColor=[System.Drawing.Color]::FromArgb(80,220,120)}
            if($null -ne $btnCancelSelfDestruct){$btnCancelSelfDestruct.Text='ОТМЕНА САМОУНИЧТОЖЕНИЯ ✓';$btnCancelSelfDestruct.Enabled=$true}
            return
        }
        if($null -ne $btnCancelSelfDestruct){$btnCancelSelfDestruct.Text='ОТМЕНА САМОУНИЧТОЖЕНИЯ';$btnCancelSelfDestruct.Enabled=$true}
        $remaining=[Math]::Ceiling(($script:SelfDestructDeadline-(Get-Date)).TotalSeconds)
        if($remaining -lt 0){$remaining=0}
        $script:SelfDestructBlink=-not $script:SelfDestructBlink
        if($null -ne $picSelfDestruct){$picSelfDestruct.Image=Get-StatusLampImage 'red' -Large;$picSelfDestruct.Visible=$script:SelfDestructBlink}
        if($null -ne $lblSelfDestruct){$lblSelfDestruct.Text=('АВТОЗАКРЫТИЕ ЧЕРЕЗ 00:{0:00}' -f [int]$remaining);$lblSelfDestruct.ForeColor=[System.Drawing.Color]::FromArgb(255,80,80)}
        if($remaining -le 0){
            if($null -ne $selfDestructTimer){$selfDestructTimer.Stop()}
            if($script:DevelopmentInProgress -or $script:QueueInProgress -or $script:GateInProgress -or $script:PlanInProgress){
                $script:SelfDestructCancelled=$true
                $script:SelfDestructEverCancelled=$true
                Add-Log 'SELF-DESTRUCT GUARD: активная работа обнаружена, автозакрытие отменено ради сохранности работы.'
                Update-SelfDestructUi
                return
            }
            Add-Log 'SELF-DESTRUCT: таймер истёк без подтверждения пользователя. Bridge закрывается.'
            try{$script:ClosingMain=$true}catch{}
            try{$form.Close()}catch{[System.Windows.Forms.Application]::Exit()}
        }
    } catch { Add-Log "SELF-DESTRUCT UI: $($_.Exception.Message)" }
}

function Assert-SelfDestructCancelled {
    if(Sync-SelfDestructCancellationState){return $true}
    [System.Windows.Forms.MessageBox]::Show("Перед запуском работы нажмите «ОТМЕНА САМОУНИЧТОЖЕНИЯ».`r`n`r`nДо отмены действует таймер автозакрытия.","Archer Dev Bridge — защита запуска",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null
    return $false
}

function Apply-SelfDestructTaskLock {
    try {
        # Safety control is intentionally always clickable, including BUSY/diagnostics/recovery states.
        if($null -ne $btnCancelSelfDestruct){$btnCancelSelfDestruct.Enabled=$true}
        if(-not (Sync-SelfDestructCancellationState)){
            foreach($c in @($btnRun,$btnRunQueue,$btnVerify,$btnPlanOnly,$btnRetryStage)){
                if($null -ne $c){$c.Enabled=$false}
            }
        }
    } catch {}
}

function Cancel-SelfDestruct {
    try {
        $alreadyCancelled=Sync-SelfDestructCancellationState
        $script:StopRequested=$false
        $script:SelfDestructCancelled=$true
        $script:SelfDestructEverCancelled=$true
        $stamp="CANCEL_SELF_DESTRUCT $(Get-Date -Format o) PID=$PID"
        [IO.File]::WriteAllText($CancelShutdownPath,$stamp,(New-Object System.Text.UTF8Encoding($false)))
        if($alreadyCancelled){
            Add-Log "ОТМЕНА САМОУНИЧТОЖЕНИЯ: повторно подтверждена; защита остаётся отключённой до следующего запуска Bridge."
        } else {
            Add-Log "ОТМЕНА САМОУНИЧТОЖЕНИЯ: внешний updater/rollback и локальный таймер автозакрытия запрещены. Текущая работа сохраняется."
        }
        try {
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'ArcherDevBridge_Update*' } | ForEach-Object {
                try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; Add-Log "Остановлен updater PID=$($_.Id)." } catch {}
            }
        } catch {}
        try {
            $alive=$false
            if($null -ne $script:ActiveProcess){try{$alive=-not $script:ActiveProcess.HasExited}catch{}}
            if(-not $alive -and -not $script:DevelopmentInProgress -and -not $script:QueueInProgress -and -not $script:GateInProgress -and -not $script:PlanInProgress){Force-UiIdle -Reason "self-destruct cancel / no active work"}
        } catch {}
        Update-SelfDestructUi
        try{[void](Update-SystemHealth)}catch{}
        if(-not $alreadyCancelled){
            [System.Windows.Forms.MessageBox]::Show("Автозакрытие и аварийный rollback отменены.`r`n`r`nКнопка отмены остаётся активной всегда и может быть нажата повторно в любой момент.","Archer Dev Bridge — ОТМЕНА САМОУНИЧТОЖЕНИЯ",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        }
    } catch {
        Add-Log "ОТМЕНА САМОУНИЧТОЖЕНИЯ: ошибка: $($_.Exception.Message)"
        try{if($null -ne $btnCancelSelfDestruct){$btnCancelSelfDestruct.Enabled=$true}}catch{}
    }
}

function Restore-CompletionSignalVisual {
    try {
        if($null -ne $form){$form.BackColor=$C_BG}
        if($null -ne $pnlHeader){$pnlHeader.BackColor=[System.Drawing.Color]::FromArgb(20,28,39)}
        if($null -ne $pnlAccent){$pnlAccent.BackColor=$C_ACCENT}
        foreach($g in @($grpConfig,$grpHealth,$grpTasks)){if($null -ne $g){$g.BackColor=$C_PANEL}}
        if($null -ne $btnAckSignal){Style-ArcherButton $btnAckSignal}
    } catch {}
}

function Update-CompletionSignalUi {
    try {
        if(-not $script:CompletionSignalActive){Restore-CompletionSignalVisual;return}
        $script:CompletionSignalBlink=-not $script:CompletionSignalBlink
        $kind=[string]$script:CompletionSignalKind
        $accent=switch($kind){
            'green' {[System.Drawing.Color]::FromArgb(70,220,120)}
            'yellow' {[System.Drawing.Color]::FromArgb(242,193,68)}
            default {[System.Drawing.Color]::FromArgb(255,80,80)}
        }
        $panel=switch($kind){
            'green' {[System.Drawing.Color]::FromArgb(20,70,42)}
            'yellow' {[System.Drawing.Color]::FromArgb(76,62,20)}
            default {[System.Drawing.Color]::FromArgb(82,28,32)}
        }
        if($script:CompletionSignalBlink){
            $form.BackColor=$panel;$pnlHeader.BackColor=$panel;$pnlAccent.BackColor=$accent
            foreach($g in @($grpConfig,$grpHealth,$grpTasks)){if($null -ne $g){$g.BackColor=$panel}}
            if($null -ne $btnAckSignal){$btnAckSignal.BackColor=$panel;$btnAckSignal.FlatAppearance.BorderColor=$accent;$btnAckSignal.ForeColor=$accent}
        } else { Restore-CompletionSignalVisual }
    } catch { Add-Log "COMPLETION SIGNAL UI: $($_.Exception.Message)" }
}

function Start-CompletionSignal {
    param([string]$Status,[string]$TaskId="")
    try {
        if($null -ne $chkCompletionSignal -and -not $chkCompletionSignal.Checked){return}
        $kind=switch -Regex ([string]$Status){
            '^(DONE|PASS|DONE_WAIT_BASE)$' {'green';break}
            '^(NEEDS_REVIEW|BLOCKED_ENVIRONMENT|VERIFIED|WARNING|REVIEW_NEEDS_FIX)$' {'yellow';break}
            default {'red'}
        }
        $script:CompletionSignalKind=$kind
        $script:CompletionSignalTaskId=$TaskId
        $script:CompletionSignalActive=$true
        $script:CompletionSignalBlink=$false
        if($null -ne $btnAckSignal){
            $btnAckSignal.Enabled=$true
            $btnAckSignal.Text=$(if($TaskId){"$TaskId — УБРАТЬ СИГНАЛ"}else{"УБРАТЬ СИГНАЛ"})
        }
        if($null -ne $completionSignalTimer){$completionSignalTimer.Start()}
        Update-CompletionSignalUi
        Add-Log "СИГНАЛ ЗАВЕРШЕНИЯ: task=$TaskId status=$Status color=$kind; мигает до ручного подтверждения."
    } catch { Add-Log "СИГНАЛ ЗАВЕРШЕНИЯ: ошибка запуска: $($_.Exception.Message)" }
}

function Acknowledge-CompletionSignal {
    param([switch]$Silent)
    try {
        $was=$script:CompletionSignalActive
        $script:CompletionSignalActive=$false
        $script:CompletionSignalKind=""
        $script:CompletionSignalTaskId=""
        $script:CompletionSignalBlink=$false
        if($null -ne $completionSignalTimer){$completionSignalTimer.Stop()}
        Restore-CompletionSignalVisual
        if($null -ne $btnAckSignal){$btnAckSignal.Enabled=$false;$btnAckSignal.Text='СИГНАЛ ПРИНЯТ'}
        if($was -and -not $Silent){Add-Log 'СИГНАЛ ЗАВЕРШЕНИЯ: подтверждён пользователем, мигание остановлено.'}
    } catch {}
}

function Set-UiBusy {
    param([bool]$Busy)
    $script:IsBusy=$Busy
    $script:LastBusyChange=Get-Date
    try { if ($Busy) { Set-ShutdownGuard $true "ACTIVE_TASK" } else { Set-ShutdownGuard $false; $script:StopRequested=$false } } catch {}
    foreach($c in @($btnRun,$btnVerify,$btnCheck,$btnBrowseProject,$btnBrowseGodot,$btnDetectGodot,$btnDiagnose,$btnQueueAdd,$btnQueueRemove,$btnQueueClear,$btnRunQueue,$btnPlanOnly,$btnRetryStage,$btnRollback,$btnCleanupLogs,$btnExportDiag,$btnGitDetails,$btnAcceptVerified,$btnReviewVerified,$btnRejectVerified)){
        if($null -ne $c){try{$c.Enabled=-not $Busy}catch{}}
    }
    if($null -ne $btnStop){try{$btnStop.Enabled=$Busy}catch{}}
    if($null -ne $btnCancelSelfDestruct){try{$btnCancelSelfDestruct.Enabled=$true}catch{}}
    if($null -ne $btnRunQueue -and -not $Busy){try{$btnRunQueue.Enabled=$script:SystemReady}catch{}}
    if($null -ne $btnRetryStage -and -not $Busy){Update-RetryButtonState}
    if($null -ne $form){try{if($Busy){$form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor}else{$form.Cursor=[System.Windows.Forms.Cursors]::Default}}catch{}}
    try{[System.Windows.Forms.Application]::DoEvents()}catch{}
}

function Force-UiIdle {
    param([string]$Reason="")
    $script:IsBusy=$false
    $script:StopRequested=$false
    $script:ActiveStage=""
    try { if($null -ne $script:ActiveProcess -and $script:ActiveProcess.HasExited){$script:ActiveProcess=$null} } catch { $script:ActiveProcess=$null }
    try { Set-ShutdownGuard $false } catch {}
    foreach($c in @($btnVerify,$btnCheck,$btnBrowseProject,$btnBrowseGodot,$btnDetectGodot,$btnDiagnose,$btnQueueAdd,$btnQueueRemove,$btnQueueClear,$btnPlanOnly,$btnRollback,$btnCleanupLogs,$btnExportDiag,$btnGitDetails,$btnAcceptVerified,$btnReviewVerified,$btnRejectVerified)){
        if($null -ne $c){try{$c.Enabled=$true}catch{}}
    }
    if($null -ne $btnRun){try{$btnRun.Enabled=$script:SystemReady}catch{}}
    if($null -ne $btnRunQueue){try{$btnRunQueue.Enabled=$script:SystemReady}catch{}}
    if($null -ne $btnStop){try{$btnStop.Enabled=$false}catch{}}
    if($null -ne $btnRetryStage){Update-RetryButtonState}
    if($null -ne $btnThawUi){try{$btnThawUi.Enabled=$true}catch{}}
    if($null -ne $btnCancelSelfDestruct){try{$btnCancelSelfDestruct.Enabled=$true}catch{}}
    Update-VerifiedTimeoutUi
    if($null -ne $form){try{$form.Cursor=[System.Windows.Forms.Cursors]::Default}catch{}}
    if($Reason){Add-Log "UI RECOVERY: $Reason"}
    Apply-SelfDestructTaskLock
    try{[System.Windows.Forms.Application]::DoEvents()}catch{}
}

function Schedule-UiIdleRecovery {
    param([string]$Reason="run finished")
    try {
        if($null -ne $form -and -not $form.IsDisposed){
            $action=[System.Action]{ Force-UiIdle -Reason $Reason; try{[void](Update-SystemHealth)}catch{} }
            [void]$form.BeginInvoke($action)
        }
    } catch { Force-UiIdle -Reason $Reason }
}

function Stop-ActiveProcessTree {
    param($Process)
    if($null -eq $Process){return}
    try{
        if(-not $Process.HasExited){
            $taskkill=Join-Path $env:SystemRoot "System32\taskkill.exe"
            if(Test-Path $taskkill){
                $psi=New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName=$taskkill; $psi.Arguments="/PID $($Process.Id) /T /F"; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
                $k=New-Object System.Diagnostics.Process; $k.StartInfo=$psi; [void]$k.Start(); [void]$k.WaitForExit(5000)
            }else{try{$Process.Kill()}catch{}}
        }
    }catch{try{$Process.Kill()}catch{}}
}

function Request-Stop {
    if(-not $script:IsBusy){return}
    $ans=[System.Windows.Forms.MessageBox]::Show("Остановить текущий этап? Текущая задача получит статус ABORTED. Git history не изменяется.","Archer Dev Bridge — STOP",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
    $script:StopRequested=$true
    Add-Log "STOP запрошен пользователем. Этап: $($script:ActiveStage)"
    if($null -ne $script:ActiveProcess){Stop-ActiveProcessTree -Process $script:ActiveProcess}
}

function Get-FreeSpaceGB {
    param([string]$Path)
    try{$root=[IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).Path);$d=New-Object System.IO.DriveInfo($root);return [math]::Round($d.AvailableFreeSpace/1GB,2)}catch{return -1}
}

function Get-PreflightReport {
    param([string]$ProjectDir,[bool]$AllowDirtyStart=$false)
    $fail=New-Object System.Collections.Generic.List[string];$warn=New-Object System.Collections.Generic.List[string];$ok=New-Object System.Collections.Generic.List[string]
    if(-not $ProjectDir -or -not(Test-Path -LiteralPath $ProjectDir)){$fail.Add("Папка проекта недоступна.")}else{$ok.Add("Project path OK")}
    if($ProjectDir -and (Test-Path -LiteralPath $ProjectDir)){
        if(Test-Path (Join-Path $ProjectDir "project.godot")){$ok.Add("project.godot OK")}else{$fail.Add("project.godot не найден.")}
        try{$t=Join-Path $ProjectDir (".adb-write-test-"+[guid]::NewGuid().ToString("N")+".tmp");[IO.File]::WriteAllText($t,"test");Remove-Item -LiteralPath $t -Force;$ok.Add("Project write OK")}catch{$fail.Add("Нет прав записи в проект: $($_.Exception.Message)")}
        $free=Get-FreeSpaceGB $ProjectDir
        if($free -ge 0 -and $free -lt 0.5){$fail.Add("Критически мало места на диске: $free ГБ")}
        elseif($free -ge 0 -and $free -lt 2){$warn.Add("Мало свободного места: $free ГБ")}
        elseif($free -ge 0){$ok.Add("Free space: $free GB")}
        $g=Get-GitBaseInfo $ProjectDir
        if(-not $g.HasGit){$fail.Add("Git repository не обнаружен.")}
        elseif($chkRequireClean.Checked -and -not $AllowDirtyStart -and $g.Status){$fail.Add("Git working tree DIRTY при включённом Clean Git.")}
        else{$ok.Add("Git preflight OK")}
    }
    try{$t=Join-Path $AppDataDir ("write-test-"+[guid]::NewGuid().ToString("N")+".tmp");[IO.File]::WriteAllText($t,"test");Remove-Item -LiteralPath $t -Force;$ok.Add("Bridge storage write OK")}catch{$fail.Add("Нет прав записи в ArcherDevBridge AppData.")}
    $auth=Test-CodexAuthAllowed;if(-not $auth.Allowed){$fail.Add($auth.Reason)}else{$ok.Add("Codex auth OK")}
    return [pscustomobject]@{Pass=($fail.Count -eq 0);Failures=@($fail);Warnings=@($warn);Ok=@($ok);Text=((@("PREFLIGHT")+@($ok|ForEach-Object{"OK: $_"})+@($warn|ForEach-Object{"WARN: $_"})+@($fail|ForEach-Object{"FAIL: $_"})) -join "`r`n")}
}

function Acquire-RunLock {
    param([string]$Project,[string]$RunDir,[string]$TaskId)
    try{
        if(Test-Path $RunLockPath){
            try{$old=Get-Content -Raw -Encoding UTF8 $RunLockPath|ConvertFrom-Json;$alive=$false;if($old.pid){$alive=$null -ne (Get-Process -Id ([int]$old.pid) -ErrorAction SilentlyContinue)};if($alive){return [pscustomobject]@{Acquired=$false;Reason="Уже активен run PID=$($old.pid), project=$($old.project)"}}}catch{}
            Remove-Item -LiteralPath $RunLockPath -Force -ErrorAction SilentlyContinue
        }
        $obj=[ordered]@{pid=$PID;project=$Project;runDir=$RunDir;taskId=$TaskId;started=(Get-Date).ToString("o");bridgeVersion=$BridgeVersion;schemaVersion=$RunSchemaVersion}
        $json=$obj|ConvertTo-Json -Depth 4
        $bytes=[Text.Encoding]::UTF8.GetBytes($json)
        $fs=[IO.File]::Open($RunLockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$fs.Write($bytes,0,$bytes.Length)}finally{$fs.Dispose()}
        return [pscustomobject]@{Acquired=$true;Reason=""}
    }catch{return [pscustomobject]@{Acquired=$false;Reason=$_.Exception.Message}}
}

function Release-RunLock {
    try{if(Test-Path $RunLockPath){$o=Get-Content -Raw -Encoding UTF8 $RunLockPath|ConvertFrom-Json;if([int]$o.pid -eq $PID){Remove-Item -LiteralPath $RunLockPath -Force}}}catch{}
}

function Recover-InterruptedRun {
    if(-not(Test-Path $RunLockPath)){return}
    try{
        $o=Get-Content -Raw -Encoding UTF8 $RunLockPath|ConvertFrom-Json
        $alive=$false;if($o.pid){$alive=$null -ne (Get-Process -Id ([int]$o.pid) -ErrorAction SilentlyContinue)}
        if($alive -and [int]$o.pid -ne $PID){return}
        $rd=[string]$o.runDir
        if($rd -and (Test-Path $rd)){
            $sp=Join-Path $rd "run-state.json"
            if(Test-Path $sp){
                $rs=Get-Content -Raw -Encoding UTF8 $sp|ConvertFrom-Json
                if([string]$rs.status -eq "RUNNING"){
                    Write-RunState -RunDir $rd -Task ([string]$rs.task) -TaskId ([string]$rs.taskId) -Stage "RECOVERY" -Status "INTERRUPTED" -Reason "Предыдущий процесс Bridge завершился до окончания run." -Project ([string]$rs.project) -RunKind "task" -RetryOf ([string]$rs.retryOf)
                    Save-LastGate -ProjectDir ([string]$rs.project) -Pass $false -RunDir $rd -Reason "Run был прерван закрытием Bridge/Windows." -Status "INTERRUPTED" -Stage "RECOVERY"
                    Add-Log "Crash Recovery: найден и помечен INTERRUPTED run: $rd"
                }
            }
        }
        Remove-Item -LiteralPath $RunLockPath -Force -ErrorAction SilentlyContinue
    }catch{Add-Log "Crash Recovery warning: $($_.Exception.Message)"}
}

function Save-GitBaseline {
    param([string]$Project,[string]$RunDir,$GitInfo)
    $u=@();$r=Invoke-ProcessCaptured -FileName "git" -Arguments "ls-files --others --exclude-standard" -WorkingDirectory $Project -TimeoutSeconds 30 -StageName "BASELINE";if($r.ExitCode -eq 0){$u=@($r.StdOut -split "`r?`n"|Where-Object{$_})}
    $obj=[ordered]@{project=$Project;head=$GitInfo.Head;branch=$GitInfo.Branch;status=$GitInfo.Status;untracked=$u;captured=(Get-Date).ToString("o")}
    $obj|ConvertTo-Json -Depth 5|Set-Content -Encoding UTF8 (Join-Path $RunDir "baseline.json")
}

function Test-SensitivePath {
    param([string]$RelativePath)
    if(-not $RelativePath){return $false}
    $name=[IO.Path]::GetFileName($RelativePath).ToLowerInvariant()
    $ext=[IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if($name -in @('.env','.env.local','.env.production','.env.development','secrets.json','credentials.json','service-account.json')){return $true}
    if($ext -in @('.pfx','.p12','.pem','.key','.kdbx')){return $true}
    return $false
}

function Write-ChangeMap {
    param([string]$Project,[string]$RunDir)
    $tracked=Invoke-ProcessCaptured -FileName "git" -Arguments "diff HEAD --name-status" -WorkingDirectory $Project -TimeoutSeconds 60 -StageName "CHANGE_MAP"
    $stat=Invoke-ProcessCaptured -FileName "git" -Arguments "diff HEAD --stat" -WorkingDirectory $Project -TimeoutSeconds 60 -StageName "CHANGE_MAP"
    $uNow=Invoke-ProcessCaptured -FileName "git" -Arguments "ls-files --others --exclude-standard" -WorkingDirectory $Project -TimeoutSeconds 60 -StageName "CHANGE_MAP"
    $baseUn=@();$bp=Join-Path $RunDir "baseline.json";if(Test-Path $bp){try{$b=Get-Content -Raw -Encoding UTF8 $bp|ConvertFrom-Json;$baseUn=@($b.untracked)}catch{}}
    $currentUn=@($uNow.StdOut -split "`r?`n"|Where-Object{$_});$created=@($currentUn|Where-Object{$_ -notin $baseUn})
    $trackedPaths=New-Object System.Collections.Generic.List[string];$added=0;$modified=0;$deleted=0;$renamed=0
    foreach($line in @($tracked.StdOut -split "`r?`n"|Where-Object{$_})){$parts=$line -split "`t";if($parts.Count -ge 2){$code=$parts[0];$path=$parts[-1];$trackedPaths.Add($path);if($code -like "A*"){$added++}elseif($code -like "D*"){$deleted++}elseif($code -like "R*"){$renamed++}else{$modified++}}}
    $sensitive=@(@($trackedPaths)+@($created) | Where-Object { Test-SensitivePath ([string]$_) } | Select-Object -Unique)
    $obj=[ordered]@{trackedPaths=@($trackedPaths);createdUntracked=$created;added=$added;modified=$modified;deleted=$deleted;renamed=$renamed;untrackedCreated=$created.Count;sensitivePaths=$sensitive;sensitiveCount=$sensitive.Count;captured=(Get-Date).ToString("o")}
    $obj|ConvertTo-Json -Depth 6|Set-Content -Encoding UTF8 (Join-Path $RunDir "change-map.json")
    $txt="CHANGE MAP`r`nAdded: $added`r`nModified: $modified`r`nDeleted: $deleted`r`nRenamed: $renamed`r`nNew untracked: $($created.Count)`r`nSensitive paths: $($sensitive.Count)`r`n$($sensitive -join "`r`n")`r`n`r`nTRACKED:`r`n$($tracked.StdOut)`r`nSTAT:`r`n$($stat.StdOut)`r`nNEW UNTRACKED:`r`n$($created -join "`r`n")"
    Write-Utf8File (Join-Path $RunDir "change-map.txt") $txt
    return [pscustomobject]$obj
}

function Invoke-TaskScopedRollback {
    $d=Get-LatestRunDiagnostic;if(-not $d.HasData -or -not $d.RunDir){[System.Windows.Forms.MessageBox]::Show("Нет современного task-run для отката.")|Out-Null;return}
    $bp=Join-Path $d.RunDir "baseline.json";$cp=Join-Path $d.RunDir "change-map.json";if(-not(Test-Path $bp) -or -not(Test-Path $cp)){[System.Windows.Forms.MessageBox]::Show("Для этого run нет baseline/change-map. Безопасный откат невозможен.")|Out-Null;return}
    try{$b=Get-Content -Raw -Encoding UTF8 $bp|ConvertFrom-Json;$c=Get-Content -Raw -Encoding UTF8 $cp|ConvertFrom-Json}catch{[System.Windows.Forms.MessageBox]::Show("Не удалось прочитать данные отката.")|Out-Null;return}
    $project=[string]$b.project;$g=Get-GitBaseInfo $project;if(-not $g.HasGit -or $g.Head -ne [string]$b.head){[System.Windows.Forms.MessageBox]::Show("HEAD изменился после run. Автоматический task-scoped rollback заблокирован.","Rollback",0,16)|Out-Null;return}
    $count=@($c.trackedPaths).Count+@($c.createdUntracked).Count
    $ans=[System.Windows.Forms.MessageBox]::Show("Откатить изменения только этого run?`r`nФайлов: $count`r`n`r`nИспользуется git restore --staged --worktree только по конкретным tracked-файлам и удаление только новых untracked-файлов из change-map. git reset --hard НЕ используется.","Archer Dev Bridge — task rollback",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return}
    $errors=New-Object System.Collections.Generic.List[string]
    foreach($rel in @($c.trackedPaths)){if(-not $rel){continue};$arg='restore --source "'+[string]$b.head+'" --staged --worktree -- "'+([string]$rel).Replace('"','\"')+'"';$r=Invoke-ProcessCaptured -FileName "git" -Arguments $arg -WorkingDirectory $project -TimeoutSeconds 60 -StageName "ROLLBACK";if($r.ExitCode -ne 0){$errors.Add("$rel : $($r.StdErr)")}}
    $root=[IO.Path]::GetFullPath($project).TrimEnd('\')+'\'
    foreach($rel in @($c.createdUntracked)){if(-not $rel){continue};try{$full=[IO.Path]::GetFullPath((Join-Path $project ([string]$rel)));if($full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf)){Remove-Item -LiteralPath $full -Force}}catch{$errors.Add("$rel : $($_.Exception.Message)")}}
    Write-Utf8File (Join-Path $d.RunDir "rollback.txt") ("Time: $(Get-Date -Format s)`r`nErrors: $($errors.Count)`r`n$($errors -join "`r`n")")
    if($errors.Count -eq 0){[System.Windows.Forms.MessageBox]::Show("Task-scoped rollback выполнен.","Rollback")|Out-Null}else{[System.Windows.Forms.MessageBox]::Show("Rollback завершён с ошибками:`r`n$($errors -join "`r`n")","Rollback",0,48)|Out-Null}
    [void](Update-SystemHealth)
}

function Retry-LastFailedStage {
    if(-not (Assert-SelfDestructCancelled)){return}
    $d=Get-LatestRunDiagnostic;if(-not $d.HasData -or $d.Pass){[System.Windows.Forms.MessageBox]::Show("Нет последнего неуспешного современного task-run.")|Out-Null;return}
    if($d.Status -eq "SAFETY_STOP" -or $d.Stage -eq "SAFETY_STOP"){[System.Windows.Forms.MessageBox]::Show("После SAFETY STOP повтор заблокирован до ручной проверки Git.")|Out-Null;return}
    if($d.Stage -match "QUALITY|BUILD|TEST|GODOT|GATE"){
        Run-GateRetry -SourceRunDir $d.RunDir
        return
    }
    $ans=[System.Windows.Forms.MessageBox]::Show("Повторить операторский этап для задачи $($d.TaskId)?`r`nBridge создаст новый run и сохранит ссылку retryOf. Текущее рабочее дерево не очищается автоматически.","Retry",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($ans -eq [System.Windows.Forms.DialogResult]::Yes){Run-DevelopmentCycle -TaskOverride $d.Task -TaskId (($d.TaskId)+"R") -AllowDirtyStart $true -RetryOf $d.RunDir -ParentTaskId $d.TaskId -TaskType "RETRY" -InheritedWorkingTree $true}
}

function Run-GateRetry {
    param([string]$SourceRunDir)
    $sp=Join-Path $SourceRunDir "run-state.json";if(-not(Test-Path $sp)){return};$src=Get-Content -Raw -Encoding UTF8 $sp|ConvertFrom-Json;$project=[string]$src.project;if(-not(Test-Path $project)){return}
    Set-UiBusy $true;$script:StopRequested=$false;$runDir="";$locked=$false
    try{
        $stamp=Get-Date -Format "yyyyMMdd-HHmmss";$runDir=Join-Path $RunsDir ($stamp+"-retry-gate");New-Item -ItemType Directory -Force -Path $runDir|Out-Null
        Write-RunState -RunDir $runDir -Task ([string]$src.task) -TaskId ([string]$src.taskId) -Stage "RETRY_GATE" -Status "RUNNING" -Project $project -RetryOf $SourceRunDir
        $lock=Acquire-RunLock -Project $project -RunDir $runDir -TaskId ([string]$src.taskId)
        if(-not $lock.Acquired){Write-RunState -RunDir $runDir -Task ([string]$src.task) -TaskId ([string]$src.taskId) -Stage "RUN_LOCK" -Status "BLOCKED" -Reason $lock.Reason -Project $project -RetryOf $SourceRunDir;throw "RUN LOCK: $($lock.Reason)"};$locked=$true
        $preflight=Get-PreflightReport -ProjectDir $project -AllowDirtyStart $true;Write-Utf8File (Join-Path $runDir "preflight.txt") $preflight.Text
        if(-not $preflight.Pass){throw "PREFLIGHT BLOCKED: "+($preflight.Failures -join '; ')}
        $godot=Find-GodotExecutable $txtGodot.Text.Trim();$v=Invoke-FullVerification -ProjectDir $project -GodotExe $godot -RunDir $runDir -Prefix "retry"
        $safety=([bool]$v.Git.Staged -or @($v.Git.SensitivePaths).Count -gt 0)
        $status=if($script:StopRequested){"ABORTED"}elseif($safety){"SAFETY_STOP"}elseif($v.Pass){"DONE"}else{"FAIL"}
        $reason=if($safety){"Safety guard: staged/sensitive changes detected"}elseif($v.Pass){"Gate retry PASS"}else{($v.BlockingReasons -join "; ")}
        Write-RunState -RunDir $runDir -Task ([string]$src.task) -TaskId ([string]$src.taskId) -Stage "QUALITY_GATE" -Status $status -Reason $reason -Project $project -RetryOf $SourceRunDir
        Save-LastGate -ProjectDir $project -Pass ($status -eq 'DONE') -RunDir $runDir -Reason $reason -Status $status -Stage "QUALITY_GATE"
        Write-RunIntegrityManifest -RunDir $runDir
        $script:LastCycleStatus=$status;$script:LastCyclePass=($status -eq 'DONE')
    }catch{
        Add-Log "Retry gate: $($_.Exception.Message)"
        if($runDir -and (Test-Path $runDir)){try{Write-RunState -RunDir $runDir -Task ([string]$src.task) -TaskId ([string]$src.taskId) -Stage "RETRY_GATE" -Status "BLOCKED" -Reason $_.Exception.Message -Project $project -RetryOf $SourceRunDir;Write-RunIntegrityManifest -RunDir $runDir}catch{}}
    }finally{if($locked){Release-RunLock};Set-UiBusy $false;[void](Update-SystemHealth)}
}

function Cleanup-RunHistory {
    $maxRuns=if($null -ne $numMaxRuns){[int]$numMaxRuns.Value}else{100};$maxGB=if($null -ne $numMaxRunGB){[double]$numMaxRunGB.Value}else{5}
    $dirs=@(Get-ChildItem -LiteralPath $RunsDir -Directory -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending)
    $total=0.0;foreach($d in $dirs){$total+=(@(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum)}
    $remove=New-Object System.Collections.Generic.List[object];for($i=0;$i -lt $dirs.Count;$i++){if($i -ge $maxRuns){$remove.Add($dirs[$i])}}
    $target=$maxGB*1GB;$remaining=$total;foreach($d in @($dirs|Sort-Object LastWriteTime)){if($remaining -le $target){break};if($d.FullName -eq $script:LastCycleRunDir){continue};if(-not $remove.Contains($d)){$remove.Add($d)};$size=@(Get-ChildItem -LiteralPath $d.FullName -File -Recurse -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum;$remaining-=$size}
    if($remove.Count -eq 0){[System.Windows.Forms.MessageBox]::Show("Очистка не требуется. Runs: $($dirs.Count), объём: $([math]::Round($total/1GB,2)) ГБ")|Out-Null;return}
    $ans=[System.Windows.Forms.MessageBox]::Show("Удалить $($remove.Count) старых run-каталогов по лимитам: $maxRuns runs / $maxGB ГБ?`r`nТекущий активный run не удаляется.","Очистка логов",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($ans -ne [System.Windows.Forms.DialogResult]::Yes){return};foreach($d in $remove){try{Remove-Item -LiteralPath $d.FullName -Recurse -Force}catch{Add-Log "Не удалось удалить $($d.FullName): $($_.Exception.Message)"}};Update-RunMetrics
}

function Export-DiagnosticsBundle {
    $d=Get-LatestRunDiagnostic;$stamp=Get-Date -Format "yyyyMMdd-HHmmss";$tmp=Join-Path $env:TEMP ("ADB-Diag-"+[guid]::NewGuid().ToString("N"));New-Item -ItemType Directory -Force -Path $tmp|Out-Null
    try{
        $report=Join-Path $tmp "system-health.txt";$h=Get-SystemHealth;$lines=@("Archer Dev Bridge v$BridgeVersion diagnostics","Time: $(Get-Date -Format s)");foreach($n in @("Godot","Codex","Auth","Git","DotNet","Project","Tests","Agents","Astra","Country")){$x=$h.$n;if($x){$lines+="${n}: $($x.State) — $($x.Detail)"}};Write-Utf8File $report ($lines -join "`r`n")
        if($d.HasData -and $d.RunDir -and (Test-Path $d.RunDir)){Copy-Item -LiteralPath $d.RunDir -Destination (Join-Path $tmp "last-run") -Recurse -Force}
        if(Test-Path $SettingsPath){Copy-Item -LiteralPath $SettingsPath -Destination (Join-Path $tmp "settings.json") -Force}
        $zip=Join-Path $DiagnosticsDir ("ArcherDevBridge-Diagnostics-$stamp.zip");if(Test-Path $zip){Remove-Item $zip -Force};Compress-Archive -Path (Join-Path $tmp "*") -DestinationPath $zip -CompressionLevel Optimal
        Start-Process explorer.exe -ArgumentList "/select,`"$zip`""
    }catch{[System.Windows.Forms.MessageBox]::Show("Не удалось создать diagnostics bundle: $($_.Exception.Message)")|Out-Null}finally{Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
}

function Run-PlanOnly {
    if(-not (Assert-SelfDestructCancelled)){return}
    $project=$txtProject.Text.Trim();$task=$txtTask.Text.Trim();if(-not(Test-Path $project) -or -not $task){[System.Windows.Forms.MessageBox]::Show("Выберите проект и введите задачу.")|Out-Null;return}
    if(-not (Test-CodexAuthAllowed).Allowed){[System.Windows.Forms.MessageBox]::Show("Codex auth не готов.")|Out-Null;return}
    Set-UiBusy $true;$script:StopRequested=$false
    try{$stamp=Get-Date -Format "yyyyMMdd-HHmmss";$rd=Join-Path $RunsDir ($stamp+"-plan");New-Item -ItemType Directory -Force -Path $rd|Out-Null;Write-RunState -RunDir $rd -Task $task -TaskId "PLAN" -Stage "PLAN" -Status "RUNNING" -Project $project -RunKind "plan";$ctx=Get-ProjectContextBundle $project;$prompt=@"
You are ASTRA in READ-ONLY PLAN MODE. Do not modify, create, delete, rename, stage or commit files. $(if((Get-OperatorMode) -eq "AI_TEAM"){"Read-only subagents may be used for exploration."}else{"ONE CODEX mode is active: do not spawn or invoke subagents; inspect the repository yourself."}) Return a concrete implementation plan with: scope, files likely affected, architecture constraints, ordered tasks, acceptance criteria, verification, risks. Clearly mark unknowns. User request:
$task

Context:
$ctx
"@;Write-Utf8File (Join-Path $rd "plan-request.txt") $task;$r=Invoke-CodexTask -ProjectDir $project -Prompt $prompt -RunDir $rd -Label "plan" -Model (Get-ComboValue $cmbCodexModel "gpt-6-astra") -ReasoningEffort (Get-ComboValue $cmbCodexReasoning "medium") -Sandbox "read-only";$ps=$(if($r.Aborted){"ABORTED"}elseif($r.ExitCode -eq 0){"DONE"}else{"FAIL"});Write-RunState -RunDir $rd -Task $task -TaskId "PLAN" -Stage "PLAN" -Status $ps -Reason $r.StdErr -Project $project -RunKind "plan";if($r.Final){Write-Utf8File (Join-Path $rd "PLAN.md") $r.Final;Start-Process notepad.exe (Join-Path $rd "PLAN.md")}else{[System.Windows.Forms.MessageBox]::Show("Plan mode завершился без итогового сообщения. Смотрите логи: $rd")|Out-Null}}finally{Set-UiBusy $false}
}

function Get-RunMetrics {
    $pass=0;$fail=0;$other=0;$total=0
    foreach($d in @(Get-ChildItem -LiteralPath $RunsDir -Directory -ErrorAction SilentlyContinue)){$sp=Join-Path $d.FullName "run-state.json";if(-not(Test-Path $sp)){continue};try{$r=Get-Content -Raw -Encoding UTF8 $sp|ConvertFrom-Json;if([int]$r.schemaVersion -lt $RunSchemaVersion -or [string]$r.runKind -ne "task"){continue};$total++;if([string]$r.status -in @("DONE","PASS")){$pass++}elseif([string]$r.status -in @("FAIL","SAFETY_STOP")){$fail++}else{$other++}}catch{}}
    return [pscustomobject]@{Total=$total;Pass=$pass;Fail=$fail;Other=$other}
}

function Update-RunMetrics {
    if($null -eq $lblMetrics){return};$m=Get-RunMetrics;$lblMetrics.Text="RUNS $($m.Total)  •  PASS $($m.Pass)  •  FAIL $($m.Fail)  •  OTHER $($m.Other)"
}

function Write-RunIntegrityManifest {
    param([string]$RunDir)
    if(-not $RunDir -or -not(Test-Path -LiteralPath $RunDir)){return}
    try{
        $lines=New-Object System.Collections.Generic.List[string]
        foreach($f in @(Get-ChildItem -LiteralPath $RunDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'run-manifest.sha256' } | Sort-Object FullName)){
            try{
                $h=Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256
                $rel=$f.FullName.Substring($RunDir.TrimEnd('\\').Length).TrimStart('\\')
                $lines.Add(($h.Hash.ToLowerInvariant()+"  "+$rel))
            }catch{}
        }
        Write-Utf8File (Join-Path $RunDir 'run-manifest.sha256') ($lines -join "`r`n")
    }catch{Add-Log "Run manifest warning: $($_.Exception.Message)"}
}

function Check-Environment {
    Add-Log "=== Проверка окружения Archer 0.6 ==="
    foreach ($toolName in @("codex","git","dotnet")) { [void](Resolve-AndPersistTool $toolName) }
    Add-Log "Operator profile: model=$(Get-ComboValue $cmbCodexModel 'gpt-6-astra'), reasoning=$(Get-ComboValue $cmbCodexReasoning 'medium')"
    foreach ($cmd in @("codex", "git", "dotnet")) {
        $r = Invoke-ProcessCaptured -FileName $cmd -Arguments "--version" -TimeoutSeconds 30
        if ($r.ExitCode -eq 0) { Add-Log ("{0}: {1}" -f $cmd,$r.StdOut.Trim()) }
        else { Add-Log ("{0}: НЕ НАЙДЕН или ошибка: {1}" -f $cmd,$r.StdErr.Trim()) }
    }
    $auth = Get-CodexAuthInfo
    Add-Log "Codex auth: mode=$($auth.Mode); $($auth.Detail)"
    $agents = Ensure-AstraAgentProfiles
    Add-Log "Astra subagents: ready=$($agents.Ready); dir=$AgentProfileDir"
    $country = Get-InternetCountryInfo -Force
    Add-Log "Страна (интернет/IP): $($country.Name) ($($country.Code)); source=$($country.Source)"

    $project = $txtProject.Text.Trim()
    if ($project -and (Test-Path $project)) {
        Add-Log "Проект: $project"
        if (Test-Path (Join-Path $project "project.godot")) { Add-Log "project.godot: найден" } else { Add-Log "project.godot: НЕ найден" }
        $cs = Get-CSharpProjectFile $project
        if ($cs) { Add-Log "C# project: $cs" } else { Add-Log "*.csproj: не найден" }
        $tests = Get-TestProjectFile $project
        if ($tests) { Add-Log "Tests project: $tests" } else { Add-Log "Tests project: не найден" }
        foreach ($name in @("PROJECT_RULES.md", "ARCHITECTURE.md", "AGENTS.md", "PROJECT_CONTEXT.md")) {
            $p = Join-Path $project $name
            if (Test-Path $p) { Add-Log "Instructions: $name найден" }
        }
        $git = Get-GitBaseInfo $project
        if ($git.HasGit) {
            $headShort = if($git.Head){$git.Head.Substring(0,[Math]::Min(8,$git.Head.Length))}else{"?"}
            Add-Log "Git: branch=$($git.Branch), HEAD=$headShort $($git.Subject)"
            if ($git.Status) { Add-Log "Git working tree: DIRTY`r`n$($git.Status.Trim())" } else { Add-Log "Git working tree: clean" }
        } else { Add-Log "Git repository: не обнаружен" }
    }

    $g = Find-GodotExecutable $txtGodot.Text.Trim()
    if ($g) {
        $txtGodot.Text = $g
        $ver = Invoke-ProcessCaptured -FileName $g -Arguments "--version" -TimeoutSeconds 30
        Add-Log "Godot: $g"
        if ($ver.StdOut) { Add-Log "Godot version: $($ver.StdOut.Trim())" }
    } else { Add-Log "Godot: не найден автоматически" }

    if ($chkPlanner.Checked) {
        if (Get-ApiKey) { Add-Log "LEGACY OpenAI API planner/reviewer: включён; отдельная API-тарификация." }
        else { Add-Log "LEGACY API planner/reviewer включён, но API key не задан." }
    } else { Add-Log "LEGACY API planner/reviewer: выключен." }
    [void](Update-SystemHealth -WriteLog)
}

function Run-VerificationOnly {
    if(-not (Assert-SelfDestructCancelled)){return}
    $project = $txtProject.Text.Trim()
    if (-not $project -or -not (Test-Path $project)) { [System.Windows.Forms.MessageBox]::Show("Выберите папку проекта.") | Out-Null; return }
    Save-Settings;Set-UiBusy $true;$script:StopRequested=$false
    try {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss";$runDir = Join-Path $RunsDir ($stamp + "-verify");New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        Write-RunState -RunDir $runDir -Task "Manual Quality Gate" -TaskId "VERIFY" -Stage "QUALITY_GATE" -Status "RUNNING" -Project $project -RunKind "verify"
        $godot = Find-GodotExecutable $txtGodot.Text.Trim();if ($godot) { $txtGodot.Text = $godot }
        $v = Invoke-FullVerification -ProjectDir $project -GodotExe $godot -RunDir $runDir -Prefix "verify"
        $status=if($script:StopRequested){"ABORTED"}elseif($v.Pass){"PASS"}else{"FAIL"};$reason=if($v.Pass){"Manual Quality Gate PASS"}else{($v.BlockingReasons -join "; ")}
        Write-RunState -RunDir $runDir -Task "Manual Quality Gate" -TaskId "VERIFY" -Stage "QUALITY_GATE" -Status $status -Reason $reason -Project $project -RunKind "verify"
        Add-Log "=== Verification result: $status ===";Add-Log "Логи: $runDir"
    } finally { Set-UiBusy $false }
}

function Run-DevelopmentCycle {
    param([string]$TaskOverride = "", [string]$TaskId = "", [bool]$AllowDirtyStart=$false, [string]$RetryOf="", [string]$ParentTaskId="", [string]$TaskType="NORMAL", [bool]$InheritedWorkingTree=$false)
    if(-not (Assert-SelfDestructCancelled)){return}
    $script:LastCyclePass = $false
    $script:LastCycleSafetyStop = $false
    $script:LastCycleRunDir = ""
    $script:LastCycleFailureStage = ""
    $script:LastCycleStatus = "RUNNING"
    $script:StopRequested = $false
    $script:CurrentParentTaskId = $ParentTaskId
    $script:CurrentTaskType = $(if($TaskType){$TaskType}else{"NORMAL"})
    $script:CurrentInheritedWorkingTree = $InheritedWorkingTree
    $project = $txtProject.Text.Trim()
    $task = if($TaskOverride){$TaskOverride.Trim()}else{$txtTask.Text.Trim()}
    if (-not $project -or -not (Test-Path $project)) { [System.Windows.Forms.MessageBox]::Show("Выберите существующую папку проекта.") | Out-Null; return }
    if (-not $task) { [System.Windows.Forms.MessageBox]::Show("Введите задачу для разработки.") | Out-Null; return }
    $health = Update-SystemHealth
    if (-not $script:SystemReady) { [System.Windows.Forms.MessageBox]::Show("Система имеет красные статусы. Нажмите РАЗОБРАТЬСЯ и устраните блокирующие проблемы до запуска задачи.", "Archer Dev Bridge 0.6", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null; return }
    $authGuard = Test-CodexAuthAllowed
    if (-not $authGuard.Allowed) { [System.Windows.Forms.MessageBox]::Show($authGuard.Reason, "Codex Auth Guard", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
    if (-not $AllowDirtyStart -and -not (Confirm-PreviousGate $project)) { return }

    if (-not (Test-Path (Join-Path $project "project.godot"))) {
        $ans = [System.Windows.Forms.MessageBox]::Show("В выбранной папке не найден project.godot. Продолжить?", "Archer Dev Bridge", [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $preGit = Get-GitBaseInfo $project
    if ($chkRequireClean.Checked -and -not $AllowDirtyStart -and $preGit.HasGit -and $preGit.Status) {
        [System.Windows.Forms.MessageBox]::Show("Рабочее дерево Git не чистое. Зафиксируйте/отмените предыдущие изменения либо снимите галочку 'Требовать clean Git перед задачей'.", "Archer Dev Bridge", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    Save-Settings
    $script:DevelopmentInProgress=$true
    Set-UiBusy $true
    $runDir = ""
    try {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $safeTaskId = if($TaskId){($TaskId -replace '[^A-Za-z0-9_-]','_')}else{"manual"}
        $runDir = Join-Path $RunsDir ($stamp + "-" + $safeTaskId)
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        $script:LastCycleRunDir = $runDir
        Write-Utf8File (Join-Path $runDir "user-task.txt") $task
        Write-Utf8File (Join-Path $runDir "run-meta.txt") ("Bridge: $BridgeVersion`r`nRunSchema: $RunSchemaVersion`r`nTaskId: $TaskId`r`nTaskType: $TaskType`r`nParentTaskId: $ParentTaskId`r`nInheritedWorkingTree: $InheritedWorkingTree`r`nRetryOf: $RetryOf`r`nStarted: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`nProject: $project")
        Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "PREPARE" -Status "RUNNING" -Project $project -RetryOf $RetryOf
        $lock=Acquire-RunLock -Project $project -RunDir $runDir -TaskId $TaskId
        if(-not $lock.Acquired){$script:LastCycleStatus="BLOCKED";Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "RUN_LOCK" -Status "BLOCKED" -Reason $lock.Reason -Project $project -RetryOf $RetryOf;Save-LastGate -ProjectDir $project -Pass $false -RunDir $runDir -Reason $lock.Reason -Status "BLOCKED" -Stage "RUN_LOCK";throw "RUN LOCK: $($lock.Reason)"}
        $preflight=Get-PreflightReport -ProjectDir $project -AllowDirtyStart $AllowDirtyStart;Write-Utf8File (Join-Path $runDir "preflight.txt") $preflight.Text
        if(-not $preflight.Pass){$reason=($preflight.Failures -join "; ");$script:LastCycleStatus="BLOCKED";Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "PREFLIGHT" -Status "BLOCKED" -Reason $reason -Project $project -RetryOf $RetryOf;Save-LastGate -ProjectDir $project -Pass $false -RunDir $runDir -Reason $reason -Status "BLOCKED" -Stage "PREFLIGHT";throw "PREFLIGHT BLOCKED: $reason"}
        if($AllowDirtyStart -and $preGit.Status){
            Add-Log "PREFLIGHT: inherited DIRTY разрешён для task=$TaskId parent=$ParentTaskId type=$TaskType. Существующие изменения сохраняются."
            Write-Utf8File (Join-Path $runDir "inherited-working-tree.txt") ("TaskId: $TaskId`r`nTaskType: $TaskType`r`nParentTaskId: $ParentTaskId`r`nRetryOf: $RetryOf`r`nInherited status:`r`n$($preGit.Status)")
        }
        Save-GitBaseline -Project $project -RunDir $runDir -GitInfo $preGit

        Add-Log "=== Новый цикл разработки $stamp / $safeTaskId ==="
        Add-Log "Проект: $project"
        Add-Log "Git base: $($preGit.Branch) $($preGit.Head) $($preGit.Subject)"
        Write-Utf8File (Join-Path $runDir "git-before.txt") ("Branch: $($preGit.Branch)`r`nHEAD: $($preGit.Head)`r`nCommit: $($preGit.Subject)`r`nStatus:`r`n$($preGit.Status)")

        $context = Get-ProjectContextBundle $project
        Write-Utf8File (Join-Path $runDir "context-bundle.md") $context

        $operatorMode = Get-OperatorMode
        $plannerSpec = $(if($operatorMode -eq "AI_TEAM"){"Legacy API planner is disabled. Astra Operator must plan locally, orchestrate subagents, implement, review, and return mandatory OPERATOR_* markers."}else{"Legacy API planner is disabled. ONE CODEX mode: Astra Operator must work as the sole coding agent, must not invoke subagents, must plan/implement/self-review locally, and return mandatory OPERATOR_* markers with SUBAGENTS_USED: NONE."})
        if ($chkPlanner.Checked) {
            $key = Get-ApiKey
            if (-not $key) { throw "Включён GPT-планировщик, но OPENAI_API_KEY не задан. API тарифицируется отдельно от ChatGPT." }
            $model = $txtApiModel.Text.Trim(); if (-not $model) { $model = "gpt-5.6-sol" }
            Add-Log "GPT-планировщик через API: $model"
            $plannerInstructions = @"
You are the software architect for a Godot 4 .NET/C# multiplayer-ready game repository. Convert the user's request into a precise implementation specification for a local Codex coding agent. Repository documents PROJECT_RULES.md, ARCHITECTURE.md and AGENTS.md are mandatory when included. Preserve server-authoritative boundaries. Do not invent unrelated roadmap features. Include acceptance criteria and exact verification steps. Explicitly say not to commit or push. Keep the specification actionable and concise.
"@
            $plannerInput = "REPOSITORY CONTEXT:`r`n$context`r`n`r`nUSER REQUEST:`r`n$task"
            $plannerSpec = Invoke-OpenAIPlanner -ApiKey $key -Model $model -Effort (Get-ComboValue $cmbApiReasoning "medium") -Instructions $plannerInstructions -InputText $plannerInput
            Write-Utf8File (Join-Path $runDir "planner-spec.txt") $plannerSpec
            Add-Log "ТЗ сформировано GPT-планировщиком."
        }

        $codexPrompt = Build-CodexPrompt -UserTask $task -PlannerSpec $plannerSpec -Context $context -OperatorMode $operatorMode
        Write-Utf8File (Join-Path $runDir "codex-prompt.txt") $codexPrompt
        $codexModel=Get-ComboValue $cmbCodexModel "gpt-6-astra"; $codexReasoning=Get-ComboValue $cmbCodexReasoning "medium"
        Write-Utf8File (Join-Path $runDir "codex-profile.txt") ("Model: $codexModel`r`nReasoning: $codexReasoning`r`nOperatorMode: $operatorMode")
        Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "CODEX" -Status "RUNNING" -Project $project -RetryOf $RetryOf
        $codex = Invoke-CodexTask -ProjectDir $project -Prompt $codexPrompt -RunDir $runDir -Label "main" -Model $codexModel -ReasoningEffort $codexReasoning
        $effectiveCodex = $codex
        if ($codex.ExitCode -ne 0) { $script:LastCycleFailureStage=$(if($codex.TimedOut){"WATCHDOG"}else{"CODEX"}); Add-Log "Codex завершился с кодом $($codex.ExitCode)." }
        Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "CODEX" -Status $(if($codex.Aborted){"ABORTED"}elseif($codex.ExitCode -eq 0){"PASS"}else{"FAIL"}) -Reason $(if($codex.Aborted){"Stopped by user"}elseif($codex.ExitCode -eq 0){""}else{"Codex exit=$($codex.ExitCode)"}) -Project $project -RetryOf $RetryOf
        if($codex.Aborted){throw "__ADB_ABORTED__"}
        if ($codex.Final) { Add-Log "Codex final:`r`n$($codex.Final.Trim())" }
        $codexInputEncodingFailure = ($codex.ExitCode -ne 0 -and ([string]$codex.StdErr -match '(?i)Failed to read prompt from stdin|input is not valid UTF-8'))
        $operatorDecision = Get-OperatorDecision $codex.Final
        $operatorReviewPass = $true
        $operatorNeedsReview = $false
        $operatorBlocked = $false
        $environmentBlocked = $false
        $operatorBlocker = 'NONE'
        $manualReleaseReview = $false
        if ($codex.ExitCode -eq 0) {
            $operatorReviewPass = [bool]$operatorDecision.ReviewPass
            $operatorBlocked = [bool]$operatorDecision.Blocked
            $manualReleaseReview = [bool]$operatorDecision.ManualReleaseReview
            $operatorNeedsReview = [bool]$operatorDecision.NeedsReview -or (($operatorDecision.Review -eq 'UNKNOWN') -and -not $operatorBlocked)
            $environmentBlocked = ([bool]$operatorDecision.EnvironmentBlocked -and -not $manualReleaseReview)
            $operatorBlocker = [string]$operatorDecision.Blocker
            switch ($operatorDecision.Review) {
                'PASS' { Add-Log 'Astra Operator review marker: PASS.' }
                'NEEDS_FIX' { Add-Log 'Astra Operator review marker: NEEDS_FIX — source repair may be allowed when no stronger blocker suppresses it.' }
                'NEEDS_REVIEW' { Add-Log 'Astra Operator review marker: NEEDS_REVIEW — auto-repair запрещён; требуется review/решение.' }
                default { Add-Log 'Astra Operator review marker: отсутствует/неизвестен — auto-repair не запускается только из-за отсутствующего маркера.' }
            }
            if ($manualReleaseReview) { Add-Log ("MANUAL RELEASE REVIEW: {0}. Structured Astra decision has priority; historical environment text is ignored." -f $operatorBlocker) }
            elseif ($environmentBlocked) { Add-Log ("ENVIRONMENT BLOCKER: {0}. Source auto-repair disabled." -f $operatorBlocker) }
        } else {
            Add-Log "Astra Operator review: SKIPPED — Codex process failed before a valid final response."
            if ($codexInputEncodingFailure) {
                $script:LastCycleFailureStage = "CODEX_INPUT_ENCODING"
                Add-Log "CODEX INPUT ENCODING FAILURE: prompt transport was rejected as non-UTF-8. Auto-repair skipped because this is a Bridge transport error, not a project-code error."
            }
        }

        $godot = Find-GodotExecutable $txtGodot.Text.Trim()
        if ($godot) { $txtGodot.Text = $godot }
        Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "QUALITY_GATE" -Status "RUNNING" -Project $project -RetryOf $RetryOf
        $verification = Invoke-FullVerification -ProjectDir $project -GodotExe $godot -RunDir $runDir -Prefix "main"
        if($verification.Git.Staged){$script:LastCycleSafetyStop=$true;$script:LastCycleFailureStage="SAFETY_STOP";Add-Log "SAFETY STOP: обнаружены staged changes. Авто-repair запрещён."}
        if(@($verification.Git.SensitivePaths).Count -gt 0){$script:LastCycleSafetyStop=$true;$script:LastCycleFailureStage="SAFETY_STOP";Add-Log ("SAFETY STOP: Sensitive File Guard: "+($verification.Git.SensitivePaths -join ", "))}
        if(-not $verification.Pass -and -not $script:LastCycleFailureStage){$script:LastCycleFailureStage="QUALITY_GATE"}

        $operatorEvidence = @([string]$codex.Final,[string]$codex.StdOut,[string]$codex.StdErr,(Get-VerificationSummary $verification),(@($verification.BlockingReasons) -join "`r`n")) -join "`r`n"
        $evidenceDecision = Get-OperatorDecision $operatorEvidence
        if ($operatorDecision.HasStructuredDecision) {
            # Structured final output is authoritative. Combined stdout/stderr may contain
            # historical release reports (including old NU1301) and must not replace it.
            if ($evidenceDecision.Blocker -ne $operatorDecision.Blocker -or $evidenceDecision.ReleaseStatus -ne $operatorDecision.ReleaseStatus) {
                Add-Log ("STRUCTURED PRECEDENCE: ignored evidence fallback {0}/{1}; keeping {2}/{3}." -f $evidenceDecision.ReleaseStatus,$evidenceDecision.Blocker,$operatorDecision.ReleaseStatus,$operatorDecision.Blocker)
            }
        } elseif ($evidenceDecision.EnvironmentBlocked) {
            $environmentBlocked = $true
            if ([string]$evidenceDecision.Blocker -and [string]$evidenceDecision.Blocker -ne 'NONE') { $operatorBlocker = [string]$evidenceDecision.Blocker }
            $script:LastCycleFailureStage = 'ENVIRONMENT_BLOCKER'
            Add-Log ("ENVIRONMENT_BLOCKER: {0}; project source auto-repair suppressed." -f $operatorBlocker)
        }

        $postGitBase = Get-GitBaseInfo $project
        $headChanged = ($preGit.HasGit -and $postGitBase.HasGit -and $preGit.Head -ne $postGitBase.Head)
        if ($headChanged) {
            Add-Log "КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ: HEAD изменился во время цикла. Codex/инструмент создал commit или переключил состояние Git. Автоматический rollback НЕ выполняется."
            $verification.Pass = $false
            $script:LastCycleSafetyStop = $true
        }

        Add-Log "=== Изменения Git ==="
        if ($verification.Git.Status) { Add-Log $verification.Git.Status.Trim() } else { Add-Log "git status: чисто" }
        if ($verification.Git.Stat) { Add-Log $verification.Git.Stat.Trim() }

        $review = ""
        $reviewPass = $true
        if ($chkPlanner.Checked) {
            Add-Log "=== GPT-ревью через API ==="
            $key = Get-ApiKey
            $model = $txtApiModel.Text.Trim(); if (-not $model) { $model = "gpt-5.6-sol" }
            $reviewInstructions = @"
You are the independent reviewer of a Godot 4 .NET/C# change made by Codex. Repository architecture documents are mandatory. Use only the supplied evidence. First line MUST be exactly either 'RESULT: PASS' or 'RESULT: NEEDS_FIX'. Then provide concise sections: concrete issues, architecture compliance, verification status, and next action. Do not invent test results. A build passing is not enough if architecture or requested behavior is wrong.
"@
            $reviewInput = @"
REPOSITORY CONTEXT:
$context

USER TASK:
$task

ARCHITECT SPEC:
$plannerSpec

CODEX FINAL:
$($codex.Final)

VERIFICATION:
$(Get-VerificationSummary $verification)

GIT STATUS:
$($verification.Git.Status)

GIT DIFF STAT:
$($verification.Git.Stat)

TRACKED DIFF (possibly truncated):
$($verification.Git.Diff)

UNTRACKED TEXT FILES (possibly truncated):
$($verification.Git.UntrackedReview)
"@
            $review = Invoke-OpenAIPlanner -ApiKey $key -Model $model -Effort (Get-ComboValue $cmbApiReasoning "medium") -Instructions $reviewInstructions -InputText $reviewInput
            Write-Utf8File (Join-Path $runDir "gpt-review.txt") $review
            Add-Log $review.Trim()
            $reviewPass = Get-ReviewPass $review
        }

        $gatePass = ($codex.ExitCode -eq 0 -and $verification.Pass -and -not $headChanged -and $operatorReviewPass -and $reviewPass -and -not $operatorNeedsReview -and -not $environmentBlocked -and -not $operatorBlocked)
        $hasTaskChanges = -not [string]::IsNullOrWhiteSpace([string]$verification.Git.Status)
        $operatorPreconditionBlocked = ($codex.ExitCode -eq 0 -and $operatorBlocked -and -not $hasTaskChanges -and $verification.Pass -and -not $environmentBlocked)
        $verifiedTimeoutCandidate = ($codex.TimedOut -and $hasTaskChanges -and $verification.Pass -and -not $headChanged -and -not $script:LastCycleSafetyStop -and $reviewPass)
        $operatorExplicitNoRepair = ($null -ne $operatorDecision.RepairSource -and -not [bool]$operatorDecision.RepairSource)
        $sourceRepairRequested = ((-not $verification.Pass) -or [bool]$operatorDecision.NeedsFix -or (-not $reviewPass))
        if($codex.TimedOut -and -not $hasTaskChanges){$script:LastCycleFailureStage='CODEX_TIMEOUT_NO_CHANGES';Add-Log 'CODEX_TIMEOUT_NO_CHANGES: watchdog сработал до появления изменений; автоматический repair пропущен.'}
        elseif($verifiedTimeoutCandidate){$script:LastCycleFailureStage='CODEX_TIMEOUT_VERIFIED';Add-Log 'CODEX_TIMEOUT_VERIFIED: Codex не завершил final response, но Build/Tests/Godot/Git Safety прошли. Auto-repair пропущен; требуется ручное принятие или review-only.'}
        elseif($manualReleaseReview){$script:LastCycleFailureStage='WAITING_MANUAL_RELEASE_CHECK';Add-Log ("WAITING_MANUAL_RELEASE_CHECK: {0}. Auto-repair исходников пропущен; требуется ручная проверка экспортированного билда." -f $operatorBlocker)}
        elseif($environmentBlocked){$script:LastCycleFailureStage='ENVIRONMENT_BLOCKER';Add-Log ("BLOCKED_ENVIRONMENT: {0}. Auto-repair исходников пропущен." -f $operatorBlocker)}
        elseif($operatorNeedsReview){$script:LastCycleFailureStage='OPERATOR_NEEDS_REVIEW';Add-Log 'OPERATOR_NEEDS_REVIEW: это не NEEDS_FIX; auto-repair пропущен.'}
        elseif($operatorPreconditionBlocked){$script:LastCycleFailureStage='OPERATOR_PRECONDITION';Add-Log 'OPERATOR_PRECONDITION: Astra заблокировала старт до изменения файлов при полностью PASS локальной проверке. Auto-repair пропущен — это не дефект кода проекта.'}

        if ($chkAutoRepair.Checked -and -not $gatePass -and $sourceRepairRequested -and -not $operatorNeedsReview -and -not $operatorBlocked -and -not $environmentBlocked -and -not $operatorExplicitNoRepair -and -not $operatorPreconditionBlocked -and -not $script:LastCycleSafetyStop -and -not $script:StopRequested -and -not $codexInputEncodingFailure -and -not $codex.TimedOut) {
            Add-Log "=== Один автоматический repair-цикл Codex ==="
            $repairPrompt = @"
The previous implementation did not pass the quality gate. Fix ONLY the concrete failures shown below while preserving the user's requested scope and repository architecture. Do not add unrelated features. Do not commit, push, reset, rebase or clean. Re-run safe checks after the fix. $(if($operatorMode -eq "AI_TEAM"){"Use archer_explorer/archer_worker/archer_reviewer when useful."}else{"ONE CODEX mode is active: do not spawn or invoke subagents; perform the focused repair and self-review yourself."}) Return the mandatory OPERATOR_RESULT and OPERATOR_REVIEW markers.

ORIGINAL USER TASK:
$task

ARCHITECT SPEC:
$plannerSpec

LOCAL VERIFICATION:
$(Get-VerificationSummary $verification)

GPT REVIEW:
$review
"@
            Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage "REPAIR" -Status "RUNNING" -Project $project -RetryOf $RetryOf
            $repair = Invoke-CodexTask -ProjectDir $project -Prompt $repairPrompt -RunDir $runDir -Label "repair1" -Model $codexModel -ReasoningEffort $codexReasoning
            $effectiveCodex = $repair
            if($repair.Aborted){throw "__ADB_ABORTED__"}
            Add-Log "Repair Codex exit=$($repair.ExitCode)"
            $operatorDecision = Get-OperatorDecision $repair.Final
            $operatorReviewPass = $true
            $operatorNeedsReview = $false
            $operatorBlocked = $false
            $environmentBlocked = $false
            $operatorBlocker = 'NONE'
            $manualReleaseReview = $false
            if ($repair.ExitCode -eq 0) {
                $operatorReviewPass = [bool]$operatorDecision.ReviewPass
                $operatorBlocked = [bool]$operatorDecision.Blocked
                $manualReleaseReview = [bool]$operatorDecision.ManualReleaseReview
                $operatorNeedsReview = [bool]$operatorDecision.NeedsReview -or (($operatorDecision.Review -eq 'UNKNOWN') -and -not $operatorBlocked)
                $environmentBlocked = ([bool]$operatorDecision.EnvironmentBlocked -and -not $manualReleaseReview)
                $operatorBlocker = [string]$operatorDecision.Blocker
                switch ($operatorDecision.Review) {
                    'PASS' { Add-Log 'Repair Astra review marker: PASS.' }
                    'NEEDS_FIX' { Add-Log 'Repair Astra review marker: NEEDS_FIX.' }
                    'NEEDS_REVIEW' { Add-Log 'Repair Astra review marker: NEEDS_REVIEW — additional source auto-repair is not allowed.' }
                    default { Add-Log 'Repair Astra review marker: отсутствует/неизвестен — требуется review.' }
                }
            } else {
                Add-Log "Repair Astra review: SKIPPED — repair Codex process failed before a valid final response."
            }

            $verification = Invoke-FullVerification -ProjectDir $project -GodotExe $godot -RunDir $runDir -Prefix "repair1"
            if($verification.Git.Staged){$script:LastCycleSafetyStop=$true;$script:LastCycleFailureStage="SAFETY_STOP";Add-Log "SAFETY STOP: repair оставил staged changes."}
            if(@($verification.Git.SensitivePaths).Count -gt 0){$script:LastCycleSafetyStop=$true;$script:LastCycleFailureStage="SAFETY_STOP";Add-Log ("SAFETY STOP: repair затронул защищённые файлы: "+($verification.Git.SensitivePaths -join ", "))}
            $repairEvidence = @([string]$repair.Final,[string]$repair.StdOut,[string]$repair.StdErr,(Get-VerificationSummary $verification),(@($verification.BlockingReasons) -join "`r`n")) -join "`r`n"
            $repairEvidenceDecision = Get-OperatorDecision $repairEvidence
            if ($operatorDecision.HasStructuredDecision) {
                if ($repairEvidenceDecision.Blocker -ne $operatorDecision.Blocker -or $repairEvidenceDecision.ReleaseStatus -ne $operatorDecision.ReleaseStatus) {
                    Add-Log ("STRUCTURED PRECEDENCE (repair): ignored evidence fallback {0}/{1}; keeping {2}/{3}." -f $repairEvidenceDecision.ReleaseStatus,$repairEvidenceDecision.Blocker,$operatorDecision.ReleaseStatus,$operatorDecision.Blocker)
                }
            } elseif ($repairEvidenceDecision.EnvironmentBlocked) {
                $environmentBlocked = $true
                if ([string]$repairEvidenceDecision.Blocker -and [string]$repairEvidenceDecision.Blocker -ne 'NONE') { $operatorBlocker = [string]$repairEvidenceDecision.Blocker }
                $script:LastCycleFailureStage = 'ENVIRONMENT_BLOCKER'
                Add-Log ("BLOCKED_ENVIRONMENT after repair: {0}." -f $operatorBlocker)
            }
            $postRepairBase = Get-GitBaseInfo $project
            $postGitBase = $postRepairBase
            $headChanged = ($preGit.HasGit -and $postRepairBase.HasGit -and $preGit.Head -ne $postRepairBase.Head)
            if ($headChanged) { $script:LastCycleSafetyStop = $true; Add-Log "SAFETY STOP: Git HEAD изменился после repair. Дальнейший авто-ремонт запрещён." }

            $review = ""
            $reviewPass = $true
            if ($chkPlanner.Checked) {
                $key = Get-ApiKey
                $model = $txtApiModel.Text.Trim(); if (-not $model) { $model = "gpt-5.6-sol" }
                $reviewInput2 = @"
REPOSITORY CONTEXT:
$context

USER TASK:
$task

ARCHITECT SPEC:
$plannerSpec

REPAIR CODEX FINAL:
$($repair.Final)

VERIFICATION AFTER REPAIR:
$(Get-VerificationSummary $verification)

GIT STATUS:
$($verification.Git.Status)

GIT DIFF STAT:
$($verification.Git.Stat)

TRACKED DIFF:
$($verification.Git.Diff)

UNTRACKED TEXT FILES:
$($verification.Git.UntrackedReview)
"@
                $reviewInstructions2 = "First line MUST be exactly RESULT: PASS or RESULT: NEEDS_FIX. Review the repaired Godot/C# change against the user task and mandatory repository architecture. Use only supplied evidence."
                $review = Invoke-OpenAIPlanner -ApiKey $key -Model $model -Effort (Get-ComboValue $cmbApiReasoning "medium") -Instructions $reviewInstructions2 -InputText $reviewInput2
                Write-Utf8File (Join-Path $runDir "gpt-review-after-repair.txt") $review
                Add-Log $review.Trim()
                $reviewPass = Get-ReviewPass $review
            }
            $gatePass = ($repair.ExitCode -eq 0 -and $verification.Pass -and -not $headChanged -and $operatorReviewPass -and $reviewPass -and -not $operatorNeedsReview -and -not $environmentBlocked -and -not $operatorBlocked)
        }

        $gateReason = "PASS"
        if (-not $gatePass) {
            if($environmentBlocked){
                $gateReason = "Environment blocker: $operatorBlocker. Project source repair suppressed."
            } elseif($manualReleaseReview){
                $gateReason = "Manual release verification required: $operatorBlocker. Source checks PASS; exported UI/profile evidence must be confirmed by the user."
            } elseif($verifiedTimeoutCandidate){
                $gateReason = "Codex watchdog timeout; local Build/Tests/Godot/Git verification PASS. Manual accept or review-only required."
            } elseif($operatorNeedsReview){
                $gateReason = "Astra Operator returned NEEDS_REVIEW or an unknown review marker. This is not NEEDS_FIX; source auto-repair is suppressed."
            } elseif($operatorPreconditionBlocked -or $operatorBlocked){
                $gateReason = "Astra Operator returned BLOCKED. Source auto-repair is suppressed unless a concrete source failure is reported separately."
            } else {
                $reasons = New-Object System.Collections.Generic.List[string]
                if ($codexInputEncodingFailure) { $reasons.Add("Bridge→Codex prompt transport rejected as non-UTF-8") }
                elseif ($effectiveCodex.ExitCode -ne 0) { $reasons.Add("Codex exit=$($effectiveCodex.ExitCode)") }
                if (-not $verification.Pass) { $reasons.Add("local verification failed") }
                if ($headChanged) { $reasons.Add("Git HEAD changed unexpectedly — SAFETY STOP") }
                if ($operatorDecision.NeedsFix) { $reasons.Add("Astra operator review: NEEDS_FIX") }
                elseif (-not $operatorReviewPass) { $reasons.Add("Astra operator review marker unknown") }
                if (-not $reviewPass) { $reasons.Add("Legacy GPT API review NEEDS_FIX/unknown") }
                $gateReason = ($reasons -join "; ")
            }
        }

        $changeMap=Write-ChangeMap -Project $project -RunDir $runDir
        Add-Log "Change map: +$($changeMap.added) ~$($changeMap.modified) -$($changeMap.deleted), new=$($changeMap.untrackedCreated), sensitive=$($changeMap.sensitiveCount)"
        if($changeMap.sensitiveCount -gt 0){$script:LastCycleSafetyStop=$true;$verifiedTimeoutCandidate=$false;$gatePass=$false;$gateReason="Sensitive File Guard: изменены защищённые файлы: "+($changeMap.sensitivePaths -join ", ");Add-Log "SAFETY STOP: $gateReason"}

        $sourceStatus = [string]$operatorDecision.SourceStatus
        if (-not $sourceStatus -or $sourceStatus -eq 'UNKNOWN') {
            if ($gatePass -or ($environmentBlocked -and $verification.Pass -and -not $headChanged -and -not $script:LastCycleSafetyStop)) { $sourceStatus = 'PASS' }
            elseif ($operatorDecision.NeedsFix) { $sourceStatus = 'NEEDS_FIX' }
            else { $sourceStatus = 'UNKNOWN' }
        }
        $releaseStatus = if($manualReleaseReview){'NEEDS_REVIEW'}elseif($environmentBlocked){'BLOCKED_ENVIRONMENT'}elseif($gatePass){'READY'}elseif($verifiedTimeoutCandidate -or $operatorNeedsReview){'NEEDS_REVIEW'}elseif($operatorBlocked -or $operatorPreconditionBlocked){'BLOCKED'}else{'UNKNOWN'}
        $repairSourceFinal = if($manualReleaseReview -or $environmentBlocked -or $operatorNeedsReview -or $operatorBlocked -or $operatorPreconditionBlocked){$false}elseif($operatorDecision.NeedsFix -or -not $verification.Pass -or -not $reviewPass){$true}else{$false}
        $classifiedResult = if($gatePass){'PASS'}elseif($script:LastCycleSafetyStop){'SAFETY_STOP'}elseif($environmentBlocked){'BLOCKED_ENVIRONMENT'}elseif($manualReleaseReview -or $verifiedTimeoutCandidate -or $operatorNeedsReview){'NEEDS_REVIEW'}elseif($operatorBlocked -or $operatorPreconditionBlocked){'BLOCKED'}else{'FAIL'}

        $gateSummary = @"
Archer Dev Bridge v$BridgeVersion quality gate
Project: $project
Task: $task
Result: $classifiedResult
Source status: $sourceStatus
Release status: $releaseStatus
Blocker: $operatorBlocker
Repair source: $repairSourceFinal
Reason: $gateReason
Git base: $($preGit.Branch) $($preGit.Head) $($preGit.Subject)
Git HEAD after: $($postGitBase.Head)
Codex model: $codexModel
Codex reasoning: $codexReasoning
Operator mode: $operatorMode
Codex exit: $($effectiveCodex.ExitCode)
Build: $($verification.BuildState), exit=$($verification.Build.ExitCode)
Tests: $($verification.TestsState), exit=$($verification.Tests.ExitCode)
Godot editor: $($verification.GodotEditorState), exit=$($verification.GodotEditor.ExitCode)
Godot client: $($verification.GodotClientState), exit=$($verification.GodotClient.ExitCode)
Godot server: $($verification.GodotServerState), exit=$($verification.GodotServer.ExitCode)
Git diff check: $($verification.GitState), exit=$($verification.Git.DiffCheckExit)
Astra operator review pass: $operatorReviewPass
Legacy API review pass: $reviewPass
Safety stop: $script:LastCycleSafetyStop
No commit was intentionally created by the bridge.
"@
        Write-Utf8File (Join-Path $runDir "gate-summary.txt") $gateSummary
        $finalStage = if($gatePass){"DONE"}elseif($script:LastCycleSafetyStop){"SAFETY_STOP"}elseif($environmentBlocked){"ENVIRONMENT_BLOCKER"}elseif($manualReleaseReview){"WAITING_MANUAL_RELEASE_CHECK"}elseif($verifiedTimeoutCandidate){"CODEX_TIMEOUT_VERIFIED"}elseif($operatorNeedsReview){"OPERATOR_NEEDS_REVIEW"}elseif($operatorPreconditionBlocked -or $operatorBlocked){"OPERATOR_BLOCKED"}elseif($script:LastCycleFailureStage){$script:LastCycleFailureStage}else{"QUALITY_GATE"}
        if($verifiedTimeoutCandidate -or $operatorNeedsReview){
            $needsReviewEvidence = @"
Archer Dev Bridge v$BridgeVersion needs-review summary
Stage: $finalStage
Reason: $gateReason
Codex exit: $($effectiveCodex.ExitCode)
Build: $($verification.BuildState)
Tests: $($verification.TestsState)
Godot editor/client/server: $($verification.GodotEditorState)/$($verification.GodotClientState)/$($verification.GodotServerState)
Git diff check: $($verification.GitState)

$(if($manualReleaseReview){"MANUAL RELEASE CHECK REQUIRED: exported gameplay / clean-profile Continue / input-audio-layout evidence.`r`nПРИНЯТЬ GATE доступен только после ручной проверки экспортированного EXE.`r`n"}else{""})
Choose: ПРИНЯТЬ GATE / REVIEW ONLY / ОТКЛОНИТЬ
"@
            Write-Utf8File (Join-Path $runDir "needs-review-summary.txt") $needsReviewEvidence
        } elseif(-not $gatePass){
            $failureEvidence = @"
Archer Dev Bridge v$BridgeVersion failure summary
Stage: $finalStage
Reason: $gateReason
Codex exit: $($effectiveCodex.ExitCode)
Codex stderr:
$($effectiveCodex.StdErr)

Codex stdout:
$($effectiveCodex.StdOut)

Verification blockers:
$($verification.BlockingReasons -join "`r`n")
"@
            Write-Utf8File (Join-Path $runDir "failure-summary.txt") $failureEvidence
        }
        $finalStatus=if($script:StopRequested){"ABORTED"}elseif($gatePass){"DONE"}elseif($script:LastCycleSafetyStop){"SAFETY_STOP"}elseif($environmentBlocked){"BLOCKED_ENVIRONMENT"}elseif($manualReleaseReview -or $verifiedTimeoutCandidate -or $operatorNeedsReview){"NEEDS_REVIEW"}elseif($operatorPreconditionBlocked -or $operatorBlocked){"BLOCKED"}else{"FAIL"}
        Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage $finalStage -Status $finalStatus -Reason $gateReason -Project $project -RetryOf $RetryOf
        Save-LastGate -ProjectDir $project -Pass $gatePass -RunDir $runDir -Reason $gateReason -Status $finalStatus -Stage $finalStage
        Write-RunIntegrityManifest -RunDir $runDir
        $script:LastCyclePass = $gatePass
        $script:LastCycleStatus = $finalStatus

        Add-Log "=== QUALITY GATE: $classifiedResult ==="
        Add-Log $gateReason
        Add-Log "Classification: SOURCE_STATUS=$sourceStatus; RELEASE_STATUS=$releaseStatus; BLOCKER=$operatorBlocker; REPAIR_SOURCE=$repairSourceFinal"
        Add-Log "Логи: $runDir"
        if ($gatePass) {
            Add-Log "Изменения готовы к ручному просмотру. Bridge не делает commit/push."
        } elseif($environmentBlocked) {
            Add-Log "Исходники не отправляются в repair-loop. Сначала устраните блокер среды/публикации, затем повторите gate/export."
        } elseif($manualReleaseReview) {
            Add-Log "WAITING_MANUAL_RELEASE_CHECK: исходники PASS. Проверьте экспортированный EXE вручную, затем выберите ПРИНЯТЬ GATE. REVIEW ONLY не заменяет ручной UI/profile check."
        } elseif($verifiedTimeoutCandidate -or $operatorNeedsReview) {
            Add-Log "Статус NEEDS_REVIEW сохранён отдельно от NEEDS_FIX. Выберите ПРИНЯТЬ GATE, REVIEW ONLY или ОТКЛОНИТЬ после проверки доказательств."
        } elseif($operatorBlocked) {
            Add-Log "Статус BLOCKED сохранён отдельно от дефекта исходников. Авто-repair не запускается без конкретного source failure."
        } else {
            Add-Log "Следующий этап не считается готовым. Исправьте конкретные ошибки/NEEDS_FIX до перехода дальше."
        }
    }
    catch {
        $script:LastCyclePass = $false
        $isAbort=($_.Exception.Message -eq "__ADB_ABORTED__" -or $script:StopRequested)
        $isBlocked=($_.Exception.Message -like "PREFLIGHT BLOCKED:*" -or $_.Exception.Message -like "RUN LOCK:*")
        if($isAbort){$script:LastCycleStatus="ABORTED";$script:LastCycleFailureStage="STOP"}
        elseif($isBlocked){$script:LastCycleStatus="BLOCKED";if(-not $script:LastCycleFailureStage){$script:LastCycleFailureStage="PREFLIGHT"}}
        else{$script:LastCycleStatus="FAIL";if(-not $script:LastCycleFailureStage){$script:LastCycleFailureStage="EXCEPTION"}}
        $errText = $_ | Out-String
        Add-Log $(if($isAbort){"Задача остановлена пользователем."}elseif($isBlocked){$_.Exception.Message}else{"ОШИБКА: $($_.Exception.Message)"})
        if($runDir -and (Test-Path -LiteralPath $runDir)){
            try {
                Write-Utf8File (Join-Path $runDir "exception.txt") $errText
                Write-Utf8File (Join-Path $runDir "failure-summary.txt") ("Stage: $($script:LastCycleFailureStage)`r`nReason: $($_.Exception.Message)`r`n`r`n$errText")
                Write-RunState -RunDir $runDir -Task $task -TaskId $TaskId -Stage $script:LastCycleFailureStage -Status $script:LastCycleStatus -Reason $_.Exception.Message -Project $project -RetryOf $RetryOf
                Write-RunIntegrityManifest -RunDir $runDir
            } catch {}
        }
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Archer Dev Bridge") | Out-Null
        try { Save-LastGate -ProjectDir $project -Pass $false -RunDir $runDir -Reason $_.Exception.Message -Status $script:LastCycleStatus -Stage $script:LastCycleFailureStage } catch {}
    }
    finally {
        Release-RunLock
        $script:DevelopmentInProgress=$false
        if(-not $script:QueueInProgress){
            Force-UiIdle -Reason "development cycle finished"
            try{[void](Update-SystemHealth)}catch{}
            if($script:LastCycleStatus -and $script:LastCycleStatus -ne "RUNNING"){Start-CompletionSignal -Status $script:LastCycleStatus -TaskId $(if($TaskId){$TaskId}else{"MANUAL"})}
            Schedule-UiIdleRecovery -Reason "development cycle post-return"
        }
        $script:CurrentParentTaskId = ""
        $script:CurrentTaskType = "NORMAL"
        $script:CurrentInheritedWorkingTree = $false
    }
}

# --- Task Queue -----------------------------------------------------------------
function Get-QueueItemMeta {
    param($Item)
    $defaults=[ordered]@{taskType="NORMAL";parentTaskId="";inheritedWorkingTree=$false;parentRunDir="";recoveryReason="";dependsOnTaskId="";requiresBase=$false;baseConfirmed=$false;baselineHead=""}
    if($null -eq $Item){return [pscustomobject]$defaults}
    try {
        if($Item.Tag){
            $m=$Item.Tag
            return [pscustomobject]@{
                taskType=$(if($m.taskType){[string]$m.taskType}else{"NORMAL"})
                parentTaskId=$(if($m.parentTaskId){[string]$m.parentTaskId}else{[string]""})
                inheritedWorkingTree=[bool]$m.inheritedWorkingTree
                parentRunDir=$(if($m.parentRunDir){[string]$m.parentRunDir}else{[string]""})
                recoveryReason=$(if($m.recoveryReason){[string]$m.recoveryReason}else{[string]""})
                dependsOnTaskId=$(if($m.dependsOnTaskId){[string]$m.dependsOnTaskId}else{[string]""})
                requiresBase=[bool]$m.requiresBase
                baseConfirmed=[bool]$m.baseConfirmed
                baselineHead=$(if($m.baselineHead){[string]$m.baselineHead}else{[string]""})
            }
        }
    } catch {}
    return [pscustomobject]$defaults
}

function Test-TargetedRepairTaskText {
    param([string]$Task)
    if(-not $Task){return $false}
    $head=$Task.Substring(0,[Math]::Min($Task.Length,700))
    return ($head -match '(?i)TARGETED\s+(REVIEW\s+)?FIX|TARGETED[_ -]?REPAIR|REVIEW\s+FIX|ТОЧЕЧН\w*\s+(ИСПРАВ|FIX)|ИСПРАВИТЬ\s+ТОЛЬКО\s+НАЙДЕНН')
}

function Get-ExplicitParentTaskId {
    param([string]$Task)
    if(-not $Task){return ""}
    $head=$Task.Substring(0,[Math]::Min($Task.Length,300))
    $m=[regex]::Match($head,'(?i)\bT\d{3}\b')
    if($m.Success){return $m.Value.ToUpperInvariant()}
    return ""
}

function Find-QueueItemById {
    param([string]$TaskId)
    if(-not $TaskId -or $null -eq $lstQueue){return $null}
    foreach($it in $lstQueue.Items){if([string]$it.Text -eq $TaskId){return $it}}
    return $null
}

function Get-LastQueueItem {
    if($null -eq $lstQueue -or $lstQueue.Items.Count -eq 0){return $null}
    return $lstQueue.Items[$lstQueue.Items.Count-1]
}

function Set-QueueDependencyCell {
    param($Item,[string]$Dependency="")
    if($null -eq $Item){return}
    try {
        while($Item.SubItems.Count -lt 4){[void]$Item.SubItems.Add("")}
        $Item.SubItems[3].Text=$Dependency
    } catch {}
}

function Test-RoadmapDependencySatisfied {
    param([string]$TaskId)
    if(-not $TaskId){return $true}
    $parent=Find-QueueItemById $TaskId
    if($null -eq $parent){return $false}
    $status=[string]$parent.SubItems[1].Text
    $pm=Get-QueueItemMeta $parent
    # A roadmap dependency is satisfied only after the previous task passed AND
    # the user explicitly confirmed its BASE. A clean working tree alone is not BASE evidence.
    if($status -notin @("DONE","PASS") -or -not [bool]$pm.baseConfirmed){return $false}
    try {
        $project=$txtProject.Text.Trim()
        if(-not $project){return $false}
        $d=Get-GitWorkingTreeDetails $project
        if($d.Dirty){return $false}
        if($pm.baselineHead){
            $gitPath=Resolve-AndPersistTool "git"
            if(-not $gitPath){return $false}
            $h=Invoke-ProcessCaptured -FileName $gitPath -Arguments "rev-parse --short HEAD" -WorkingDirectory $project -TimeoutSeconds 30
            if($h.ExitCode -ne 0 -or $h.StdOut.Trim() -ne [string]$pm.baselineHead){return $false}
        }
    } catch { return $false }
    return $true
}

function Test-HasRoadmapDependent {
    param([string]$TaskId)
    if(-not $TaskId -or $null -eq $lstQueue){return $false}
    foreach($it in $lstQueue.Items){
        $m=Get-QueueItemMeta $it
        if($m.requiresBase -and [string]$m.dependsOnTaskId -eq $TaskId){return $true}
    }
    return $false
}

function Reconcile-RoadmapQueue {
    if($null -eq $lstQueue){return}
    $changed=$false
    $gitClean=$false
    try {
        $project=$txtProject.Text.Trim()
        if($project){$gitClean=-not (Get-GitWorkingTreeDetails $project).Dirty}
    } catch {}
    foreach($it in $lstQueue.Items){
        $m=Get-QueueItemMeta $it
        Set-QueueDependencyCell -Item $it -Dependency $m.dependsOnTaskId
        if(-not $m.requiresBase -or -not $m.dependsOnTaskId){continue}
        $parent=Find-QueueItemById $m.dependsOnTaskId
        if($null -ne $parent){
            $pm=Get-QueueItemMeta $parent
            $ps=[string]$parent.SubItems[1].Text
            # 0.6.7 recovery: a DONE/PASS parent without explicit BASE confirmation
            # must wait for the user's BASE acknowledgement before its child can run.
            if($ps -in @("DONE","PASS") -and -not [bool]$pm.baseConfirmed){
                $parent.SubItems[1].Text="DONE_WAIT_BASE"
                $pm.baseConfirmed=$false
                $parent.Tag=$pm
                $changed=$true
            }
        }
        $s=[string]$it.SubItems[1].Text
        $ready=Test-RoadmapDependencySatisfied $m.dependsOnTaskId
        if($ready -and $s -eq "WAITING_BASE"){$it.SubItems[1].Text="QUEUED";$changed=$true}
        elseif(-not $ready -and $s -in @("QUEUED","RETRY")){$it.SubItems[1].Text="WAITING_BASE";$changed=$true}
        elseif(-not $ready -and $gitClean -and $s -in @("FAIL","BLOCKED")){
            # If 0.6.7 wrongly launched a dependent task before BASE confirmation and it
            # produced no working-tree changes, restore the intended WAITING_BASE state.
            $it.SubItems[1].Text="WAITING_BASE";$changed=$true
            Add-Log "ROADMAP RECOVERY 0.6.8: $($it.Text) возвращена в WAITING_BASE; зависимость $($m.dependsOnTaskId) не была подтверждена как BASE."
        }
    }
    if($changed){Save-TaskQueue}
}

function Confirm-RoadmapBaseCommit {
    param([string]$Head="")
    if($null -eq $lstQueue){return $null}
    # Normalize legacy/recovered queue states BEFORE searching for the pending BASE.
    # This makes a single click sufficient even if the parent was still DONE/PASS
    # when Git Inspector was opened.
    Reconcile-RoadmapQueue
    $candidate=$null
    for($i=$lstQueue.Items.Count-1;$i -ge 0;$i--){
        $it=$lstQueue.Items[$i]
        if([string]$it.SubItems[1].Text -eq "DONE_WAIT_BASE"){$candidate=$it;break}
    }
    if($null -eq $candidate){return $null}
    $candidate.SubItems[1].Text="DONE"
    $m=Get-QueueItemMeta $candidate
    $m.baseConfirmed=$true
    $m.baselineHead=$Head
    $candidate.Tag=$m
    $unlocked=New-Object System.Collections.Generic.List[string]
    foreach($it in $lstQueue.Items){
        $cm=Get-QueueItemMeta $it
        if($cm.requiresBase -and [string]$cm.dependsOnTaskId -eq [string]$candidate.Text -and [string]$it.SubItems[1].Text -eq "WAITING_BASE"){
            $it.SubItems[1].Text="QUEUED"
            $unlocked.Add([string]$it.Text)
        }
    }
    Save-TaskQueue
    $u=if($unlocked.Count -gt 0){$unlocked -join ', '}else{'нет'}
    Add-Log "ROADMAP BASE: $($candidate.Text) подтверждён commit=$Head; разблокированы: $u."
    return [pscustomobject]@{TaskId=[string]$candidate.Text;Unlocked=@($unlocked)}
}

function Find-RepairParentCandidate {
    param([string]$Task)
    $explicit=Get-ExplicitParentTaskId $Task
    if($explicit -and (Find-QueueItemById $explicit)){return $explicit}
    try {
        if($lstQueue.SelectedItems.Count -gt 0){
            $s=$lstQueue.SelectedItems[0]
            if([string]$s.SubItems[1].Text -in @("FAIL","BLOCKED","BLOCKED_ENVIRONMENT","NEEDS_REVIEW","REVIEW_NEEDS_FIX","INTERRUPTED","ABORTED")){return [string]$s.Text}
        }
        for($i=$lstQueue.Items.Count-1;$i -ge 0;$i--){
            $it=$lstQueue.Items[$i];$st=[string]$it.SubItems[1].Text
            if($st -in @("FAIL","BLOCKED","BLOCKED_ENVIRONMENT","NEEDS_REVIEW","REVIEW_NEEDS_FIX","INTERRUPTED","ABORTED")){return [string]$it.Text}
        }
    } catch {}
    return ""
}

function Resolve-QueueTaskMeta {
    param([string]$Task,$Existing=$null)
    if($Existing){
        $old=Get-QueueItemMeta $Existing
        if($old.taskType -ne "NORMAL" -or $old.parentTaskId){return $old}
    }
    if(Test-TargetedRepairTaskText $Task){
        $parent=Find-RepairParentCandidate $Task
        $parentRun=""
        if($parent){
            $pit=Find-QueueItemById $parent
            $ptask=$(if($pit){[string]$pit.SubItems[2].Text}else{""})
            $src=Get-LatestFailedRunForQueueTask -TaskId $parent -Task $ptask
            if($src){$parentRun=[string]$src.RunDir}
        }
        return [pscustomobject]@{taskType="TARGETED_REPAIR";parentTaskId=$parent;inheritedWorkingTree=[bool]$parent;parentRunDir=$parentRun;recoveryReason="";dependsOnTaskId="";requiresBase=$false;baseConfirmed=$false;baselineHead=""}
    }
    return [pscustomobject]@{taskType="NORMAL";parentTaskId="";inheritedWorkingTree=$false;parentRunDir="";recoveryReason="";dependsOnTaskId="";requiresBase=$false;baseConfirmed=$false;baselineHead=""}
}

function Save-TaskQueue {
    if ($null -eq $lstQueue) { return }
    try {
        $items = @()
        foreach ($it in $lstQueue.Items) {
            $m=Get-QueueItemMeta $it
            $items += [pscustomobject]@{
                id=$it.Text; status=$it.SubItems[1].Text; task=$it.SubItems[2].Text
                taskType=$m.taskType; parentTaskId=$m.parentTaskId
                inheritedWorkingTree=[bool]$m.inheritedWorkingTree; parentRunDir=$m.parentRunDir
                recoveryReason=$m.recoveryReason; dependsOnTaskId=$m.dependsOnTaskId
                requiresBase=[bool]$m.requiresBase; baseConfirmed=[bool]$m.baseConfirmed; baselineHead=$m.baselineHead
            }
        }
        ConvertTo-Json -InputObject $items -Depth 5 | Set-Content -Encoding UTF8 $TaskQueuePath
    } catch { Add-Log "Не удалось сохранить очередь: $($_.Exception.Message)" }
}

function Load-TaskQueue {
    if ($null -eq $lstQueue -or -not (Test-Path $TaskQueuePath)) { return }
    $changed=$false
    try {
        $data = Get-Content -Raw -Encoding UTF8 $TaskQueuePath | ConvertFrom-Json
        foreach ($q in @($data)) {
            if (-not $q.task) { continue }
            $status=$(if($q.status){[string]$q.status}else{"QUEUED"})
            if($status -eq "RUNNING"){$status="BLOCKED";$changed=$true}
            $item = New-Object System.Windows.Forms.ListViewItem([string]$q.id)
            [void]$item.SubItems.Add($status)
            [void]$item.SubItems.Add([string]$q.task)
            [void]$item.SubItems.Add($(if($q.dependsOnTaskId){[string]$q.dependsOnTaskId}else{""}))
            $meta=[pscustomobject]@{
                taskType=$(if($q.taskType){[string]$q.taskType}else{"NORMAL"})
                parentTaskId=$(if($q.parentTaskId){[string]$q.parentTaskId}else{""})
                inheritedWorkingTree=[bool]$q.inheritedWorkingTree
                parentRunDir=$(if($q.parentRunDir){[string]$q.parentRunDir}else{""})
                recoveryReason=$(if($q.recoveryReason){[string]$q.recoveryReason}else{if($status -eq "BLOCKED"){"Recovered stale RUNNING after Bridge restart"}else{""}})
                dependsOnTaskId=$(if($q.dependsOnTaskId){[string]$q.dependsOnTaskId}else{""})
                requiresBase=[bool]$q.requiresBase
                baseConfirmed=[bool]$q.baseConfirmed
                baselineHead=$(if($q.baselineHead){[string]$q.baselineHead}else{""})
            }
            $item.Tag=$meta
            [void]$lstQueue.Items.Add($item)
        }
        # Migrate legacy repair rows after all parent rows are present.
        foreach($item in $lstQueue.Items){
            $m=Get-QueueItemMeta $item
            if($m.taskType -eq "NORMAL" -and (Test-TargetedRepairTaskText ([string]$item.SubItems[2].Text))){
                $item.Tag=Resolve-QueueTaskMeta -Task ([string]$item.SubItems[2].Text) -Existing $item
                $changed=$true
            }
        }
        if($changed){Save-TaskQueue;Add-Log "Очередь: восстановлены/мигрированы repair-задачи; stale RUNNING переведён в BLOCKED."}
        Reconcile-RoadmapQueue
    } catch { Add-Log "Не удалось загрузить очередь задач: $($_.Exception.Message)" }
}

function Add-CurrentTaskToQueue {
    try {
        $task = $txtTask.Text.Trim()
        if (-not $task) { [System.Windows.Forms.MessageBox]::Show("Введите задачу перед добавлением в очередь.") | Out-Null; return }
        $next=1;foreach($q in $lstQueue.Items){if($q.Text -match "^T(\d+)$"){$n=[int]$Matches[1];if($n -ge $next){$next=$n+1}}}
        $meta=Resolve-QueueTaskMeta -Task $task
        $status="QUEUED"
        if($meta.taskType -eq "NORMAL" -and $null -ne $chkRoadmapDependency -and $chkRoadmapDependency.Checked){
            $parent=Get-LastQueueItem
            if($null -ne $parent){
                $meta.dependsOnTaskId=[string]$parent.Text
                $meta.requiresBase=$true
                $ready=Test-RoadmapDependencySatisfied $meta.dependsOnTaskId
                if(-not $ready){
                    $status="WAITING_BASE"
                    if([string]$parent.SubItems[1].Text -in @("DONE","PASS")){
                        $parent.SubItems[1].Text="DONE_WAIT_BASE"
                        $pm=Get-QueueItemMeta $parent;$pm.baseConfirmed=$false;$parent.Tag=$pm
                    }
                }
            }
        }
        $item = New-Object System.Windows.Forms.ListViewItem(("T{0:000}" -f $next))
        [void]$item.SubItems.Add($status)
        [void]$item.SubItems.Add(($task -replace "`r?`n"," "))
        [void]$item.SubItems.Add([string]$meta.dependsOnTaskId)
        $item.Tag=$meta
        [void]$lstQueue.Items.Add($item)
        Save-TaskQueue
        if($meta.taskType -eq "TARGETED_REPAIR"){
            Add-Log "Очередь: добавлена repair-задача $($item.Text), parent=$($meta.parentTaskId), inherited DIRTY=$($meta.inheritedWorkingTree)."
        } elseif($meta.requiresBase) {
            Add-Log "ROADMAP: добавлена $($item.Text), зависит от BASE $($meta.dependsOnTaskId), статус=$status."
        } else { Add-Log "Очередь: добавлена задача $($item.Text)." }
    } catch {
        Add-Log "Очередь: ошибка добавления задачи — $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Не удалось добавить задачу в очередь.`r`n`r`n$($_.Exception.Message)","Archer Dev Bridge — очередь",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

function Remove-SelectedQueueTask {
    if ($lstQueue.SelectedItems.Count -eq 0) { return }
    foreach ($it in @($lstQueue.SelectedItems)) { $lstQueue.Items.Remove($it) }
    Save-TaskQueue
}

function Clear-TaskQueue {
    if ($lstQueue.Items.Count -eq 0) { return }
    $ans=[System.Windows.Forms.MessageBox]::Show("Очистить очередь задач?","Archer Dev Bridge",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if($ans -eq [System.Windows.Forms.DialogResult]::Yes){$lstQueue.Items.Clear();Save-TaskQueue}
}

function Run-TaskQueue {
    if(-not (Assert-SelfDestructCancelled)){return}
    Reconcile-RoadmapQueue
    $queued = @($lstQueue.Items | Where-Object { $_.SubItems[1].Text -in @("QUEUED","RETRY") })
    if ($queued.Count -eq 0) {
        $waiting=@($lstQueue.Items|Where-Object{$_.SubItems[1].Text -eq "WAITING_BASE"})
        if($waiting.Count -gt 0){
            [System.Windows.Forms.MessageBox]::Show("Следующий ROADMAP-этап ждёт BASE предыдущей задачи.`r`n`r`nПроверьте Git → создайте BASE commit → после этого зависимая задача станет QUEUED.","Archer Dev Bridge — ROADMAP QUEUE",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)|Out-Null
        } else {[System.Windows.Forms.MessageBox]::Show("В очереди нет задач со статусом QUEUED/RETRY.") | Out-Null}
        return
    }
    $script:QueueInProgress=$true
    Set-UiBusy $true
    try {
        foreach ($it in $queued) {
            if($script:StopRequested){break}
            $meta=Get-QueueItemMeta $it
            if($meta.requiresBase -and $meta.dependsOnTaskId -and -not (Test-RoadmapDependencySatisfied $meta.dependsOnTaskId)){
                $it.SubItems[1].Text="WAITING_BASE";Save-TaskQueue
                Add-Log "ROADMAP PAUSE: $($it.Text) ждёт BASE задачи $($meta.dependsOnTaskId)."
                break
            }
            if($meta.taskType -eq "NORMAL" -and (Test-TargetedRepairTaskText ([string]$it.SubItems[2].Text))){
                $meta=Resolve-QueueTaskMeta -Task ([string]$it.SubItems[2].Text) -Existing $it
                $it.Tag=$meta;Save-TaskQueue
            }
            $allowDirty=[bool]($meta.taskType -eq "TARGETED_REPAIR" -and $meta.inheritedWorkingTree)
            $retryOf=[string]$meta.parentRunDir
            if($allowDirty -and -not $retryOf -and $meta.parentTaskId){
                $pit=Find-QueueItemById $meta.parentTaskId
                $ptask=$(if($pit){[string]$pit.SubItems[2].Text}else{""})
                $src=Get-LatestFailedRunForQueueTask -TaskId $meta.parentTaskId -Task $ptask
                if($src){$retryOf=[string]$src.RunDir;$meta.parentRunDir=$retryOf;$it.Tag=$meta;Save-TaskQueue}
            }
            $it.SubItems[1].Text="RUNNING"; Save-TaskQueue; [System.Windows.Forms.Application]::DoEvents()
            Add-Log "=== QUEUE $($it.Text): RUNNING ==="
            if($allowDirty){Add-Log "QUEUE LINEAGE: $($it.Text) type=TARGETED_REPAIR parent=$($meta.parentTaskId); inherited DIRTY разрешён только для этой repair-задачи."}
            $taskForRun=[string]$it.SubItems[2].Text
            if($meta.requiresBase -and $meta.dependsOnTaskId){
                $parent=Find-QueueItemById $meta.dependsOnTaskId
                $pm=$(if($parent){Get-QueueItemMeta $parent}else{$null})
                $parentStatus=$(if($parent){[string]$parent.SubItems[1].Text}else{"UNKNOWN"})
                $depEvidence=@"

ARCHER DEV BRIDGE VERIFIED ROADMAP PRECONDITION (trusted orchestration evidence):
- Previous task: $($meta.dependsOnTaskId)
- Previous task status: $parentStatus (Quality Gate passed)
- BASE explicitly confirmed by user: $([bool]$pm.baseConfirmed)
- BASE HEAD: $([string]$pm.baselineHead)
- Git working tree: CLEAN (validated immediately before queue execution)
Treat this prerequisite as SATISFIED. Do not ask the user to reconfirm the previous gate/BASE. Proceed with the requested implementation.
"@
                $taskForRun += $depEvidence
                Add-Log "ROADMAP EVIDENCE: $($it.Text) получает подтверждение $($meta.dependsOnTaskId): Gate PASS + BASE=$([bool]$pm.baseConfirmed) + CLEAN Git."
            }
            Run-DevelopmentCycle -TaskOverride $taskForRun -TaskId $it.Text -AllowDirtyStart $allowDirty -RetryOf $retryOf -ParentTaskId $meta.parentTaskId -TaskType $meta.taskType -InheritedWorkingTree $allowDirty
            $status=if($script:LastCycleStatus){$script:LastCycleStatus}else{if($script:LastCyclePass){"DONE"}else{"FAIL"}}
            if($status -eq "RUNNING"){
                $status="BLOCKED"
                $meta.recoveryReason="Cycle returned before run start/completion; status normalized from RUNNING to BLOCKED"
                $it.Tag=$meta
                Add-Log "QUEUE RECOVERY: $($it.Text) вернулся без финального статуса; RUNNING → BLOCKED."
            }
            if($status -in @("DONE","PASS") -and (Test-HasRoadmapDependent $it.Text)){
                $status="DONE_WAIT_BASE"
                $meta.baseConfirmed=$false
                $it.Tag=$meta
            }
            $it.SubItems[1].Text=$status; Save-TaskQueue
            Start-CompletionSignal -Status $status -TaskId ([string]$it.Text)
            if($status -eq "DONE_WAIT_BASE"){
                Add-Log "ROADMAP PAUSE: $($it.Text) успешно завершена и ждёт ручной BASE commit. Следующий этап не будет запущен автоматически."
                break
            }
            if($status -notin @("DONE","PASS")){
                Add-Log "Очередь остановлена: задача $($it.Text) = $status."
                break
            }
            Add-Log "=== QUEUE $($it.Text): DONE ==="
            if ($chkRequireClean.Checked) {
                $g=Get-GitBaseInfo $txtProject.Text.Trim()
                if ($g.Status) { Add-Log "Безопасная пауза очереди: после PASS остались незакоммиченные изменения. Просмотрите их перед следующей задачей."; break }
            }
        }
    } catch {
        Add-Log "QUEUE ERROR: $($_.Exception.Message)"
        try{
            $q=Get-SelectedQueueTaskInfo
            if($q -and $q.Status -eq "RUNNING"){$q.Item.SubItems[1].Text="BLOCKED";Save-TaskQueue}
        }catch{}
    } finally {
        $script:QueueInProgress=$false
        $script:DevelopmentInProgress=$false
        Release-RunLock
        Force-UiIdle -Reason "queue finished"
        try{[void](Update-SystemHealth)}catch{}
        Apply-SelfDestructTaskLock
        Schedule-UiIdleRecovery -Reason "queue post-return"
    }
}

# ---------------- UI ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Archer Nakodil // Dev Bridge v$BridgeVersion — Astra Operator 0.6"
$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formWidth = [Math]::Min(1280, [Math]::Max(1040, $workingArea.Width - 30))
$formHeight = [Math]::Min(920, [Math]::Max(780, $workingArea.Height - 30))
$form.Size = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1040, 780)
$form.BackColor = [System.Drawing.Color]::FromArgb(15,21,29)
$form.ForeColor = [System.Drawing.Color]::FromArgb(232,238,245)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$C_BG=[System.Drawing.Color]::FromArgb(15,21,29)
$C_PANEL=[System.Drawing.Color]::FromArgb(24,34,47)
$C_PANEL2=[System.Drawing.Color]::FromArgb(18,26,36)
$C_TEXT=[System.Drawing.Color]::FromArgb(232,238,245)
$C_MUTED=[System.Drawing.Color]::FromArgb(154,169,186)
$C_ACCENT=[System.Drawing.Color]::FromArgb(243,156,18)
$C_BLUE=[System.Drawing.Color]::FromArgb(51,181,229)

function Style-ArcherButton {
    param($Button,[bool]$Primary=$false)
    $Button.FlatStyle=[System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize=1
    $Button.FlatAppearance.BorderColor=$(if($Primary){$C_ACCENT}else{[System.Drawing.Color]::FromArgb(69,86,105)})
    $Button.BackColor=$(if($Primary){[System.Drawing.Color]::FromArgb(99,62,8)}else{[System.Drawing.Color]::FromArgb(34,48,65)})
    $Button.ForeColor=$C_TEXT
    $Button.Cursor=[System.Windows.Forms.Cursors]::Hand
}
function Style-ArcherInput { param($Control) $Control.BackColor=[System.Drawing.Color]::FromArgb(10,15,21); $Control.ForeColor=$C_TEXT }
function Style-ArcherGroup { param($Group) $Group.ForeColor=$C_TEXT; $Group.BackColor=$C_PANEL }

# Header
$pnlHeader=New-Object System.Windows.Forms.Panel
$pnlHeader.Location=New-Object System.Drawing.Point(0,0); $pnlHeader.Size=New-Object System.Drawing.Size(1264,72); $pnlHeader.Anchor="Top,Left,Right"; $pnlHeader.BackColor=[System.Drawing.Color]::FromArgb(20,28,39); $form.Controls.Add($pnlHeader)
$pnlAccent=New-Object System.Windows.Forms.Panel
$pnlAccent.Location=New-Object System.Drawing.Point(0,0); $pnlAccent.Size=New-Object System.Drawing.Size(7,72); $pnlAccent.BackColor=$C_ACCENT; $pnlHeader.Controls.Add($pnlAccent)
$lblBrand=New-Object System.Windows.Forms.Label
$lblBrand.Text="ARCHER NAKODIL // DEV BRIDGE"; $lblBrand.Location=New-Object System.Drawing.Point(22,12); $lblBrand.AutoSize=$true; $lblBrand.Font=New-Object System.Drawing.Font("Segoe UI Semibold",17,[System.Drawing.FontStyle]::Bold); $lblBrand.ForeColor=$C_TEXT; $pnlHeader.Controls.Add($lblBrand)
$lblVersion=New-Object System.Windows.Forms.Label
$lblVersion.Text="v$BridgeVersion  •  ASTRA OPERATOR / STABILITY CORE"; $lblVersion.Location=New-Object System.Drawing.Point(25,44); $lblVersion.AutoSize=$true; $lblVersion.ForeColor=$C_ACCENT; $lblVersion.Font=New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold); $pnlHeader.Controls.Add($lblVersion)
$lblMetrics=New-Object System.Windows.Forms.Label; $lblMetrics.Text="RUNS 0  •  PASS 0  •  FAIL 0"; $lblMetrics.Location=New-Object System.Drawing.Point(430,44); $lblMetrics.Size=New-Object System.Drawing.Size(400,18); $lblMetrics.ForeColor=$C_MUTED; $pnlHeader.Controls.Add($lblMetrics)
$btnAckSignal=New-Object System.Windows.Forms.Button; $btnAckSignal.Text="СИГНАЛ ПРИНЯТ"; $btnAckSignal.Location=New-Object System.Drawing.Point(430,9); $btnAckSignal.Size=New-Object System.Drawing.Size(215,29); $btnAckSignal.Font=New-Object System.Drawing.Font("Segoe UI",8,[System.Drawing.FontStyle]::Bold); Style-ArcherButton $btnAckSignal; $btnAckSignal.Enabled=$false; $btnAckSignal.Add_Click({Acknowledge-CompletionSignal}); $pnlHeader.Controls.Add($btnAckSignal)
$picSelfDestruct=New-Object System.Windows.Forms.PictureBox; $picSelfDestruct.Location=New-Object System.Drawing.Point(660,10); $picSelfDestruct.Size=New-Object System.Drawing.Size(24,24); $picSelfDestruct.SizeMode=[System.Windows.Forms.PictureBoxSizeMode]::Zoom; $picSelfDestruct.BackColor=[System.Drawing.Color]::Transparent; $pnlHeader.Controls.Add($picSelfDestruct)
$lblSelfDestruct=New-Object System.Windows.Forms.Label; $lblSelfDestruct.Text="АВТОЗАКРЫТИЕ ЧЕРЕЗ 00:30"; $lblSelfDestruct.Location=New-Object System.Drawing.Point(690,9); $lblSelfDestruct.Size=New-Object System.Drawing.Size(300,27); $lblSelfDestruct.TextAlign="MiddleLeft"; $lblSelfDestruct.ForeColor=[System.Drawing.Color]::FromArgb(255,80,80); $lblSelfDestruct.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $pnlHeader.Controls.Add($lblSelfDestruct)
$picCountry=New-Object System.Windows.Forms.PictureBox
$picCountry.Location=New-Object System.Drawing.Point(1040,22); $picCountry.Size=New-Object System.Drawing.Size(18,18); $picCountry.SizeMode=[System.Windows.Forms.PictureBoxSizeMode]::Zoom; $picCountry.Anchor="Top,Right"; $picCountry.BackColor=[System.Drawing.Color]::Transparent; $pnlHeader.Controls.Add($picCountry)
$lblCountry=New-Object System.Windows.Forms.Label
$lblCountry.Text="СТРАНА: определение..."; $lblCountry.Location=New-Object System.Drawing.Point(1062,18); $lblCountry.Size=New-Object System.Drawing.Size(173,26); $lblCountry.TextAlign="MiddleRight"; $lblCountry.Anchor="Top,Right"; $lblCountry.ForeColor=$C_BLUE; $lblCountry.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $pnlHeader.Controls.Add($lblCountry)
$lblPrivacy=New-Object System.Windows.Forms.Label
$lblPrivacy.Text="Интернет • внешний IP • без GPS/координат"; $lblPrivacy.Location=New-Object System.Drawing.Point(900,43); $lblPrivacy.Size=New-Object System.Drawing.Size(335,18); $lblPrivacy.TextAlign="MiddleRight"; $lblPrivacy.Anchor="Top,Right"; $lblPrivacy.ForeColor=$C_MUTED; $pnlHeader.Controls.Add($lblPrivacy)

# Configuration
$grpConfig=New-Object System.Windows.Forms.GroupBox
$grpConfig.Text="КОНФИГУРАЦИЯ / OPERATOR PROFILE"; $grpConfig.Location=New-Object System.Drawing.Point(18,82); $grpConfig.Size=New-Object System.Drawing.Size(1225,187); $grpConfig.Anchor="Top,Left,Right"; Style-ArcherGroup $grpConfig; $form.Controls.Add($grpConfig)

$lblProject=New-Object System.Windows.Forms.Label; $lblProject.Text="Godot проект:"; $lblProject.Location=New-Object System.Drawing.Point(14,28); $lblProject.AutoSize=$true; $grpConfig.Controls.Add($lblProject)
$txtProject=New-Object System.Windows.Forms.TextBox; $txtProject.Location=New-Object System.Drawing.Point(120,24); $txtProject.Size=New-Object System.Drawing.Size(965,25); $txtProject.Anchor="Top,Left,Right"; Style-ArcherInput $txtProject; $grpConfig.Controls.Add($txtProject)
$btnBrowseProject=New-Object System.Windows.Forms.Button; $btnBrowseProject.Text="..."; $btnBrowseProject.Location=New-Object System.Drawing.Point(1095,22); $btnBrowseProject.Size=New-Object System.Drawing.Size(105,28); $btnBrowseProject.Anchor="Top,Right"; Style-ArcherButton $btnBrowseProject; $grpConfig.Controls.Add($btnBrowseProject)
$btnBrowseProject.Add_Click({$dlg=New-Object System.Windows.Forms.FolderBrowserDialog;$dlg.Description="Выберите корень Godot-проекта";if($txtProject.Text -and (Test-Path $txtProject.Text)){$dlg.SelectedPath=$txtProject.Text};if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$txtProject.Text=$dlg.SelectedPath;Save-Settings;[void](Update-SystemHealth)}})

$lblGodot=New-Object System.Windows.Forms.Label; $lblGodot.Text="Godot .NET:"; $lblGodot.Location=New-Object System.Drawing.Point(14,61); $lblGodot.AutoSize=$true; $grpConfig.Controls.Add($lblGodot)
$txtGodot=New-Object System.Windows.Forms.TextBox; $txtGodot.Location=New-Object System.Drawing.Point(120,57); $txtGodot.Size=New-Object System.Drawing.Size(825,25); $txtGodot.Anchor="Top,Left,Right"; Style-ArcherInput $txtGodot; $grpConfig.Controls.Add($txtGodot)
$btnDetectGodot=New-Object System.Windows.Forms.Button; $btnDetectGodot.Text="НАЙТИ"; $btnDetectGodot.Location=New-Object System.Drawing.Point(955,55); $btnDetectGodot.Size=New-Object System.Drawing.Size(90,28); $btnDetectGodot.Anchor="Top,Right"; Style-ArcherButton $btnDetectGodot; $grpConfig.Controls.Add($btnDetectGodot)
$btnBrowseGodot=New-Object System.Windows.Forms.Button; $btnBrowseGodot.Text="..."; $btnBrowseGodot.Location=New-Object System.Drawing.Point(1055,55); $btnBrowseGodot.Size=New-Object System.Drawing.Size(145,28); $btnBrowseGodot.Anchor="Top,Right"; Style-ArcherButton $btnBrowseGodot; $grpConfig.Controls.Add($btnBrowseGodot)
$btnDetectGodot.Add_Click({$g=Find-GodotExecutable $txtGodot.Text.Trim();if($g){$txtGodot.Text=$g;Save-Settings;Add-Log "Godot найден: $g";[void](Update-SystemHealth)}else{[System.Windows.Forms.MessageBox]::Show("Godot не найден автоматически.")|Out-Null}})
$btnBrowseGodot.Add_Click({$dlg=New-Object System.Windows.Forms.OpenFileDialog;$dlg.Filter="Executable (*.exe)|*.exe|All files (*.*)|*.*";if($txtGodot.Text -and (Test-Path $txtGodot.Text)){$dlg.FileName=$txtGodot.Text};if($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){$txtGodot.Text=$dlg.FileName;Save-Settings;[void](Update-SystemHealth)}})

$lblCodexModel=New-Object System.Windows.Forms.Label; $lblCodexModel.Text="ASTRA operator:"; $lblCodexModel.Location=New-Object System.Drawing.Point(14,94); $lblCodexModel.AutoSize=$true; $grpConfig.Controls.Add($lblCodexModel)
$cmbCodexModel=New-Object System.Windows.Forms.ComboBox; $cmbCodexModel.Location=New-Object System.Drawing.Point(120,90); $cmbCodexModel.Size=New-Object System.Drawing.Size(180,25); $cmbCodexModel.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDown; [void]$cmbCodexModel.Items.AddRange(@("gpt-6-astra","gpt-5.6-sol","gpt-5.6-terra","gpt-5.6-luna")); $cmbCodexModel.Text="gpt-6-astra"; Style-ArcherInput $cmbCodexModel; $grpConfig.Controls.Add($cmbCodexModel)
$lblCodexReasoning=New-Object System.Windows.Forms.Label; $lblCodexReasoning.Text="Reasoning:"; $lblCodexReasoning.Location=New-Object System.Drawing.Point(312,94); $lblCodexReasoning.AutoSize=$true; $grpConfig.Controls.Add($lblCodexReasoning)
$cmbCodexReasoning=New-Object System.Windows.Forms.ComboBox; $cmbCodexReasoning.Location=New-Object System.Drawing.Point(382,90); $cmbCodexReasoning.Size=New-Object System.Drawing.Size(100,25); $cmbCodexReasoning.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList; [void]$cmbCodexReasoning.Items.AddRange(@("low","medium","high","xhigh","max")); $cmbCodexReasoning.SelectedItem="medium"; Style-ArcherInput $cmbCodexReasoning; $grpConfig.Controls.Add($cmbCodexReasoning)
$lblOperatorMode=New-Object System.Windows.Forms.Label; $lblOperatorMode.Text="Режим:"; $lblOperatorMode.Location=New-Object System.Drawing.Point(500,94); $lblOperatorMode.AutoSize=$true; $grpConfig.Controls.Add($lblOperatorMode)
$cmbOperatorMode=New-Object System.Windows.Forms.ComboBox; $cmbOperatorMode.Location=New-Object System.Drawing.Point(555,90); $cmbOperatorMode.Size=New-Object System.Drawing.Size(205,25); $cmbOperatorMode.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList; [void]$cmbOperatorMode.Items.AddRange(@("ASTRA + ONE CODEX","ASTRA + AI TEAM")); $cmbOperatorMode.SelectedItem="ASTRA + ONE CODEX"; Style-ArcherInput $cmbOperatorMode; $grpConfig.Controls.Add($cmbOperatorMode)
$chkAllowApiAuth=New-Object System.Windows.Forms.CheckBox; $chkAllowApiAuth.Text="Разрешить Codex API-auth (отдельная тарификация)"; $chkAllowApiAuth.Location=New-Object System.Drawing.Point(775,90); $chkAllowApiAuth.Size=New-Object System.Drawing.Size(425,25); $chkAllowApiAuth.Checked=$false; $grpConfig.Controls.Add($chkAllowApiAuth)

$chkAutoRepair=New-Object System.Windows.Forms.CheckBox; $chkAutoRepair.Text="1 авто repair при FAIL"; $chkAutoRepair.Location=New-Object System.Drawing.Point(18,124); $chkAutoRepair.Size=New-Object System.Drawing.Size(185,24); $chkAutoRepair.Checked=$true; $grpConfig.Controls.Add($chkAutoRepair)
$chkRequireClean=New-Object System.Windows.Forms.CheckBox; $chkRequireClean.Text="Требовать чистый Git"; $chkRequireClean.Location=New-Object System.Drawing.Point(215,124); $chkRequireClean.Size=New-Object System.Drawing.Size(190,24); $chkRequireClean.Checked=$true; $grpConfig.Controls.Add($chkRequireClean)
$chkTests=New-Object System.Windows.Forms.CheckBox; $chkTests.Text="Project/lifecycle tests"; $chkTests.Location=New-Object System.Drawing.Point(415,124); $chkTests.Size=New-Object System.Drawing.Size(180,24); $chkTests.Checked=$true; $grpConfig.Controls.Add($chkTests)
$chkGodotSmoke=New-Object System.Windows.Forms.CheckBox; $chkGodotSmoke.Text="Godot smoke x3"; $chkGodotSmoke.Location=New-Object System.Drawing.Point(605,124); $chkGodotSmoke.Size=New-Object System.Drawing.Size(150,24); $chkGodotSmoke.Checked=$true; $grpConfig.Controls.Add($chkGodotSmoke)
$chkPlanner=New-Object System.Windows.Forms.CheckBox; $chkPlanner.Text="LEGACY API planner/reviewer"; $chkPlanner.Location=New-Object System.Drawing.Point(765,124); $chkPlanner.Size=New-Object System.Drawing.Size(230,24); $chkPlanner.Checked=$false; $grpConfig.Controls.Add($chkPlanner)

$lblApiModel=New-Object System.Windows.Forms.Label; $lblApiModel.Text="API model:"; $lblApiModel.Location=New-Object System.Drawing.Point(18,157); $lblApiModel.AutoSize=$true; $grpConfig.Controls.Add($lblApiModel)
$txtApiModel=New-Object System.Windows.Forms.TextBox; $txtApiModel.Location=New-Object System.Drawing.Point(88,153); $txtApiModel.Size=New-Object System.Drawing.Size(150,24); $txtApiModel.Text="gpt-5.6-sol"; Style-ArcherInput $txtApiModel; $grpConfig.Controls.Add($txtApiModel)
$lblApiReasoning=New-Object System.Windows.Forms.Label; $lblApiReasoning.Text="reasoning:"; $lblApiReasoning.Location=New-Object System.Drawing.Point(250,157); $lblApiReasoning.AutoSize=$true; $grpConfig.Controls.Add($lblApiReasoning)
$cmbApiReasoning=New-Object System.Windows.Forms.ComboBox; $cmbApiReasoning.Location=New-Object System.Drawing.Point(320,153); $cmbApiReasoning.Size=New-Object System.Drawing.Size(95,24); $cmbApiReasoning.DropDownStyle=[System.Windows.Forms.ComboBoxStyle]::DropDownList; [void]$cmbApiReasoning.Items.AddRange(@("low","medium","high","xhigh","max")); $cmbApiReasoning.SelectedItem="medium"; Style-ArcherInput $cmbApiReasoning; $grpConfig.Controls.Add($cmbApiReasoning)
$lblApi=New-Object System.Windows.Forms.Label; $lblApi.Text="API key:"; $lblApi.Location=New-Object System.Drawing.Point(430,157); $lblApi.AutoSize=$true; $grpConfig.Controls.Add($lblApi)
$txtApiKey=New-Object System.Windows.Forms.TextBox; $txtApiKey.Location=New-Object System.Drawing.Point(490,153); $txtApiKey.Size=New-Object System.Drawing.Size(710,24); $txtApiKey.Anchor="Top,Left,Right"; $txtApiKey.UseSystemPasswordChar=$true; $txtApiKey.Text=[Environment]::GetEnvironmentVariable("OPENAI_API_KEY","Process"); Style-ArcherInput $txtApiKey; $grpConfig.Controls.Add($txtApiKey)

# Health monitor
$grpHealth=New-Object System.Windows.Forms.GroupBox; $grpHealth.Text="SYSTEM HEALTH MONITOR"; $grpHealth.Location=New-Object System.Drawing.Point(18,280); $grpHealth.Size=New-Object System.Drawing.Size(1225,220); $grpHealth.Anchor="Top,Left,Right"; Style-ArcherGroup $grpHealth; $form.Controls.Add($grpHealth)
$toolTipHealth=New-Object System.Windows.Forms.ToolTip
$picHealthOverall=New-Object System.Windows.Forms.PictureBox; $picHealthOverall.Location=New-Object System.Drawing.Point(14,20); $picHealthOverall.Size=New-Object System.Drawing.Size(22,22); $picHealthOverall.SizeMode=[System.Windows.Forms.PictureBoxSizeMode]::Zoom; $picHealthOverall.BackColor=[System.Drawing.Color]::Transparent; $grpHealth.Controls.Add($picHealthOverall)
$lblHealthOverall=New-Object System.Windows.Forms.Label; $lblHealthOverall.Text="СИСТЕМА: ПРОВЕРКА..."; $lblHealthOverall.Location=New-Object System.Drawing.Point(42,21); $lblHealthOverall.Size=New-Object System.Drawing.Size(390,24); $lblHealthOverall.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $grpHealth.Controls.Add($lblHealthOverall)
$uiHealthOverall=[pscustomobject]@{Icon=$picHealthOverall;Label=$lblHealthOverall}
function New-HealthUiItem([int]$x,[int]$y,[int]$w,[string]$text) {
    $pb=New-Object System.Windows.Forms.PictureBox
    $pb.Location=New-Object System.Drawing.Point($x,($y+1)); $pb.Size=New-Object System.Drawing.Size(16,16); $pb.SizeMode=[System.Windows.Forms.PictureBoxSizeMode]::Zoom; $pb.BackColor=[System.Drawing.Color]::Transparent; $grpHealth.Controls.Add($pb)
    $l=New-Object System.Windows.Forms.Label
    $l.Location=New-Object System.Drawing.Point(($x+20),($y-1)); $l.Size=New-Object System.Drawing.Size(($w-20),21); $l.Text=$text; $grpHealth.Controls.Add($l)
    return [pscustomobject]@{Icon=$pb;Label=$l}
}
$uiHealthGodot=New-HealthUiItem 14 54 156 "Godot: ..."
$uiHealthCodex=New-HealthUiItem 170 54 156 "Codex: ..."
$uiHealthAuth=New-HealthUiItem 326 54 148 "Auth: ..."
$uiHealthGit=New-HealthUiItem 474 54 126 "Git: ..."
$uiHealthDotNet=New-HealthUiItem 600 54 146 ".NET: ..."
$uiHealthProject=New-HealthUiItem 14 84 190 "Project: ..."
$uiHealthTests=New-HealthUiItem 205 84 175 "Tests: ..."
$uiHealthAgents=New-HealthUiItem 380 84 175 "Agents: ..."
$uiHealthAstra=New-HealthUiItem 555 84 165 "Astra: ..."
$uiHealthCountry=New-HealthUiItem 720 84 200 "Country: ..."
$picLastRun=New-Object System.Windows.Forms.PictureBox; $picLastRun.Location=New-Object System.Drawing.Point(14,115); $picLastRun.Size=New-Object System.Drawing.Size(16,16); $picLastRun.SizeMode=[System.Windows.Forms.PictureBoxSizeMode]::Zoom; $picLastRun.BackColor=[System.Drawing.Color]::Transparent; $grpHealth.Controls.Add($picLastRun)
$lblLastRun=New-Object System.Windows.Forms.Label; $lblLastRun.Text="ПОСЛЕДНИЙ ЦИКЛ: НЕТ ДАННЫХ"; $lblLastRun.Location=New-Object System.Drawing.Point(34,113); $lblLastRun.Size=New-Object System.Drawing.Size(650,22); $grpHealth.Controls.Add($lblLastRun)
$btnLastRunDetails=New-Object System.Windows.Forms.Button; $btnLastRunDetails.Text="ПОКАЗАТЬ ПРИЧИНУ"; $btnLastRunDetails.Location=New-Object System.Drawing.Point(720,108); $btnLastRunDetails.Size=New-Object System.Drawing.Size(200,28); Style-ArcherButton $btnLastRunDetails; $btnLastRunDetails.Enabled=$false; $btnLastRunDetails.Add_Click({Show-LastRunDetails}); $grpHealth.Controls.Add($btnLastRunDetails)
$btnDiagnose=New-Object System.Windows.Forms.Button; $btnDiagnose.Text="РАЗОБРАТЬСЯ"; $btnDiagnose.Location=New-Object System.Drawing.Point(965,40); $btnDiagnose.Size=New-Object System.Drawing.Size(235,62); $btnDiagnose.Anchor="Top,Right"; $btnDiagnose.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); Style-ArcherButton $btnDiagnose $true; $btnDiagnose.Add_Click({Save-Settings;Set-UiBusy $true;try{Invoke-DiagnoseAndRepair}finally{Set-UiBusy $false;[void](Update-SystemHealth)}}); $grpHealth.Controls.Add($btnDiagnose)
$btnStop=New-Object System.Windows.Forms.Button; $btnStop.Text="СТОП"; $btnStop.Location=New-Object System.Drawing.Point(965,108); $btnStop.Size=New-Object System.Drawing.Size(112,30); Style-ArcherButton $btnStop; $btnStop.BackColor=[System.Drawing.Color]::FromArgb(100,28,28); $btnStop.Enabled=$false; $btnStop.Add_Click({Request-Stop}); $grpHealth.Controls.Add($btnStop)
$btnCancelSelfDestruct=New-Object System.Windows.Forms.Button; $btnCancelSelfDestruct.Text="ОТМЕНА САМОУНИЧТОЖЕНИЯ"; $btnCancelSelfDestruct.Location=New-Object System.Drawing.Point(965,142); $btnCancelSelfDestruct.Size=New-Object System.Drawing.Size(235,32); Style-ArcherButton $btnCancelSelfDestruct $true; $btnCancelSelfDestruct.BackColor=[System.Drawing.Color]::FromArgb(120,45,18); $btnCancelSelfDestruct.ForeColor=[System.Drawing.Color]::White; $btnCancelSelfDestruct.Add_Click({Cancel-SelfDestruct}); $grpHealth.Controls.Add($btnCancelSelfDestruct)
$btnRetryStage=New-Object System.Windows.Forms.Button; $btnRetryStage.Text="ПОВТОРИТЬ ЭТАП"; $btnRetryStage.Location=New-Object System.Drawing.Point(1085,108); $btnRetryStage.Size=New-Object System.Drawing.Size(115,30); Style-ArcherButton $btnRetryStage; $btnRetryStage.Add_Click({Retry-SelectedQueueTask}); $grpHealth.Controls.Add($btnRetryStage)
$btnRollback=New-Object System.Windows.Forms.Button; $btnRollback.Text="ОТКАТ TASK"; $btnRollback.Location=New-Object System.Drawing.Point(14,153); $btnRollback.Size=New-Object System.Drawing.Size(125,30); Style-ArcherButton $btnRollback; $btnRollback.Add_Click({Invoke-TaskScopedRollback}); $grpHealth.Controls.Add($btnRollback)
$btnExportDiag=New-Object System.Windows.Forms.Button; $btnExportDiag.Text="DIAGNOSTICS ZIP"; $btnExportDiag.Location=New-Object System.Drawing.Point(147,153); $btnExportDiag.Size=New-Object System.Drawing.Size(145,30); Style-ArcherButton $btnExportDiag; $btnExportDiag.Add_Click({Export-DiagnosticsBundle}); $grpHealth.Controls.Add($btnExportDiag)
$btnCleanupLogs=New-Object System.Windows.Forms.Button; $btnCleanupLogs.Text="ОЧИСТИТЬ ЛОГИ"; $btnCleanupLogs.Location=New-Object System.Drawing.Point(300,153); $btnCleanupLogs.Size=New-Object System.Drawing.Size(135,30); Style-ArcherButton $btnCleanupLogs; $btnCleanupLogs.Add_Click({Cleanup-RunHistory}); $grpHealth.Controls.Add($btnCleanupLogs)
$btnAcceptVerified=New-Object System.Windows.Forms.Button; $btnAcceptVerified.Text="ПРИНЯТЬ GATE"; $btnAcceptVerified.Location=New-Object System.Drawing.Point(14,182); $btnAcceptVerified.Size=New-Object System.Drawing.Size(150,30); Style-ArcherButton $btnAcceptVerified $true; $btnAcceptVerified.Enabled=$false; $btnAcceptVerified.Add_Click({Accept-VerifiedTimeoutGate}); $grpHealth.Controls.Add($btnAcceptVerified)
$btnReviewVerified=New-Object System.Windows.Forms.Button; $btnReviewVerified.Text="REVIEW ONLY"; $btnReviewVerified.Location=New-Object System.Drawing.Point(172,182); $btnReviewVerified.Size=New-Object System.Drawing.Size(150,30); Style-ArcherButton $btnReviewVerified; $btnReviewVerified.Enabled=$false; $btnReviewVerified.Add_Click({Review-VerifiedTimeoutGate}); $grpHealth.Controls.Add($btnReviewVerified)
$btnRejectVerified=New-Object System.Windows.Forms.Button; $btnRejectVerified.Text="ОТКЛОНИТЬ"; $btnRejectVerified.Location=New-Object System.Drawing.Point(330,182); $btnRejectVerified.Size=New-Object System.Drawing.Size(130,30); Style-ArcherButton $btnRejectVerified; $btnRejectVerified.Enabled=$false; $btnRejectVerified.Add_Click({Reject-VerifiedTimeoutGate}); $grpHealth.Controls.Add($btnRejectVerified)
$chkCompletionSignal=New-Object System.Windows.Forms.CheckBox; $chkCompletionSignal.Text="СИГНАЛ ЗАВЕРШЕНИЯ"; $chkCompletionSignal.Location=New-Object System.Drawing.Point(470,186); $chkCompletionSignal.Size=New-Object System.Drawing.Size(225,24); $chkCompletionSignal.Checked=$true; $chkCompletionSignal.ForeColor=$C_ACCENT; $grpHealth.Controls.Add($chkCompletionSignal)
$btnOperatorLog=New-Object System.Windows.Forms.Button; $btnOperatorLog.Text="ОПЕРАТОРСКИЙ ЛОГ"; $btnOperatorLog.Location=New-Object System.Drawing.Point(720,182); $btnOperatorLog.Size=New-Object System.Drawing.Size(170,30); Style-ArcherButton $btnOperatorLog; $btnOperatorLog.Add_Click({if($logForm.Visible){$logForm.BringToFront();$logForm.Activate()}else{$logForm.Show($form);$logForm.BringToFront();$logForm.Activate()}}); $grpHealth.Controls.Add($btnOperatorLog)
$btnGitDetails=New-Object System.Windows.Forms.Button; $btnGitDetails.Text="GIT ИЗМЕНЕНИЯ"; $btnGitDetails.Location=New-Object System.Drawing.Point(900,182); $btnGitDetails.Size=New-Object System.Drawing.Size(150,30); Style-ArcherButton $btnGitDetails; $btnGitDetails.Add_Click({Show-GitWorkingTreeDetails}); $grpHealth.Controls.Add($btnGitDetails)
$btnThawUi=New-Object System.Windows.Forms.Button; $btnThawUi.Text="РАЗМОРОЗИТЬ UI"; $btnThawUi.Location=New-Object System.Drawing.Point(1060,182); $btnThawUi.Size=New-Object System.Drawing.Size(140,30); Style-ArcherButton $btnThawUi; $btnThawUi.Add_Click({Force-UiIdle -Reason "manual UI thaw";try{[void](Update-SystemHealth)}catch{}}); $grpHealth.Controls.Add($btnThawUi)
$lblWatchdog=New-Object System.Windows.Forms.Label; $lblWatchdog.Text="Watchdog, мин:"; $lblWatchdog.Location=New-Object System.Drawing.Point(455,160); $lblWatchdog.AutoSize=$true; $grpHealth.Controls.Add($lblWatchdog)
$numWatchdog=New-Object System.Windows.Forms.NumericUpDown; $numWatchdog.Location=New-Object System.Drawing.Point(555,155); $numWatchdog.Size=New-Object System.Drawing.Size(60,25); $numWatchdog.Minimum=5; $numWatchdog.Maximum=240; $numWatchdog.Value=30; Style-ArcherInput $numWatchdog; $grpHealth.Controls.Add($numWatchdog)
$lblKeepRuns=New-Object System.Windows.Forms.Label; $lblKeepRuns.Text="Runs:"; $lblKeepRuns.Location=New-Object System.Drawing.Point(635,160); $lblKeepRuns.AutoSize=$true; $grpHealth.Controls.Add($lblKeepRuns)
$numMaxRuns=New-Object System.Windows.Forms.NumericUpDown; $numMaxRuns.Location=New-Object System.Drawing.Point(675,155); $numMaxRuns.Size=New-Object System.Drawing.Size(65,25); $numMaxRuns.Minimum=10; $numMaxRuns.Maximum=1000; $numMaxRuns.Value=100; Style-ArcherInput $numMaxRuns; $grpHealth.Controls.Add($numMaxRuns)
$lblKeepGB=New-Object System.Windows.Forms.Label; $lblKeepGB.Text="Лимит ГБ:"; $lblKeepGB.Location=New-Object System.Drawing.Point(755,160); $lblKeepGB.AutoSize=$true; $grpHealth.Controls.Add($lblKeepGB)
$numMaxRunGB=New-Object System.Windows.Forms.NumericUpDown; $numMaxRunGB.Location=New-Object System.Drawing.Point(820,155); $numMaxRunGB.Size=New-Object System.Drawing.Size(65,25); $numMaxRunGB.Minimum=1; $numMaxRunGB.Maximum=100; $numMaxRunGB.Value=5; Style-ArcherInput $numMaxRunGB; $grpHealth.Controls.Add($numMaxRunGB)


# Task + queue
$grpTasks=New-Object System.Windows.Forms.GroupBox; $grpTasks.Text="ASTRA OPERATOR / ROADMAP TASK QUEUE"; $grpTasks.Location=New-Object System.Drawing.Point(18,512); $grpTasks.Size=New-Object System.Drawing.Size(1225,270); $grpTasks.Anchor="Top,Left,Right"; Style-ArcherGroup $grpTasks; $form.Controls.Add($grpTasks)
$lblTask=New-Object System.Windows.Forms.Label; $lblTask.Text="Новая задача / ТЗ:"; $lblTask.Location=New-Object System.Drawing.Point(14,25); $lblTask.AutoSize=$true; $grpTasks.Controls.Add($lblTask)
$txtTask=New-Object System.Windows.Forms.TextBox; $txtTask.Location=New-Object System.Drawing.Point(17,48); $txtTask.Size=New-Object System.Drawing.Size(565,155); $txtTask.Multiline=$true; $txtTask.ScrollBars="Vertical"; $txtTask.Font=New-Object System.Drawing.Font("Consolas",10); $txtTask.Text="Продолжить разработку NEW CORE в рамках текущего roadmap-этапа."; Style-ArcherInput $txtTask; $grpTasks.Controls.Add($txtTask)
# ADB_HF2_RETRY_DIRECTIVE_EDITOR
function Show-RetryDirectiveEditor {
    if ($null -eq $lstQueue -or $lstQueue.SelectedItems.Count -ne 1) {
        [System.Windows.Forms.MessageBox]::Show("Сначала выберите одну задачу в очереди.", "Archer Dev Bridge — директива повтора", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $item = $lstQueue.SelectedItems[0]
    if ($item.SubItems.Count -lt 3) {
        [System.Windows.Forms.MessageBox]::Show("Не удалось прочитать выбранную задачу.", "Archer Dev Bridge — директива повтора", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $taskId = [string]$item.SubItems[0].Text
    $status = [string]$item.SubItems[1].Text
    if ($status -eq "RUNNING") {
        [System.Windows.Forms.MessageBox]::Show("Нельзя менять директиву выполняющейся задачи. Сначала дождитесь завершения или остановите цикл.", "Archer Dev Bridge — директива повтора", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $taskText = [string]$item.SubItems[2].Text
    $begin = "[BRIDGE USER RETRY DIRECTIVE]"
    $end = "[/BRIDGE USER RETRY DIRECTIVE]"
    $pattern = "(?s)" + [regex]::Escape($begin) + "\\r?\\n(.*?)\\r?\\n" + [regex]::Escape($end) + "\\r?\\n*"
    $m = [regex]::Match($taskText, $pattern)
    if ($m.Success) {
        $current = $m.Groups[1].Value.Trim()
        $baseTask = ([regex]::Replace($taskText, $pattern, "", 1)).TrimStart()
    } else {
        $baseTask = $taskText
        $current = "CONTINUE T021. Preserve all valid unfinished work. Do NOT restore walking or manual vehicle controls just to satisfy legacy 0.1.0 tests. Migrate obsolete tests to the vehicle-only / DriveTo architecture while preserving the invariants they were intended to verify. Replace old single-vehicle assumptions with explicit player/NPC vehicle selection. Finish DriveTo network codec/TCP integration and the two-driver TCP path. Fix actual T021 regressions, including NPC/faction/economy/save issues and git diff --check. Re-run the full gate. Do not start T022, T023 or 0.1.2."
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Archer Dev Bridge — директива повтора $taskId"
    $dlg.Size = New-Object System.Drawing.Size(790,560)
    $dlg.MinimumSize = New-Object System.Drawing.Size(650,460)
    $dlg.StartPosition = "CenterScreen"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(15,27,39)
    $dlg.ForeColor = [System.Drawing.Color]::White

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Задача: $taskId    Статус: $status`r`nТекст ниже будет добавлен к этой же задаче и попадёт в следующий RETRY. Новая T-задача не создаётся."
    $lbl.Location = New-Object System.Drawing.Point(16,16)
    $lbl.Size = New-Object System.Drawing.Size(742,52)
    $lbl.Anchor = "Top,Left,Right"
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(220,230,238)
    $dlg.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ScrollBars = "Vertical"
    $txt.AcceptsReturn = $true
    $txt.AcceptsTab = $true
    $txt.WordWrap = $true
    $txt.Location = New-Object System.Drawing.Point(16,76)
    $txt.Size = New-Object System.Drawing.Size(742,390)
    $txt.Anchor = "Top,Bottom,Left,Right"
    $txt.Font = New-Object System.Drawing.Font("Consolas",10)
    $txt.BackColor = [System.Drawing.Color]::FromArgb(8,16,24)
    $txt.ForeColor = [System.Drawing.Color]::White
    $txt.Text = $current
    $dlg.Controls.Add($txt)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "СОХРАНИТЬ ДИРЕКТИВУ"
    $btnSave.Location = New-Object System.Drawing.Point(16,478)
    $btnSave.Size = New-Object System.Drawing.Size(230,36)
    $btnSave.Anchor = "Bottom,Left"
    Style-ArcherButton $btnSave $true
    $btnSave.Add_Click({
        $value = $txt.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            $item.SubItems[2].Text = $baseTask
        } else {
            $item.SubItems[2].Text = $begin + "`r`n" + $value + "`r`n" + $end + "`r`n`r`n" + $baseTask
        }
        Save-TaskQueue
        Add-Log "ROADMAP: директива повтора сохранена для $taskId."
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSave)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "ОЧИСТИТЬ"
    $btnClear.Location = New-Object System.Drawing.Point(258,478)
    $btnClear.Size = New-Object System.Drawing.Size(130,36)
    $btnClear.Anchor = "Bottom,Left"
    Style-ArcherButton $btnClear
    $btnClear.Add_Click({ $txt.Clear() })
    $dlg.Controls.Add($btnClear)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "ОТМЕНА"
    $btnCancel.Location = New-Object System.Drawing.Point(628,478)
    $btnCancel.Size = New-Object System.Drawing.Size(130,36)
    $btnCancel.Anchor = "Bottom,Right"
    Style-ArcherButton $btnCancel
    $btnCancel.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel
    [void]$dlg.ShowDialog()
}
$btnRetryDirective = New-Object System.Windows.Forms.Button; $btnRetryDirective.Text="ДИРЕКТИВА RETRY"; $btnRetryDirective.Location=New-Object System.Drawing.Point(830,214); $btnRetryDirective.Size=New-Object System.Drawing.Size(120,34); Style-ArcherButton $btnRetryDirective; $btnRetryDirective.Add_Click({Show-RetryDirectiveEditor}); $grpTasks.Controls.Add($btnRetryDirective)
$btnQueueAdd=New-Object System.Windows.Forms.Button; $btnQueueAdd.Text="ДОБАВИТЬ В ОЧЕРЕДЬ"; $btnQueueAdd.Location=New-Object System.Drawing.Point(17,214); $btnQueueAdd.Size=New-Object System.Drawing.Size(200,34); Style-ArcherButton $btnQueueAdd $true; $btnQueueAdd.Add_Click({Add-CurrentTaskToQueue}); $grpTasks.Controls.Add($btnQueueAdd)
$chkRoadmapDependency=New-Object System.Windows.Forms.CheckBox; $chkRoadmapDependency.Text="ROADMAP: ждать BASE предыдущего этапа"; $chkRoadmapDependency.Location=New-Object System.Drawing.Point(228,220); $chkRoadmapDependency.Size=New-Object System.Drawing.Size(345,24); $chkRoadmapDependency.Checked=$true; $chkRoadmapDependency.ForeColor=$C_ACCENT; $grpTasks.Controls.Add($chkRoadmapDependency)

$lblQueue=New-Object System.Windows.Forms.Label; $lblQueue.Text="Очередь задач:"; $lblQueue.Location=New-Object System.Drawing.Point(605,25); $lblQueue.AutoSize=$true; $grpTasks.Controls.Add($lblQueue)
$lstQueue=New-Object System.Windows.Forms.ListView; $lstQueue.Location=New-Object System.Drawing.Point(608,48); $lstQueue.Size=New-Object System.Drawing.Size(592,155); $lstQueue.Anchor="Top,Left,Right"; $lstQueue.View=[System.Windows.Forms.View]::Details; $lstQueue.FullRowSelect=$true; $lstQueue.GridLines=$false; $lstQueue.HideSelection=$false; $lstQueue.BackColor=[System.Drawing.Color]::FromArgb(10,15,21); $lstQueue.ForeColor=$C_TEXT; [void]$lstQueue.Columns.Add("ID",55); [void]$lstQueue.Columns.Add("STATUS",120); [void]$lstQueue.Columns.Add("TASK",315); [void]$lstQueue.Columns.Add("DEPENDS",85); $grpTasks.Controls.Add($lstQueue); $lstQueue.Add_SelectedIndexChanged({Update-RetryButtonState})
$btnQueueRemove=New-Object System.Windows.Forms.Button; $btnQueueRemove.Text="УДАЛИТЬ"; $btnQueueRemove.Location=New-Object System.Drawing.Point(608,214); $btnQueueRemove.Size=New-Object System.Drawing.Size(105,34); Style-ArcherButton $btnQueueRemove; $btnQueueRemove.Add_Click({Remove-SelectedQueueTask}); $grpTasks.Controls.Add($btnQueueRemove)
$btnQueueClear=New-Object System.Windows.Forms.Button; $btnQueueClear.Text="ОЧИСТИТЬ"; $btnQueueClear.Location=New-Object System.Drawing.Point(721,214); $btnQueueClear.Size=New-Object System.Drawing.Size(105,34); Style-ArcherButton $btnQueueClear; $btnQueueClear.Add_Click({Clear-TaskQueue}); $grpTasks.Controls.Add($btnQueueClear)
$btnRunQueue=New-Object System.Windows.Forms.Button; $btnRunQueue.Text="ЗАПУСТИТЬ ОЧЕРЕДЬ"; $btnRunQueue.Location=New-Object System.Drawing.Point(955,214); $btnRunQueue.Size=New-Object System.Drawing.Size(245,34); $btnRunQueue.Anchor="Top,Right"; Style-ArcherButton $btnRunQueue $true; $btnRunQueue.Add_Click({Run-TaskQueue}); $grpTasks.Controls.Add($btnRunQueue)

# Actions
$btnCheck=New-Object System.Windows.Forms.Button; $btnCheck.Text="ПРОВЕРИТЬ"; $btnCheck.Location=New-Object System.Drawing.Point(18,795); $btnCheck.Size=New-Object System.Drawing.Size(150,38); Style-ArcherButton $btnCheck; $btnCheck.Add_Click({Save-Settings;Set-UiBusy $true;try{Check-Environment}finally{Set-UiBusy $false;[void](Update-SystemHealth)}}); $form.Controls.Add($btnCheck)
$btnVerify=New-Object System.Windows.Forms.Button; $btnVerify.Text="QUALITY GATE"; $btnVerify.Location=New-Object System.Drawing.Point(148,795); $btnVerify.Size=New-Object System.Drawing.Size(160,38); Style-ArcherButton $btnVerify; $btnVerify.Add_Click({Run-VerificationOnly}); $form.Controls.Add($btnVerify)
$btnOpenRuns=New-Object System.Windows.Forms.Button; $btnOpenRuns.Text="ЛОГИ"; $btnOpenRuns.Location=New-Object System.Drawing.Point(298,795); $btnOpenRuns.Size=New-Object System.Drawing.Size(110,38); Style-ArcherButton $btnOpenRuns; $btnOpenRuns.Add_Click({Start-Process explorer.exe $RunsDir}); $form.Controls.Add($btnOpenRuns)
$btnPlanOnly=New-Object System.Windows.Forms.Button; $btnPlanOnly.Text="ASTRA: ПЛАН (READ-ONLY)"; $btnPlanOnly.Location=New-Object System.Drawing.Point(418,795); $btnPlanOnly.Size=New-Object System.Drawing.Size(157,38); Style-ArcherButton $btnPlanOnly; $btnPlanOnly.Add_Click({Run-PlanOnly}); $form.Controls.Add($btnPlanOnly)
$btnRun=New-Object System.Windows.Forms.Button; $btnRun.Text="ASTRA: ЗАПУСТИТЬ ЗАДАЧУ → ONE CODEX → STRICT GATE"; $btnRun.Location=New-Object System.Drawing.Point(585,795); $btnRun.Size=New-Object System.Drawing.Size(658,38); $btnRun.Anchor="Top,Left,Right"; Style-ArcherButton $btnRun $true; $btnRun.Add_Click({Run-DevelopmentCycle}); $form.Controls.Add($btnRun)

# Detached operator log window. It is modeless and can be opened/hidden independently.
$script:ClosingMain=$false
$logForm=New-Object System.Windows.Forms.Form
$logForm.Text="Archer Dev Bridge — Операторский лог"
$logForm.Size=New-Object System.Drawing.Size(1050,650)
$logForm.MinimumSize=New-Object System.Drawing.Size(760,420)
$logForm.StartPosition=[System.Windows.Forms.FormStartPosition]::CenterParent
$logForm.BackColor=$C_BG
$logForm.ForeColor=$C_TEXT
$logForm.Font=New-Object System.Drawing.Font("Segoe UI",9)

$logToolbar=New-Object System.Windows.Forms.Panel; $logToolbar.Dock=[System.Windows.Forms.DockStyle]::Top; $logToolbar.Height=44; $logToolbar.BackColor=$C_PANEL; $logForm.Controls.Add($logToolbar)
$lblDetachedLog=New-Object System.Windows.Forms.Label; $lblDetachedLog.Text="ОПЕРАТОРСКИЙ ЛОГ"; $lblDetachedLog.Location=New-Object System.Drawing.Point(12,13); $lblDetachedLog.AutoSize=$true; $lblDetachedLog.ForeColor=$C_ACCENT; $lblDetachedLog.Font=New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold); $logToolbar.Controls.Add($lblDetachedLog)
$btnLogCopy=New-Object System.Windows.Forms.Button; $btnLogCopy.Text="КОПИРОВАТЬ"; $btnLogCopy.Location=New-Object System.Drawing.Point(620,7); $btnLogCopy.Size=New-Object System.Drawing.Size(120,30); $btnLogCopy.Anchor="Top,Right"; Style-ArcherButton $btnLogCopy; $logToolbar.Controls.Add($btnLogCopy)
$btnLogRuns=New-Object System.Windows.Forms.Button; $btnLogRuns.Text="ОТКРЫТЬ RUNS"; $btnLogRuns.Location=New-Object System.Drawing.Point(748,7); $btnLogRuns.Size=New-Object System.Drawing.Size(130,30); $btnLogRuns.Anchor="Top,Right"; Style-ArcherButton $btnLogRuns; $btnLogRuns.Add_Click({Start-Process explorer.exe $RunsDir}); $logToolbar.Controls.Add($btnLogRuns)
$btnLogHide=New-Object System.Windows.Forms.Button; $btnLogHide.Text="СКРЫТЬ"; $btnLogHide.Location=New-Object System.Drawing.Point(886,7); $btnLogHide.Size=New-Object System.Drawing.Size(120,30); $btnLogHide.Anchor="Top,Right"; Style-ArcherButton $btnLogHide; $btnLogHide.Add_Click({$logForm.Hide()}); $logToolbar.Controls.Add($btnLogHide)

$txtLog=New-Object System.Windows.Forms.RichTextBox; $txtLog.Dock=[System.Windows.Forms.DockStyle]::Fill; $txtLog.ReadOnly=$true; $txtLog.Font=New-Object System.Drawing.Font("Consolas",9); $txtLog.BackColor=[System.Drawing.Color]::FromArgb(8,12,17); $txtLog.ForeColor=[System.Drawing.Color]::FromArgb(194,208,222); $txtLog.BorderStyle=[System.Windows.Forms.BorderStyle]::None; $logForm.Controls.Add($txtLog); $txtLog.BringToFront()
$btnLogCopy.Add_Click({try{if($txtLog.Text){[System.Windows.Forms.Clipboard]::SetText($txtLog.Text)}}catch{}})
$logForm.Add_FormClosing({if(-not $script:ClosingMain){$_.Cancel=$true;$logForm.Hide()}})

Load-Settings
Load-TaskQueue
Promote-LatestManualAcceptedRoadmapState
Promote-LatestStructuredManualReviewRun
Promote-LatestVerifiedTimeoutRun
try{$dPromote=Get-LatestRunDiagnostic;if($dPromote.Status -eq 'NEEDS_REVIEW'){Set-QueueTaskStatusById -TaskId $dPromote.TaskId -Status 'NEEDS_REVIEW'}}catch{}
Update-RetryButtonState
Update-VerifiedTimeoutUi

$settingsTimer=New-Object System.Windows.Forms.Timer; $settingsTimer.Interval=500; $settingsTimer.Add_Tick({$settingsTimer.Stop();Save-Settings})
$uiRecoveryTimer=New-Object System.Windows.Forms.Timer
$uiRecoveryTimer.Interval=2000
$uiRecoveryTimer.Add_Tick({
    try {
        if($script:IsBusy -and -not $script:QueueInProgress -and -not $script:DevelopmentInProgress -and -not $script:GateInProgress -and -not $script:PlanInProgress){
            $alive=$false
            if($null -ne $script:ActiveProcess){try{$alive=-not $script:ActiveProcess.HasExited}catch{}}
            if(-not $alive){Force-UiIdle -Reason "watchdog detected stale BUSY state";try{[void](Update-SystemHealth)}catch{}}
        }
    } catch {}
})
$uiRecoveryTimer.Start()
$selfDestructTimer=New-Object System.Windows.Forms.Timer
$selfDestructTimer.Interval=500
$selfDestructTimer.Add_Tick({Update-SelfDestructUi;Apply-SelfDestructTaskLock})
$completionSignalTimer=New-Object System.Windows.Forms.Timer
$completionSignalTimer.Interval=700
$completionSignalTimer.Add_Tick({Update-CompletionSignalUi})
function Queue-SettingsSave {$settingsTimer.Stop();$settingsTimer.Start()}
$txtProject.Add_TextChanged({Queue-SettingsSave})
$txtGodot.Add_TextChanged({Queue-SettingsSave})
$cmbCodexModel.Add_TextChanged({Queue-SettingsSave;[void](Update-SystemHealth)})
$cmbCodexReasoning.Add_SelectedIndexChanged({Queue-SettingsSave})
$cmbOperatorMode.Add_SelectedIndexChanged({Queue-SettingsSave;Update-OperatorModeUi;if((Get-OperatorMode) -eq "AI_TEAM"){try{[void](Ensure-AstraAgentProfiles -Repair)}catch{Add-Log "AI TEAM profiles: $($_.Exception.Message)"}};[void](Update-SystemHealth)})
$chkAllowApiAuth.Add_CheckedChanged({Queue-SettingsSave;[void](Update-SystemHealth)})
$txtApiModel.Add_TextChanged({Queue-SettingsSave})
$cmbApiReasoning.Add_SelectedIndexChanged({Queue-SettingsSave})
$chkPlanner.Add_CheckedChanged({Queue-SettingsSave})
$chkAutoRepair.Add_CheckedChanged({Queue-SettingsSave})
$chkRequireClean.Add_CheckedChanged({Queue-SettingsSave;[void](Update-SystemHealth)})
$chkTests.Add_CheckedChanged({Queue-SettingsSave;[void](Update-SystemHealth)})
$chkGodotSmoke.Add_CheckedChanged({Queue-SettingsSave})
$chkRoadmapDependency.Add_CheckedChanged({Queue-SettingsSave;Reconcile-RoadmapQueue})
$chkCompletionSignal.Add_CheckedChanged({Queue-SettingsSave;if(-not $chkCompletionSignal.Checked){Acknowledge-CompletionSignal -Silent}})
$numWatchdog.Add_ValueChanged({Queue-SettingsSave})
$numMaxRuns.Add_ValueChanged({Queue-SettingsSave})
$numMaxRunGB.Add_ValueChanged({Queue-SettingsSave})
$form.Add_FormClosing({if($script:IsBusy){$ans=[System.Windows.Forms.MessageBox]::Show("Сейчас выполняется задача. Остановить её и закрыть Bridge?","Archer Dev Bridge",[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning);if($ans -ne [System.Windows.Forms.DialogResult]::Yes){$_.Cancel=$true;return};$script:StopRequested=$true;if($null -ne $script:ActiveProcess){Stop-ActiveProcessTree -Process $script:ActiveProcess}};$script:ClosingMain=$true;try{$logForm.Close();$logForm.Dispose()}catch{};$settingsTimer.Stop();try{$uiRecoveryTimer.Stop()}catch{};try{$selfDestructTimer.Stop()}catch{};try{$completionSignalTimer.Stop()}catch{};Set-ShutdownGuard $false;Save-Settings;Save-TaskQueue;try{if($null -ne $script:SingleInstanceMutex){$script:SingleInstanceMutex.ReleaseMutex();$script:SingleInstanceMutex.Dispose();$script:SingleInstanceMutex=$null}}catch{}})

Add-Log "Archer Dev Bridge v$BridgeVersion готов."
Add-Log "0.6.13: Manual Release Gate now resolves retry IDs back to their ROADMAP parent and persists DONE_WAIT_BASE; accepted 0.6.12 runs are reconciled on startup."
Add-Log "0.6.12 rules preserved: structured Astra markers have precedence over historical stdout/stderr; manual exported-UI blockers route to WAITING_MANUAL_RELEASE_CHECK instead of stale NU1301."
Add-Log "Safety: ROADMAP child never starts before explicit BASE confirmation and CLEAN Git; cancel-self-destruct stays clickable in every UI state and remains sticky until Bridge restart."
Add-Log "Настройки: $SettingsPath"
Add-Log "Agent profiles: $AgentProfileDir"
if($txtProject.Text){Add-Log "Сохранённый проект: $($txtProject.Text)"}
if($txtGodot.Text){Add-Log "Сохранённый Godot: $($txtGodot.Text)"}
Add-Log "Operator: model=$(Get-ComboValue $cmbCodexModel 'gpt-6-astra'), reasoning=$(Get-ComboValue $cmbCodexReasoning 'medium'), mode=$(Get-OperatorMode)."
Add-Log "API planner/reviewer — LEGACY и по умолчанию OFF. API key не сохраняется."
Add-Log "Автоматический task-cycle не делает commit/push/reset/rebase/clean. Git Inspector может создать BASE commit только по явному подтверждению пользователя; push не выполняется."
$form.Add_Shown({
    try {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.Activate()
        $form.BringToFront()
        $ready = [pscustomobject]@{
            schema = 1
            version = $BridgeVersion
            pid = $PID
            shownAt = (Get-Date).ToString("o")
            title = $form.Text
        }
        $readyJson=$ready | ConvertTo-Json -Depth 4; [IO.File]::WriteAllText($UiReadyPath,$readyJson,(New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    Recover-InterruptedRun
    if ((Get-OperatorMode) -eq "AI_TEAM") {
        try { [void](Ensure-AstraAgentProfiles -Repair) } catch { Add-Log "Не удалось подготовить Astra subagents: $($_.Exception.Message)" }
    } else {
        Add-Log "Operator mode: ONE CODEX — subagents отключены."
    }
    $script:CountryInfo=Get-InternetCountryInfo -Force
    [void](Update-SystemHealth)
    Reconcile-RoadmapQueue
    $script:SelfDestructCancelled=$false
    $script:SelfDestructEverCancelled=$false
    $script:SelfDestructDeadline=(Get-Date).AddSeconds($script:SelfDestructSeconds)
    $script:SelfDestructBlink=$false
    Update-SelfDestructUi
    $selfDestructTimer.Start()
    Apply-SelfDestructTaskLock
})
[void]$form.ShowDialog()