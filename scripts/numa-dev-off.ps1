param(
    [switch]$RestartDnsClient
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$comment = "numa-dev-domain-profile"
$runtimeDir = Join-Path $env:ProgramData "numa-dev"
$pidFile = Join-Path $runtimeDir "numa-dev.pid"
$watchdogPidFile = Join-Path $runtimeDir "numa-dev-watchdog.pid"
$watchdogScript = Join-Path $runtimeDir "numa-dev-watchdog.ps1"

function Stop-Watchdog {
    param([string]$WatchdogPidFile)

    if (-not (Test-Path $WatchdogPidFile)) {
        return 0
    }

    $stopped = 0
    $pidText = Get-Content -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $watchdogPid = 0
    if ([int]::TryParse($pidText, [ref]$watchdogPid)) {
        $proc = Get-Process -Id $watchdogPid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $watchdogPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 100
            if (Get-Process -Id $watchdogPid -ErrorAction SilentlyContinue) {
                taskkill /PID $watchdogPid /T /F | Out-Null
                Start-Sleep -Milliseconds 100
            }
            if (-not (Get-Process -Id $watchdogPid -ErrorAction SilentlyContinue)) {
                $stopped = 1
            }
        }
    }

    Remove-Item -LiteralPath $WatchdogPidFile -Force -ErrorAction SilentlyContinue
    return $stopped
}

$isAdmin = Test-Admin
$watchdogStopped = Stop-Watchdog -WatchdogPidFile $watchdogPidFile
Remove-Item -LiteralPath $watchdogScript -Force -ErrorAction SilentlyContinue

if ($isAdmin) {
    Get-DnsClientNrptRule |
        Where-Object { $_.Comment -eq $comment } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }

    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null

    if ($RestartDnsClient) {
        try {
            Restart-Service -Name Dnscache -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not restart Dnscache: $($_.Exception.Message)"
        }
    }
} else {
    Write-Warning "Not running as Administrator; NRPT rules and DNS cache were not changed."
}

$pids = [System.Collections.Generic.HashSet[int]]::new()
if (Test-Path $pidFile) {
    $pidText = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $oldPid = 0
    if ([int]::TryParse($pidText, [ref]$oldPid)) {
        [void]$pids.Add($oldPid)
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -eq "numa-dev" -or $_.ProcessName -eq "numa-dev.exe" } |
    ForEach-Object {
        [void]$pids.Add([int]$_.Id)
    }

$stopped = 0
foreach ($processId in $pids) {
    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($proc -and ($proc.ProcessName -eq "numa-dev" -or $proc.ProcessName -eq "numa-dev.exe")) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 100
        if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
            taskkill /PID $processId /T /F | Out-Null
            Start-Sleep -Milliseconds 100
        }
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            $stopped++
        } else {
            Write-Warning "Could not stop numa-dev process $processId. Run numa-dev-off.bat and approve UAC."
        }
    }
}

Write-Host "numa-dev is OFF."
if ($isAdmin) {
    Write-Host "  NRPT rules removed."
    Write-Host "  DNS cache flushed."
} else {
    Write-Host "  NRPT rules not changed because this shell is not Administrator."
}
Write-Host "  Processes stopped: $stopped"
Write-Host "  Watchdogs stopped: $watchdogStopped"
