# Numa Dev DNS

中文 | [English](README.md)

Numa Dev DNS 是一个 Windows 专用的轻量开发 DNS profile。它构建出的核心程序是
`numa-dev.exe`，用于把指定域名解析到指定 IPv4 地址，并通过 Windows NRPT 规则让
这些域名的 DNS 查询走本地开发 DNS。

这不是完整的 Numa DNS resolver，而是一个很窄的开发环境工具，适合把一组真实域名
临时指向本机或局域网里的开发服务器。

## 功能

- 精确域名到 IPv4 A 记录映射。
- 通过 Windows NRPT 只劫持配置过的域名。
- `dev-domains.txt` 每 3 秒自动热加载。
- 配置文件内容无效时，继续使用上一份有效的内存映射。
- 支持可见窗口启动和隐藏后台启动。
- `numa-dev.exe` 退出后，隐藏 watchdog 会自动删除 NRPT 规则并刷新 DNS。
- GitHub tag release 只发布经过 UPX 压缩的 `numa-dev.exe` 本体。

## 不包含什么

`numa-dev.exe` 有意不包含完整 Numa 的功能：

- 没有 Web UI
- 没有 HTTP API
- 没有 DoH 或 DoT
- 没有 TLS
- 没有代理
- 没有 DNSSEC
- 没有递归解析器
- 没有服务安装
- 没有广告拦截
- 不支持通配符域名
- 不支持 IPv6 记录

## 文件说明

- `src/bin/numa-dev.rs`：极简 DNS server。
- `dev-domains.txt`：域名到 IPv4 的映射配置。
- `numa-dev-on.bat`：可见窗口启动 `numa-dev.exe`，并添加 NRPT 规则。
- `numa-dev-on-hidden.bat`：隐藏启动 `numa-dev.exe`，日志写入 `ProgramData\numa-dev`。
- `numa-dev-off.bat`：删除 NRPT 规则、刷新 DNS、停止 `numa-dev.exe`。
- `scripts/numa-dev-on.ps1`：需要管理员权限的启动逻辑。
- `scripts/numa-dev-off.ps1`：需要管理员权限的清理逻辑。
- `.github/workflows/release.yml`：创建 tag 时自动发布 Windows exe。

## 域名配置

`dev-domains.txt` 的格式是：

```txt
<ipv4> <domain> [domain...]
```

示例：

```txt
192.168.0.103 api.synccopay.com pay.synccopay.com
192.168.0.103 admin.synccopay.com
```

空行和 `#` 注释会被忽略。域名会被转成小写，并去掉末尾的点。通配符和 IPv6 会被
拒绝。

程序每 3 秒重新读取这个文件。如果新内容校验失败，运行中的进程会继续使用上一份
有效配置。

## 构建

构建开发 DNS 可执行文件：

```powershell
cargo build --release --bin numa-dev
```

输出位置：

```text
target\release\numa-dev.exe
```

## 使用

可见窗口启动：

```bat
numa-dev-on.bat
```

隐藏后台启动：

```bat
numa-dev-on-hidden.bat
```

停止并恢复 Windows DNS 路由：

```bat
numa-dev-off.bat
```

启动脚本会请求管理员权限，因为监听 53 端口和修改 Windows NRPT 规则都需要提权。

不安装 NRPT、只直接运行 DNS server：

```powershell
.\target\release\numa-dev.exe --domains dev-domains.txt --bind 127.0.0.2:53 --ttl 60
```

## Windows 路由原理

Windows 自带的 DNS Client 服务占用 `127.0.0.1:53`，所以这个工具默认监听
`127.0.0.2:53`。启动脚本会读取 `dev-domains.txt`，为这些域名添加 NRPT 规则，
让 Windows 把匹配域名的 DNS 查询交给 `127.0.0.2` 上的 `numa-dev.exe`。

只有配置过的域名会走 `numa-dev.exe`，其他域名仍然使用系统原本的 DNS 设置。

## 恢复方式

如果你直接关闭 `numa-dev.exe`，隐藏 watchdog 会自动删除 NRPT 规则并刷新 DNS。

如果 `numa-dev.exe` 和 watchdog 都被强制结束，运行：

```bat
numa-dev-off.bat
```

它会删除 `numa-dev-domain-profile` NRPT 规则、刷新 DNS，并停止残留的 `numa-dev`
进程。

如果访问异常，优先运行 `numa-dev-off.bat` 恢复 Windows DNS 路由。

## 发布

推送任意 tag 会触发 GitHub Actions release：

```powershell
git tag dev-v0.1.0
git push origin dev-v0.1.0
```

workflow 会在 `windows-latest` 上执行 `cargo test --locked --bin numa-dev`，再执行
`cargo build --release --locked --bin numa-dev`，然后用 UPX 压缩 exe，并把
`numa-dev.exe` 直接上传到该 tag 的 GitHub Release。

发布产物是 exe 本体，不是 `.zip`、`.tar.gz` 或其他压缩包。

## 许可证

MIT
