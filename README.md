# TCP Brutal Custom

TCP Brutal 的独立自定义版，提供按对端 IP 分组的速率控制、安装管理和活跃连接视图。

本项目基于 [HyNetworks/tcp-brutal](https://github.com/HyNetworks/tcp-brutal)，将 Hysteria 的 Brutal 拥塞控制算法实现为 Linux TCP 内核模块，并新增 `perip` 规则模式：每个对端 IP 独立拥有一份带宽，而同一 IP 建立的多条 TCP 连接仍共享该带宽。

## Hot module replacement

Configure the systemd services that own Brutal connections with `sudo tbc hotplug-services sing-box.service nginx.service`. On a busy module, update, migration, and uninstall temporarily stop only configured active services and their active socket units, wait up to 15 seconds, then restore their previous state. Connections reconnect briefly, but a server reboot is not required. `tbc hotplug-services` shows the list and `--clear` removes it.

## 2.4.0

2.4.0 新增按本地 TCP 监听端口自动启用 Brutal 的模式。管理器可通过 `tbc ports` 配置单端口、多端口或端口范围，并自动为 IPv4/IPv6 建立策略路由；未命中的端口继续使用系统默认拥塞控制算法。该模式适合 VLESS Reality、Xray、sing-box、nginx 等普通 TCP 服务，无需应用层适配。

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

无论对端建立一条或多条 TCP 连接，同一 IP 都不会因多连接获得多份带宽。

## 功能

- Linux 5.10+ TCP 拥塞控制模块，支持 x86_64 与 ARM64。
- 对普通 TCP 应用生效，不要求客户端安装模块或改造协议。
- `perip`：按对端公网 IP 隔离速率；同一 IP 连接动态共享。
- 可按本地 TCP 监听端口自动启用 Brutal；未配置端口继续使用系统默认拥塞算法。
- IPv4、IPv6 和 IPv4-mapped IPv6 支持；IPv4 与 IPv6 分别计组。
- `brutalctl` 管理规则，并可查看每个活跃 IP 的速率、连接数与累计发送流量。
- 保留上游应用 `group_id` 接口与普通共享规则行为。

## 快速部署

使用管理器安装后，会按设置的 IPv4、IPv6 每 IP 速率创建 `perip` 规则并设置开机恢复：

```bash
curl -fsSL https://github.com/sagehere/TCP-Brutal-Custom/releases/latest/download/install.sh | sudo -E bash
```

也可以直接用 `brutalctl` 添加规则；`80` 是每个 IP 的目标总速率，单位为 Mbps：

```bash
sudo brutalctl add 0.0.0.0/0 80 noroute perip
sudo brutalctl add ::/0 80 noroute perip
```

查看规则和当前使用 TCP Brutal Custom 的 IP：

```bash
brutalctl list
brutalctl peers
brutalctl peers --family 4 --limit 1000
sudo tbc view
sudo tbc view --watch
```

`view --watch` 每两秒刷新一次，按 Ctrl+C 退出。IP 行只在对应 `perip` 连接存活期间显示。

## 按监听端口自动启用 Brutal

管理器可以让指定的本地 TCP 监听端口自动使用 Brutal，应用本身无需支持 TCP Brutal。典型用途是在 s-ui/Xray 中把 VLESS Reality 入站监听在 `443`，然后只为 `443` 开启 Brutal；SSH、APT、Xray outbound 和其他端口继续使用系统默认的 BBR/CUBIC。

```bash
sudo tbc ports
```

交互输入支持单端口、多端口和范围：

```text
443
443,8443
10000-10100
443,8443,10000-10100
```

输入 `none`、`off`、`clear` 或 `0` 可清除端口配置。管理器会为 IPv4/IPv6 建立独立策略路由，匹配服务端发送方向的本地 `sport`，并在对应路由上锁定 `congctl brutal`。规则仅影响新建 TCP 连接；已经存在的连接继续使用原来的拥塞算法直到关闭。

示例：

```text
VLESS Reality 监听 :443  -> Brutal
SSH :22                 -> 系统默认 CC
Xray outbound :随机端口 -> 系统默认 CC
UDP / QUIC              -> 不受影响
```

端口策略会随 `tcp-brutal-custom.service` 在开机时自动恢复。`sudo tbc status` 可查看当前 Brutal TCP 端口。

## 规则说明

```bash
brutalctl add <prefix> <Mbps> [gain=<tenths>] [noroute] [perip] [maxpeers=N]
brutalctl list
brutalctl peers
brutalctl del <prefix>
brutalctl flush
```

- 不带 `perip` 时，保持上游行为：所有命中规则的连接共享一份速率。
- 带 `perip` 时，每个对端 IP 各自拥有一份速率；同一 IP 的所有连接合计共享。
- `perip` 必须使用默认锁定规则，不能与 `nolock` 一起使用。
- `maxpeers=N` 可限制单条 `perip` 规则同时存在的 peer 组数量；达到上限后新 IP 使用固定哈希 fallback pacer。`maxpeers=0` 表示不限。
- 修改同一模式规则的速率会立即影响已有连接。普通共享规则与 `perip` 规则之间切换时，先删除再重新添加规则。
- 规则只匹配新建连接；删除规则后，旧连接会继续使用原速率直到关闭。
- 规则和统计按 network namespace 隔离；需要在对应容器或 namespace 内配置规则。
- 规则重启后失效，应通过 systemd 或启动脚本恢复。

`brutalctl peers` 支持 `--rule ID`、`--ip ADDRESS`、`--family 4|6` 和
`--limit N`。`/proc/net/tcp_brutal/stats` 提供 peer 分配失败、fallback、
当前及峰值 peer 组数。P2 还提供 `/proc/net/tcp_brutal/limits`：写入 `max_peers=N` 可设置当前 network namespace 的 peer 总预算；`0` 表示不限。达到规则或 namespace 预算时不会拒绝 TCP 连接，而是使用 `hashed_fallback` 保持可用性。

## 边界与建议

- 分组依据是发送端看到的对端 IP，不区分应用层身份。处于同一 NAT 的设备仍共享一份速率。
- 双栈客户端的 IPv4 与 IPv6 会分别获得一份速率。
- Brutal 不会探测链路带宽。速率应不高于客户端实际可承受带宽；设置过高会增加丢包。
- `perip` 解决的是规则组内的速率竞争，不会突破 VPS 出口带宽限制。
- TCP Brutal 只作用于 TCP；UDP 和 QUIC 流量不受影响。

## 从源码构建

Linux 上需要当前内核对应的 headers：

```bash
sudo apt install -y linux-headers-$(uname -r) gcc make libc6-dev
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

仅支持 Debian/Ubuntu、systemd、Linux 5.10+ 的 x86_64/ARM64 服务器。以下命令会从最新的不可变 Release 下载安装器；安装器随后验证 Release 元数据、摘要与源码身份，再通过 DKMS 构建模块、设置每 IP 速率并启用开机恢复：

### Web panel and traffic statistics

After installation, run `sudo tbc` and select the Web-panel entry to choose a local port and administrator credentials. The panel listens only on `127.0.0.1`; publish it through an existing reverse proxy or SSH tunnel rather than exposing it directly.

The panel manages the same settings as the terminal menu and shows active peers. The module accumulates sent and retransmitted bytes for configured TCP source ports, while a five-second collector retains daily history. Retransmission rate is retransmitted data bytes divided by total sent data bytes; retransmitted bytes are MSS-based estimates and exclude TCP/IP headers. Run `sudo brutalctl port-stats` for the current counters.

```bash
curl -fsSL https://github.com/sagehere/TCP-Brutal-Custom/releases/latest/download/install.sh | sudo -E bash
```

脚本的交互输入会直接从终端读取，因此上述管道方式可以正常使用。如果当前环境没有交互终端，请先下载再运行：

```bash
curl -fsSLo install.sh https://github.com/sagehere/TCP-Brutal-Custom/releases/latest/download/install.sh
sudo -E bash install.sh
```

安装后使用交互菜单：

```bash
sudo tbc
```

旧命令 `sudo brutal-manager` 保留为兼容入口。

也可以直接执行：

```bash
sudo tbc install
sudo tbc rate
sudo tbc ports
sudo tbc hotplug-services sing-box.service nginx.service
sudo tbc enable
sudo tbc disable
sudo tbc status
sudo tbc uninstall
```

`hotplug-services` configures the systemd services that may be restarted to release Brutal connections during an update, migration, or uninstall. Use `sudo tbc hotplug-services` to inspect the configured list, or `sudo tbc hotplug-services --clear` to remove it. Only services that were running before the operation, plus their active socket units, are restored afterward.

安装和改速时可分别设置 IPv4、IPv6 的每 IP 速率，并选择 `auto`、`ipv4`、`ipv6` 或 `dual` 地址族模式。`auto` 只会为同时具备全局地址和默认路由的地址族应用规则；暂时不可用的地址族会保留配置，待下次可用时由 systemd 服务恢复。

菜单提供状态、活跃 IP 快照和实时刷新，输入 `0` 退出。关闭开机启动也会关闭模块自动加载；再次开启时会恢复两者。安装或更新失败时，管理器会清理临时文件并尝试恢复原模块和规则。配置热插拔服务后，模块被 TCP 连接占用时，更新、上游迁移和卸载会短暂停止这些服务、重载模块并恢复服务，无需重启。名单外占用会安全退出并报告问题。

## P2 控制与观测接口

支持的模块会通过 `TCP_BRUTAL_INFO` 明确公布能力。`brutalctl` 在发现
Generic Netlink `tcp_brutal` family 后使用类型化接口，否则自动回退到
`/proc/net/tcp_brutal`，不会根据版本号猜测功能。

```bash
brutalctl info
brutalctl stats
brutalctl limits
sudo brutalctl limits 10000
sudo brutalctl add 0.0.0.0/0 100 perip aggregate=1000 maxpeers=10000
```

`aggregate=Mbps` 是单条 `perip` 规则内所有子 pacer 的可选总上限；不配置时
保持原有每 IP 语义。`maxpeers` 和 namespace `limits` 达到上限时使用
`hashed_fallback` 保持连接可用，它不是严格的租户隔离。架构、威胁边界和
报告方式见 [架构说明](docs/architecture.md)、[威胁模型](docs/threat-model.md)
和 [安全策略](SECURITY.md)。
