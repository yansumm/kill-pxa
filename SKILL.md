---
name: kill-pxa
description: 个人电脑在 Guest 网络下被限制“魔法”，又不想为了进 Office 网络而在个人电脑上安装占存储、吃内存 CPU、还会截屏录屏的 strange software（如 PXA）时，只要有一台已接入 Office 网络并部署好 Clash/mihomo 的主机，就通过官方 VPN + 常驻 SSH 端口转发把它的出口借过来，做成可在本地客户端一键切换的 profile，同时访问内网与外网（Google/GPT/Claude）；也覆盖通过运行时 API 切换出口地区与常见排障。
---
# kill-pxa

## 一行安装

```bash
npx skills add yansumm/kill-pxa --skill kill-pxa -g -y
```

安装后，在你的 agent 中直接使用 `$kill-pxa`。这条命令使用 skills CLI 的公开 GitHub 仓库安装方式；去掉 `-g` 可改为只安装到当前项目。

在办公室里想让个人电脑**同时访问内网和外网（Google、GPT、Claude）**，本来只有两条路：

1. **装上 `strange software` 进 Office 网络**：以在个人电脑上安装 PXA 这类 `strange software` 为代价，接入 **Office 网络**，再开“魔法”。能通是能通，但个人电脑得长期供着一个动辄占用几个 G 存储、狂吃内存和 CPU，还时不时截屏录屏带来过度隐私暴露的 `strange software`。
2. **接入 Guest 网络 + 多个 VPN**：个人电脑干干净净接入 **Guest 网络**，通过 VPN 接入内网、再开“魔法”接入外网。想法很美好，但 **Guest 网络直接把“魔法”限制死了**，导致这条路走不通——大家还是被逼回第一条路，在个人电脑上装 `strange software`。

这个 skill 给的是**第三条路**：既然你已经有一台接入 **Office 网络** 并部署好环境的主机（比如工位台式机或开发机，上面已经装好了各种 `strange software`，能同时访问内网、跑着规则和出口都齐全的“魔法” Clash/mihomo），那就让 `strange software` 留在那台主机上。你的个人电脑安心连 **Guest 网络**，通过官方 VPN 连进内网找到那台 Office 主机，再用一条常驻 SSH 端口转发把它的“魔法”出口借过来，做成本地客户端里一键切换的 profile。

从此个人电脑免装 `strange software`，内网照走官方 VPN，外网 Google、GPT、Claude 照常起飞。

## 这个 skill 不做什么

它复用一个**已经存在、本来就被允许**的出口：不新建绕开网络的通道，不从外网穿透进内网，
也不改变流量在哪里被检查。你在内网的流量照旧走公司官方 VPN，外网流量照旧从那台 Office 主机原本就在用的、本来就受监督的出口出去。请不要拿它访问奇奇怪怪的内容——你借的是那台主机现成的合规出口，两台机器和这些流量仍然算在你头上。

## 前置条件

以下条件必须**已经成立**，不要把这个 skill 当成建设备或建代理的工具。

- **一台接入 Office 网络并部署好的主机（出口主机）**：这台主机已经按要求装好 `strange software`、接入了 Office 网络，能同时访问内网和外网，并且上面部署了可用的“魔法”（Clash/mihomo），开了 mixed 或 HTTP 端口（常见 7890）；如果想切出口地区，还要开 RESTful API（常见 9090）。
- **可达性**：你的个人电脑在 Guest 网络下，连上官方 VPN 后能 SSH 到这台 Office 主机（注意主机地址可能是 DHCP 分来的）。
- **免交互登录**：配好密钥登录，隧道是无人的。没配先 `ssh-copy-id user@host`。
- **本地客户端**（可选但常用）：跑 mihomo 内核的任意 Clash 系 GUI——FlClash、Clash Verge Rev、
  ClashX Meta、Mihomo Party 都行，它们都能导入本地 YAML 并切换 profile。
- **工具**：本机有 `ssh`、`curl`、`jq`。

## 配置

先挑一个本地端口，别和代理自己用的 7890/9090 撞；`17890` 是个合适的默认值。

### 01 隧道

隧道就是一个后台 `ssh -N`，只持有一条 `LocalForward`。用脚本一次写好 SSH 配置块、
守护单元并拉起（本 skill 目录下执行）：

```bash
scripts/tunnel.sh install --ssh-host <出口主机地址> --ssh-user <用户名> --ssh-key ~/.ssh/id_ed25519
scripts/tunnel.sh status
```

默认远端代理 `127.0.0.1:7890`、本地端口 `17890`、别名 `egress`；用
`--remote-port`、`--local-port`、`--name` 覆盖。

脚本会先把你原有的 `~/.ssh/config` 里 `# >>> egress tunnel >>>` 这一段删掉再重写，所以重复执行
是安全的，卸载也只删这一段。但如果里面**本来就有**一个同名 `Host`，ssh 只认第一个匹配的段，
本脚本写的段会被它整个盖住、隧道连到那个旧地址上去——脚本在这种情况下直接停下并告诉你冲突，
换个 `--name` 或处理掉那段旧配置即可。

同理，别把 `LocalForward` 加到你平时登录用的那个别名上。那样每次 `ssh` 登录都会顺带建一条隧道。

