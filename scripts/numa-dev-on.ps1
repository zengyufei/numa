param(
    [string]$NumaDevExe = $env:NUMA_DEV_EXE,
    [string]$Bind = "127.0.0.2:53",
    [int]$Ttl = 60,
    [Alias("Background")]
    [switch]$Hidden
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Please run this script as Administrator. NRPT changes and port 53 require elevated rights."
    }
}

function Get-Root {
    foreach ($candidate in @($PSScriptRoot, (Join-Path $PSScriptRoot ".."))) {
        $resolved = Resolve-Path $candidate -ErrorAction SilentlyContinue
        if (-not $resolved) {
            continue
        }
        $root = $resolved.Path
        if ((Test-Path (Join-Path $root "dev-domains.txt")) -or (Test-Path (Join-Path $root "numa-dev.exe"))) {
            return $root
        }
    }
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Resolve-NumaDevExe {
    param([string]$Candidate, [string]$Root)

    if ($Candidate) {
        $resolved = Resolve-Path $Candidate -ErrorAction SilentlyContinue
        if ($resolved) {
            return $resolved.Path
        }
        throw "NUMA_DEV_EXE was set but not found: $Candidate"
    }

    foreach ($path in @(
        (Join-Path $Root "bin\numa-dev.exe"),
        (Join-Path $Root "numa-dev.exe"),
        (Join-Path $Root "target\release\numa-dev.exe")
    )) {
        if (Test-Path $path) {
            return (Resolve-Path $path).Path
        }
    }

    $cmd = Get-Command "numa-dev.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw "Could not find numa-dev.exe. Build it with: cargo build --release --bin numa-dev"
}

function Read-DevDomains {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Domain file not found: $Path"
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $lineNo = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNo++
        $line = ($rawLine -split "#", 2)[0].Trim()
        if (-not $line) {
            continue
        }

        $parts = $line -split "\s+"
        if ($parts.Count -lt 2) {
            throw "${Path}:$lineNo must be '<ipv4> <domain> [domain...]'"
        }

        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
            $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "${Path}:$lineNo has invalid IPv4 address: $($parts[0])"
        }

        foreach ($domainPart in $parts[1..($parts.Count - 1)]) {
            $domain = $domainPart.Trim().TrimEnd(".").ToLowerInvariant()
            if ($domain.StartsWith("*.")) {
                throw "${Path}:$lineNo wildcards are not supported by numa-dev.exe: $domain"
            }
            if ($domain) {
                $entries.Add([pscustomobject]@{
                    Domain = $domain
                    Ip = $parts[0]
                })
            }
        }
    }

    return @($entries | Sort-Object Domain -Unique)
}

function Split-NumaDevArgs {
    param([string]$Text)

    if (-not $Text) {
        throw 'NUMA_DEV_ARGS is empty. Set it in numa-dev-on.bat, for example: set "NUMA_DEV_ARGS=--domains dev-domains.txt"'
    }

    return @($Text -split "\s+" | Where-Object { $_ })
}

function Get-DomainFileFromNumaDevArgs {
    param([string[]]$NumaArgs)

    for ($i = 0; $i -lt $NumaArgs.Count; $i++) {
        if ($NumaArgs[$i] -eq "--domains") {
            if ($i + 1 -ge $NumaArgs.Count) {
                throw "NUMA_DEV_ARGS has --domains but no file path."
            }
            return $NumaArgs[$i + 1]
        }
    }

    throw 'NUMA_DEV_ARGS must include --domains <file>, for example: set "NUMA_DEV_ARGS=--domains dev-domains.txt"'
}

function Resolve-DomainFilePath {
    param([string]$Path, [string]$Root)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $Root $Path)
}

function Remove-NumaDevNrptRules {
    param([string]$Comment)

    Get-DnsClientNrptRule |
        Where-Object { $_.Comment -eq $Comment } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }
}

function Stop-Watchdog {
    param(
        [string]$WatchdogPidFile,
        [string]$WatchdogScript
    )

    if (-not (Test-Path $WatchdogPidFile)) {
        return
    }

    $pidText = Get-Content -LiteralPath $WatchdogPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    $watchdogPid = 0
    if ([int]::TryParse($pidText, [ref]$watchdogPid)) {
        $proc = Get-Process -Id $watchdogPid -ErrorAction SilentlyContinue
        if ($proc) {
            Stop-Process -Id $watchdogPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 100
            if (Get-Process -Id $watchdogPid -ErrorAction SilentlyContinue) {
                taskkill /PID $watchdogPid /T /F | Out-Null
            }
        }
    }

    Remove-Item -LiteralPath $WatchdogPidFile -Force -ErrorAction SilentlyContinue
    if ($WatchdogScript) {
        Remove-Item -LiteralPath $WatchdogScript -Force -ErrorAction SilentlyContinue
    }
}

