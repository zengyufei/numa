# Numa Dev DNS

This folder contains a narrow Windows-only DNS profile for development.

It uses `numa-dev.exe`, not the full `numa.exe`. The dev binary has no Web UI,
HTTP API, DoH/DoT, TLS, proxy, DNSSEC, recursive resolver, service install, or
ad blocking. It only maps configured domains to IPv4 A records and prints DNS
queries to the console.

## Files

- `dev-domains.txt` is the only domain config file.
- `numa-dev.exe` is the minimal DNS server.
- `numa-dev-on.bat` starts `numa-dev.exe` and adds Windows NRPT rules.
- `numa-dev-off.bat` removes the NRPT rules and stops `numa-dev.exe`.

## Domain Format

```txt
192.168.0.103 api.synccopay.com
192.168.0.103 pay.synccopay.com admin.synccopay.com
```

Blank lines and `#` comments are ignored. Wildcards and IPv6 are intentionally
not supported.

`numa-dev.exe` reloads this file every 3 seconds. Valid changes replace the
in-memory domain map without restarting; invalid changes are reported and the
last valid map stays active.

## Usage

Run:

```bat
numa-dev-on.bat
numa-dev-off.bat
```

The bat files request Administrator permission when NRPT needs to change.
If `numa-dev.exe` is closed directly, a hidden watchdog removes the NRPT rules
and flushes DNS automatically. If both the server and watchdog are killed, run
`numa-dev-off.bat` to restore Windows DNS routing.

Direct run:

```bat
numa-dev.exe --domains dev-domains.txt --bind 127.0.0.2:53 --ttl 60
```

Build:

```bat
cargo build --release --bin numa-dev
```
