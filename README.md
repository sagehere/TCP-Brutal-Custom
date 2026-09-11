# TCP Brutal Custom

面向 **Xray / 3x-ui / VLESS + REALITY + XHTTP** 的 TCP Brutal 自定义版。

本项目基于 [HyNetworks/tcp-brutal](https://github.com/HyNetworks/tcp-brutal)，将 Hysteria 的 Brutal 拥塞控制算法实现为 Linux TCP 内核模块，并新增 `perip` 规则模式：每个客户端公网 IP 独立拥有一份带宽，而同一 IP 建立的多条 XHTTP TCP 连接仍共享该带宽。

## 为什么需要 `perip`

上游普通规则将所有命中同一前缀的连接放进一个共享组：

```text
0.0.0.0/0 80 Mbps
├── 客户端 A
└── 客户端 B
    合计共享 80 Mbps
```

使用 `perip` 后，TCP Brutal 自动按服务器实际看到的客户端公网 IP 分组：

```text
0.0.0.0/0 80 Mbps perip
├── 客户端 A 的公网 IP：所有连接合计 80 Mbps
└── 客户端 B 的公网 IP：所有连接合计 80 Mbps
```

这适合 XHTTP `stream-one`：无论客户端建立一条或多条底层 TCP 连接，同一公网 IP 都不会因多连接获得多份带宽。

## 功能

- Linux 5.10+ TCP 拥塞控制模块，支持 x86_64 与 ARM64。
- 对普通 TCP 应用生效，不要求客户端安装模块或改造协议。
- `perip`：按对端公网 IP 隔离速率；同一 IP 连接动态共享。
- IPv4、IPv6 和 IPv4-mapped IPv6 支持；IPv4 与 IPv6 分别计组。
- `brutalctl` 管理规则，显示连接数、活跃 IP 组数与累计发送流量。
- 保留上游应用 `group_id` 接口与普通共享规则行为。

## 快速部署：Xray / 3x-ui / XHTTP

在服务器安装或编译加载本模块后，保留系统默认 TCP 拥塞控制算法，例如 BBR；不要把 Brutal 设为系统默认值。

在 3x-ui 的 XHTTP 入站 Socket 设置中添加 Custom Sockopt：

```text
System  = linux
Network = tcp
Level   = 6
Opt     = 13
Type    = str
Value   = brutal
```

然后在服务器添加 IPv4 和 IPv6 规则。`noroute` 适用于由 Xray 的 Custom Sockopt 选择 Brutal 的方式：

```bash
sudo brutalctl add 0.0.0.0/0 80 noroute perip
sudo brutalctl add ::/0 80 noroute perip
```

`80` 是每个公网 IP 的目标总速率，单位为 Mbps。查看运行状态：

```bash
brutalctl list
```

示例输出中的 `GROUP=perip` 表示按 IP 分组，`IPS` 是当前活跃 IP 组数：

```text
DESTINATION                    RATE(Mbps)  GAIN  LOCK   GROUP  ROUTE   ID  MEMBERS   IPS   SENT(MB)
0.0.0.0/0                            80.00    20   yes   perip     no    1        3     2      123.4
```

部署后用以下命令确认 Xray 入站连接正在使用 Brutal：

```bash
ss -tin 'sport = :443'
```

## 规则说明

```bash
brutalctl add <prefix> <Mbps> [gain=<tenths>] [noroute] [perip]
brutalctl list
brutalctl del <prefix>
brutalctl flush
```

- 不带 `perip` 时，保持上游行为：所有命中规则的连接共享一份速率。
- 带 `perip` 时，每个对端 IP 各自拥有一份速率；同一 IP 的所有连接合计共享。
- `perip` 必须使用默认锁定规则，不能与 `nolock` 一起使用。
- 修改同一模式规则的速率会立即影响已有连接。普通共享规则与 `perip` 规则之间切换时，先删除再重新添加规则。
- 规则只匹配新建连接；删除规则后，旧连接会继续使用原速率直到关闭。
- 规则重启后失效，应通过 systemd 或启动脚本恢复。

## 边界与建议

- 分组依据是服务器看到的公网 IP，不是 VLESS 用户。处于同一 NAT 的设备仍共享一份速率。
- 双栈客户端的 IPv4 与 IPv6 会分别获得一份速率。
- Brutal 不会探测链路带宽。速率应不高于客户端实际可承受带宽；设置过高会增加丢包。
- `perip` 解决的是规则组内的速率竞争，不会突破 VPS 出口带宽限制。
- XHTTP 使用 HTTP/3 时底层是 QUIC/UDP，TCP Brutal 不会作用于该连接。

## 从源码构建

Linux 上需要当前内核对应的 headers：

```bash
sudo apt install -y linux-headers-$(uname -r) build-essential
make
sudo make load
make -C tools
sudo install -m 0755 tools/brutalctl /usr/local/bin/brutalctl
```

构建完成后确认：

```bash
lsmod | grep brutal
sysctl net.ipv4.tcp_available_congestion_control
brutalctl list
```

## 与上游的关系

这是非官方自定义分支。核心算法、安装方式和应用 socket API 均源自上游 TCP Brutal；本项目的额外功能是规则级 `perip` 自动分组。详细的通用 API 与上游说明可参考 [HyNetworks/tcp-brutal](https://github.com/HyNetworks/tcp-brutal)。

本项目沿用上游的 GPL-3.0 许可证。

## 一键安装与管理

仅支持 Debian/Ubuntu、systemd、Linux 5.10+ 的 x86_64/ARM64 服务器。以下命令会下载当前 `master` 提交、通过 DKMS 构建模块、设置每 IP 速率并启用开机恢复：

```bash
curl -fsSL https://raw.githubusercontent.com/sagehere/TCP-Brutal-Custom/master/install.sh | sudo -E bash
```

脚本的交互输入会直接从终端读取，因此上述管道方式可以正常使用。如果当前环境没有交互终端，请先下载再运行：

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/sagehere/TCP-Brutal-Custom/master/install.sh
sudo -E bash install.sh
```

安装后使用交互菜单：

```bash
sudo brutal-manager
```

也可以直接执行：

```bash
sudo brutal-manager install
sudo brutal-manager rate
sudo brutal-manager enable
sudo brutal-manager disable
sudo brutal-manager status
sudo brutal-manager uninstall
```

安装和改速时可分别设置 IPv4、IPv6 的每 IP 速率，并选择 `auto`、`ipv4`、`ipv6` 或 `dual` 地址族模式。`auto` 只会为同时具备全局地址和默认路由的地址族应用规则；暂时不可用的地址族会保留配置，待下次可用时由 systemd 服务恢复。

菜单中输入 `0` 或 `7` 均可退出。取消确认不会被视为错误。关闭开机启动也会关闭模块的自动加载；再次开启时会恢复两者。安装或更新失败时，管理器会清理临时文件、尝试恢复原模块和规则，并只重启本次由它暂停的代理服务。

卸载前必须先在 3x-ui/Xray 中移除 Custom Sockopt 的 `brutal`。管理器会提示确认、暂停已运行的 `x-ui.service` 或 `xray.service`、移除本项目管理的规则和模块，再尝试恢复先前运行的代理服务。
