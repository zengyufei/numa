# Numa Dev DNS

English | [中文](README.zh.md)

Numa Dev DNS is a Windows-only lightweight DNS profile for local development.
It builds `numa-dev.exe`, a minimal DNS server that maps configured domains to
IPv4 A records and lets Windows route those domains through it with NRPT rules.

`numa-dev` is a lightweight local DNS tool for Windows. After startup, it
automatically adds NRPT rules to replace editing the hosts file, so configured
domains resolve to development environment IP addresses.

This is not the full Numa resolver. It is a narrow developer tool for machines
that need a few real hostnames to resolve to a local or LAN development IP.

## Features

- Exact domain to IPv4 A record mapping.
- Windows NRPT rules for routing only configured domains to `numa-dev.exe`.
- `dev-domains.txt` hot reload every 3 seconds.
- Invalid domain file changes keep the last valid in-memory map.
- Visible or hidden startup modes.
- Hidden watchdog removes NRPT rules and flushes DNS after `numa-dev.exe` exits.
- GitHub tag releases publish only the UPX-compressed `numa-dev.exe` asset.

## Not Included

`numa-dev.exe` intentionally does not include the full Numa feature set:

- no Web UI
- no HTTP API
- no DoH or DoT
- no TLS
- no proxy
- no DNSSEC
- no recursive resolver
- no service install
- no ad blocking
- no wildcard domains
- no IPv6 records

## Files

- `src/bin/numa-dev.rs`: minimal DNS server.
- `dev-domains.txt`: domain to IPv4 mapping file.
- `numa-dev-on.bat`: starts `numa-dev.exe` in a visible window and installs NRPT rules.
- `numa-dev-on-hidden.bat`: starts `numa-dev.exe` hidden and writes logs under `ProgramData\numa-dev`.
- `numa-dev-off.bat`: removes NRPT rules, flushes DNS, and stops `numa-dev.exe`.
- `scripts/numa-dev-on.ps1`: elevated startup logic.
- `scripts/numa-dev-off.ps1`: elevated cleanup logic.
- `.github/workflows/release.yml`: tag-triggered Windows release workflow.

## Domain File

`dev-domains.txt` uses this format:

```txt
<ipv4> <domain> [domain...]
```

Example:

```txt
192.168.0.103 api.synccopay.com pay.synccopay.com
192.168.0.103 admin.synccopay.com
```

Blank lines and `#` comments are ignored. Domains are normalized to lowercase
and trailing dots are removed. Wildcards and IPv6 are rejected.

The file is reloaded every 3 seconds. If a reload fails validation, the running
process keeps using the previous valid mapping.

## Build

Build the development DNS executable:

```powershell
cargo build --release --bin numa-dev
```

The output is:

```text
target\release\numa-dev.exe
```

## Usage

Start with a visible console:

```bat
numa-dev-on.bat
```

Start hidden:

```bat
numa-dev-on-hidden.bat
```

Stop and restore Windows DNS routing:

```bat
numa-dev-off.bat
```

The start scripts request Administrator permission because binding port 53 and
changing Windows NRPT rules require elevation.

Direct run without NRPT setup:

```powershell
.\target\release\numa-dev.exe --domains dev-domains.txt --bind 127.0.0.2:53 --ttl 60
```

## How Windows Routing Works

Windows owns `127.0.0.1:53`, so this tool listens on `127.0.0.2:53` by default.
The startup script reads `dev-domains.txt`, adds NRPT rules for those domains,
and tells Windows to send matching DNS queries to `127.0.0.2`.

Only the configured domains are routed through `numa-dev.exe`; other domains
continue using the machine's normal DNS settings.

## Recovery

If `numa-dev.exe` is closed directly, the hidden watchdog removes the NRPT rules
and flushes DNS automatically.

If both the server and watchdog are killed, run:

```bat
numa-dev-off.bat
```

That removes the `numa-dev-domain-profile` NRPT rules, flushes DNS, and stops
remaining `numa-dev` processes.

## Release

Pushing any tag triggers the GitHub Actions release workflow:

```powershell
git tag dev-v0.1.0
git push origin dev-v0.1.0
```

The workflow builds on `windows-latest`, runs `cargo test --locked --bin
numa-dev`, builds `cargo build --release --locked --bin numa-dev`, compresses
the executable with UPX, and uploads `numa-dev.exe` directly to the tag's GitHub
Release.

The release asset is the executable itself, not a `.zip`, `.tar.gz`, or other
archive.

## License

MIT
