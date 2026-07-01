param(
    [string]$NumaDevExe = $env:NUMA_DEV_EXE,
    [string]$Bind = "127.0.0.2:53",
    [int]$Ttl = 60
)

$ErrorActionPreference = "Continue"

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "==== $Title ===="
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
        (Join-Path $Root "target\numa-dev.exe"),
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

    throw "Could not find numa-dev.exe."
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        throw 'NUMA_DEV_ARGS is empty.'
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

    throw 'NUMA_DEV_ARGS must include --domains <file>.'
}

function Resolve-DomainFilePath {
    param([string]$Path, [string]$Root)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $Root $Path)
}

$root = Get-Root
$runtimeDir = Join-Path $env:ProgramData "numa-dev"
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $runtimeDir "numa-dev-debug-$stamp.log"

Start-Transcript -LiteralPath $logPath -Force | Out-Null
try {
    Write-Section "Environment"
    Write-Host "Root: $root"
    Write-Host "Log: $logPath"
    Write-Host "Admin: $(Test-Admin)"
    Write-Host "Bind: $Bind"
    Write-Host "TTL: $Ttl"
    Write-Host "NUMA_DEV_EXE: $env:NUMA_DEV_EXE"
    if (-not $env:NUMA_DEV_ARGS) {
        $env:NUMA_DEV_ARGS = "--domains dev-domains.txt"
        Write-Host "NUMA_DEV_ARGS was empty; using debug default: $env:NUMA_DEV_ARGS"
    } else {
        Write-Host "NUMA_DEV_ARGS: $env:NUMA_DEV_ARGS"
    }

    Write-Section "Executable"
    $numaDevPath = Resolve-NumaDevExe -Candidate $NumaDevExe -Root $root
    $exe = Get-Item -LiteralPath $numaDevPath
    Write-Host "Resolved: $($exe.FullName)"
    Write-Host "Size: $($exe.Length) bytes"
    Write-Host "LastWriteTime: $($exe.LastWriteTime)"
    & $exe.FullName --help
    Write-Host "Help exit code: $LASTEXITCODE"

    Write-Section "Domain file"
    $numaDevArgs = @(Split-NumaDevArgs -Text $env:NUMA_DEV_ARGS)
    $domainFile = Get-DomainFileFromNumaDevArgs -NumaArgs $numaDevArgs
    $domainFilePath = Resolve-DomainFilePath -Path $domainFile -Root $root
    $entries = @(Read-DevDomains -Path $domainFilePath)
    Write-Host "Path: $domainFilePath"
    Write-Host "Entries: $($entries.Count)"
    if ($entries.Count -gt 0) {
        Write-Host "Probe domain: $($entries[0].Domain) -> $($entries[0].Ip)"
    }

    Write-Section "Port check"
    $serverIp = ($Bind -split ":", 2)[0]
    $serverPort = ($Bind -split ":", 2)[1]
    netstat -ano | Select-String ":$serverPort\s" | ForEach-Object { Write-Host $_ }

    Write-Section "Direct bind test"
    $testBind = "${serverIp}:55353"
    Write-Host "Trying non-privileged bind: $testBind"
    $testProc = Start-Process `
        -FilePath $exe.FullName `
        -ArgumentList @("--domains", $domainFilePath, "--bind", $testBind, "--ttl", "$Ttl") `
        -WorkingDirectory $root `
        -RedirectStandardOutput (Join-Path $runtimeDir "numa-dev-debug-stdout.log") `
        -RedirectStandardError (Join-Path $runtimeDir "numa-dev-debug-stderr.log") `
        -PassThru `
        -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (Get-Process -Id $testProc.Id -ErrorAction SilentlyContinue) {
        Write-Host "Direct bind test process is running: $($testProc.Id)"
        Stop-Process -Id $testProc.Id -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Direct bind test process exited with code: $($testProc.ExitCode)"
    }
    Get-Content -LiteralPath (Join-Path $runtimeDir "numa-dev-debug-stdout.log") -ErrorAction SilentlyContinue
    Get-Content -LiteralPath (Join-Path $runtimeDir "numa-dev-debug-stderr.log") -ErrorAction SilentlyContinue

    Write-Section "Full startup"
    $onScript = Join-Path $root "scripts\numa-dev-on.ps1"
    Write-Host "Running: $onScript -NumaDevExe `"$numaDevPath`" -Bind $Bind -Ttl $Ttl -Hidden"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $onScript -NumaDevExe $numaDevPath -Bind $Bind -Ttl $Ttl -Hidden
    Write-Host "Startup exit code: $LASTEXITCODE"

    Write-Section "Runtime files"
    Get-ChildItem -LiteralPath $runtimeDir -Filter "numa-dev*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Format-Table Name, Length, LastWriteTime -AutoSize

    foreach ($file in @("numa-dev.out.log", "numa-dev.err.log", "numa-dev-watchdog.log")) {
        $path = Join-Path $runtimeDir $file
        if (Test-Path $path) {
            Write-Section $file
            Get-Content -LiteralPath $path -Tail 80
        }
    }

    Write-Section "NRPT rules"
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Comment -eq "numa-dev-domain-profile" } |
        Format-List *
} catch {
    Write-Section "ERROR"
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    exit 1
} finally {
    Stop-Transcript | Out-Null
    Write-Host ""
    Write-Host "Debug log written to: $logPath"
}