function Stop-StaleNumaDev {
    param([string]$PidFile)

    $pids = [System.Collections.Generic.HashSet[int]]::new()
    if (Test-Path $PidFile) {
        $pidText = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $oldPid = 0
        if ([int]::TryParse($pidText, [ref]$oldPid)) {
            [void]$pids.Add($oldPid)
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }

    Get-Process "numa-dev" -ErrorAction SilentlyContinue | ForEach-Object {
        [void]$pids.Add([int]$_.Id)
    }

    foreach ($processId in $pids) {
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq "numa-dev") {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
    }

    if ($pids.Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

function Wait-ForDnsReady {
    param([string]$Domain, [string]$Server, [string]$ExpectedIp)

    for ($i = 0; $i -lt 30; $i++) {
        try {
            $answer = Resolve-DnsName $Domain -Server $Server -Type A -DnsOnly -ErrorAction Stop
            if ($answer | Where-Object { $_.IPAddress -eq $ExpectedIp }) {
                return
            }
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }

    throw "numa-dev.exe started, but DNS probe did not return $Domain -> $ExpectedIp"
}

function Start-NumaDevWatchdog {
    param(
        [int]$NumaDevPid,
        [string]$RuntimeDir,
        [string]$PidFile,
        [string]$WatchdogPidFile,
        [string]$Comment
    )

    $watchdogScript = Join-Path $RuntimeDir "numa-dev-watchdog.ps1"
    $watchdogLog = Join-Path $RuntimeDir "numa-dev-watchdog.log"
    $watchdogScriptText = @'
param(
    [int]$NumaDevPid,
    [string]$Comment,
    [string]$PidFile,
    [string]$WatchdogPidFile,
    [string]$LogFile
)

$ErrorActionPreference = "SilentlyContinue"

function Write-WatchdogLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $LogFile -Value "$timestamp $Message" -Encoding ASCII
}

try {
    Write-WatchdogLog "watching numa-dev process $NumaDevPid"
    Wait-Process -Id $NumaDevPid
    Write-WatchdogLog "numa-dev process $NumaDevPid exited; cleaning NRPT rules"

    Get-DnsClientNrptRule |
        Where-Object { $_.Comment -eq $Comment } |
        ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force }

    Clear-DnsClientCache
    ipconfig /flushdns | Out-Null
} finally {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $WatchdogPidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
}
'@

    Set-Content -LiteralPath $watchdogScript -Value $watchdogScriptText -Encoding ASCII

    $watchdogArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$watchdogScript`"",
        "-NumaDevPid", "$NumaDevPid",
        "-Comment", "`"$Comment`"",
        "-PidFile", "`"$PidFile`"",
        "-WatchdogPidFile", "`"$WatchdogPidFile`"",
        "-LogFile", "`"$watchdogLog`""
    )
    $watchdog = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList $watchdogArgs `
        -WindowStyle Hidden `
        -PassThru
    Set-Content -LiteralPath $WatchdogPidFile -Value $watchdog.Id -Encoding ASCII
    return $watchdog.Id
}

Assert-Admin

$root = Get-Root
$numaDevArgs = @(Split-NumaDevArgs -Text $env:NUMA_DEV_ARGS)
$domainFile = Get-DomainFileFromNumaDevArgs -NumaArgs $numaDevArgs
$numaDevPath = Resolve-NumaDevExe -Candidate $NumaDevExe -Root $root
$domainFilePath = Resolve-DomainFilePath -Path $domainFile -Root $root
$entries = @(Read-DevDomains -Path $domainFilePath)
if ($entries.Count -eq 0) {
    throw "No domains found in $domainFilePath"
}

$runtimeDir = Join-Path $env:ProgramData "numa-dev"
$pidFile = Join-Path $runtimeDir "numa-dev.pid"
$watchdogPidFile = Join-Path $runtimeDir "numa-dev-watchdog.pid"
$watchdogScript = Join-Path $runtimeDir "numa-dev-watchdog.ps1"
$outLog = Join-Path $runtimeDir "numa-dev.out.log"
$errLog = Join-Path $runtimeDir "numa-dev.err.log"
$comment = "numa-dev-domain-profile"
$serverIp = ($Bind -split ":", 2)[0]

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
Stop-Watchdog -WatchdogPidFile $watchdogPidFile -WatchdogScript $watchdogScript
Stop-StaleNumaDev -PidFile $pidFile
Remove-NumaDevNrptRules -Comment $comment
Clear-DnsClientCache
ipconfig /flushdns | Out-Null

$processArgs = @($numaDevArgs + @("--bind", $Bind, "--ttl", "$Ttl"))
if ($Hidden) {
    $proc = Start-Process `
        -FilePath $numaDevPath `
        -ArgumentList $processArgs `
        -WorkingDirectory $root `
        -WindowStyle Hidden `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru
} else {
    $proc = Start-Process `
        -FilePath $numaDevPath `
        -ArgumentList $processArgs `
        -WorkingDirectory $root `
        -WindowStyle Normal `
        -PassThru
}
Set-Content -LiteralPath $pidFile -Value $proc.Id -Encoding ASCII
$watchdogPid = Start-NumaDevWatchdog `
    -NumaDevPid $proc.Id `
    -RuntimeDir $runtimeDir `
    -PidFile $pidFile `
    -WatchdogPidFile $watchdogPidFile `
    -Comment $comment

$probe = $entries[0]
Wait-ForDnsReady -Domain $probe.Domain -Server $serverIp -ExpectedIp $probe.Ip

$domains = @($entries | ForEach-Object { $_.Domain })

Add-DnsClientNrptRule -Namespace $domains -NameServers $serverIp -Comment $comment | Out-Null
Clear-DnsClientCache
ipconfig /flushdns | Out-Null

Write-Host "numa-dev is ON."
Write-Host "  Domains: $($domains.Count)"
Write-Host "  Resolver: $serverIp"
Write-Host "  Process: $($proc.Id)"
Write-Host "  Watchdog: $watchdogPid"
if ($Hidden) {
    Write-Host "  Logs: $outLog / $errLog"
} else {
    Write-Host "  Console: visible"
}