守护方式 macOS 用 launchd（`KeepAlive`），Linux 用 systemd user unit（`Restart=always`）。
两者存在的理由只有一个：VPN 掉线重连后隧道自己回来。它会以 15 秒的间隔重试，并且会
**明显失败而不是假活**——`ExitOnForwardFailure yes` 让 ssh 在端口绑不上时直接退出，
而不是留着进程却什么都没转发。

不要用临时隧道：终端里敲的 `ssh -L` 会随终端一起死，`ControlMaster` 则绑在最先连上的那个会话上。

先验证，再往下走：

```bash
nc -z 127.0.0.1 17890
curl -s -x http://127.0.0.1:17890 https://ipinfo.io/json
```

第二条既证明出口通，也顺带告诉你流量从哪个国家出去。失败的话先看
[references/troubleshooting.md](references/troubleshooting.md)，别去动客户端——
隧道不通时，后面每一步都没有意义。

### 02 本地 profile

把 [scripts/outbound-profile.yaml](scripts/outbound-profile.yaml) 拷到一个长期位置，
把 `proxies[0].port` 改成你用的本地端口，再用**客户端同款内核**校验：

```bash
ssh egress 'mihomo -t -f /dev/stdin' < ~/Documents/egress-outbound.yaml
```

这份 profile 只有一个指向隧道的 HTTP 代理和一条 `MATCH` 兜底规则。分流（包括哪些站点
不走代理）已经在出口主机上做完了，本地再写一套，只会得到两套互相打架的规则。

然后在客户端里导入：配置（Profiles）→ 加号 → 从文件导入 → 选这个 YAML。
这一步是纯 GUI，通常没法自动化——Flutter 写的客户端可访问性树是空的，`clash://` 协议也不会生成 profile。

### 03 验证客户端这条路径

切到新 profile、打开系统代理（或 TUN），然后测**客户端自己的端口**，而不是隧道端口，
因为应用实际走的是前者：

```bash
curl -s -x http://127.0.0.1:7890 https://ipinfo.io/json
```

返回的 IP 必须和 01 里的一致。隧道好使但这条不通，说明客户端没在用这个 profile，
或者它的 mixed 端口不是 7890。

### 04 出口地区（可选）

从哪个国家出去，由出口主机上**末条规则指向的那个代理组**决定。改运行时，
永远不要改它的配置文件：

```bash
scripts/egress.sh list                       # 所有组和它们当前的选择
scripts/egress.sh members "Default Proxy"    # 某个组里能选谁
scripts/egress.sh select "Default Proxy" "US Fixed IP"
```

脚本会打印切换前的值，回滚就是把那个值再切回去。注意这是出口主机上的**全局运行时状态**：
所有连这个代理的客户端都会跟着变，包括主机自己。把它当成共享开关，用完记得调回来。
API 细节和原始命令见 [references/egress-selection.md](references/egress-selection.md)。

### 05 Shell 辅助（可选）

GUI 客户端只设系统代理，不往 shell 里导出 `http_proxy`，所以 `curl`、`git`、`pip` 看不见它。
在 `~/.zshrc` 或 `~/.bashrc` 里加两个函数补上：

```bash
proxy-on() {
  export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890
  export all_proxy=socks5h://127.0.0.1:7890
  export no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local
}
proxy-off() { unset http_proxy https_proxy all_proxy no_proxy; }
```

指向客户端的 7890，不是隧道的 17890。直连隧道会绕过客户端的规则和节点选择，
而那正是 03 验证过能用的东西。

## 容易踩的坑

- **TUN 成环**。开 TUN 后，如果去出口主机的路由被 TUN 抓走，流量会进隧道、回到隧道，无限循环。
  把出口主机的网段写进 `tun.route-exclude-address`，并用 `route -n get <主机>`（macOS）
  或 `ip route get <主机>`（Linux）确认主机是走 VPN 网卡到达的。
- **没有 UDP**。HTTP 代理出站只承载 TCP。与其让 QUIC 请求挂着，不如直接拒掉：
  `AND,((NETWORK,udp),(DST-PORT,443)),REJECT`，浏览器一次失败后就会回落 TCP。
- **端口要改两处**。SSH 配置里的 `LocalForward` 和 YAML 里的 `proxies[0].port` 必须一致。
  只改一处，看起来是隧道通着、客户端却全挂。
- **会变的地址**。出口主机跑在 DHCP 上时，旧 `HostName` 会让隧道断掉，而网络本身是好的。
  改 SSH 配置里的 `HostName`，重启服务，看 `status`。
- **换个网络就断**。隧道能通，靠的是「本机能到达出口主机」这一条。出口主机在内网里、你换了
  Wi-Fi 没连 VPN，或者在家想用这套东西，隧道都是不通的——这是前提没成立，不是配置错了。
  先 `nc -vz <主机> <ssh端口>` 确认到得了，再去查隧道。
- **吞吐受限于一条 SSH 连接**。借用的是对方那台机器本来就开着的代理端口，两个代理之间没
  再套一层多路复用：同一时刻的并发连接数受 ssh 单连接限制，下载大文件也更慢。

## 什么算装完了

下面四条按顺序都成立：

1. `nc -z 127.0.0.1 <本地端口>` 通，且守护服务在运行。
2. `curl -x http://127.0.0.1:<本地端口> https://ipinfo.io/json` 返回 IP 和国家。
3. `curl -x http://127.0.0.1:7890 https://ipinfo.io/json` 返回同一个 IP。
4. 重启一次服务，隧道不靠人工就回来了。
