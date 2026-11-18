# 排障：隧道通了但没网

按顺序查。每一步都先拿到事实，再决定下一步。

## 先分清三段

链路是三段，断在哪儿决定查什么：

```
本机应用 → 本地客户端(7890) → 隧道(17890) → ssh/内网 → 出口主机 → 它自己的代理出口 → 外网
```

用两个 curl 把范围切出来：

```bash
curl -s -x http://127.0.0.1:17890 https://ipinfo.io/json   # 只测隧道
curl -s -x http://127.0.0.1:7890  https://ipinfo.io/json   # 测客户端
```

## 隧道段

**端口没监听**

```bash
lsof -iTCP:17890 -sTCP:LISTEN        # macOS/Linux
scripts/tunnel.sh status
```

没有监听时，直接手动跑一次 ssh，它会把错误打出来：

```bash
ssh -N -v egress
```

常见原因：端口被别的程序占了（`lsof -iTCP:17890` 会显示是谁）；密钥没配好（`BatchMode=yes`
下不会提示输密码，直接失败）；出口主机地址过期。

**端口在监听但请求挂住**

说明 ssh 连上了、转发也建了，但到出口主机的代理端口不通。在出口主机上确认：

```bash
ssh egress 'ss -ltnp | grep 7890'
```

mihomo 若只监听 `127.0.0.1` 就没问题（隧道落在同机回环），但端口号要对。

**反复重启**

看日志尾部的报错，通常是 VPN 没起来：

```bash
tail -30 ${TMPDIR:-/tmp}/egress-tunnel.log
```

macOS 看 `launchctl print gui/$(id -u)/com.egress.tunnel` 里的 `last exit code`；
Linux 看 `systemctl --user status egress-tunnel.service`。

## 客户端段

**客户端端口不是 7890**

不同客户端默认端口不同，也可能被人改过。macOS 上：

```bash
scutil --proxy | grep -E 'HTTPPort|SOCKSPort'
```

**切了 profile 但没生效**

先看客户端有没有真的把系统代理指到它；再看 profile 里 `proxies[0].port` 是不是隧道端口。
两者都对还不通，就用客户端自己的日志（多数客户端有"日志/Logs"页）看它有没有在连 17890。

**开了 TUN 之后全断**

几乎一定是成环：到出口主机的流量被 TUN 抓走，经隧道回到隧道。确认路由：

```bash
route -n get <出口主机地址>     # macOS，看 interface 是否为 utun*
ip route get <出口主机地址>     # Linux
```

如果走的是 TUN 网卡而不是 VPN 网卡，把主机网段加进 `tun.route-exclude-address`。

## 出口主机段

绕过本机客户端，直接在出口主机上验证它自己的代理和出口：

```bash
ssh egress 'curl -s -m 15 -x http://127.0.0.1:7890 https://ipinfo.io/json'
```

这条不通就与隧道无关，问题在出口主机上（代理没跑、订阅过期、规则把它自己导向了死节点）。
这条通而第 17890 那条不通，说明问题在转发或本机到主机的路径上。

## 速度慢

先分辨是延迟还是吞吐。SSH 隧道多一次 TCP 中转，交互式操作（点网页、SSH 再套 SSH）会感觉明显，
大文件下载通常还能接受。

```bash
curl -o /dev/null -s -w 'connect %{time_connect} ttfb %{time_starttransfer} total %{time_total}\n' \
  -x http://127.0.0.1:17890 https://www.google.com
```

想压延迟，可行的方向是把出口主机换到离你更近的机房，或改用 UDP 承载的隧道
（WireGuard、`ssh -w`），代价是要多维护一个组件。SSH 的 TCP 隧道本身没有调优空间，
改加密算法带来的差别远小于链路本身的往返时间。
