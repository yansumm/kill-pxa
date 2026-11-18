# 出口地区：用运行时 API 切代理组

## 机制

mihomo 把流量按规则匹配，末条通常是一条兜底规则（`MATCH` 或 `FINAL`），指向一个**代理组**。
组是 Selector 就用手选的那个成员，是 URLTest/Fallback 就按健康检查自动挑。
所以"我从哪个国家出去"取决于：末条规则指向哪个组，那个组当前选中哪个节点。

这跟本地隧道无关。本地只做转发，地区完全由出口主机决定。

## 为什么用运行时 API 而不是改配置文件

- 配置文件往往归 root 所有、权限 600，改它需要 sudo，还可能被包管理或配置管理工具覆盖。
- 运行时选择是 mihomo 的官方能力，结果写进 `cache.db`，重启后自动恢复。
- 改错了可以立刻改回来，不需要重启进程、也不影响其他正在用的连接。

代价是：这是**全局**状态。所有客户端都跟着变，包括出口主机自己的流量。

## 原始命令

用 `jq -rn --arg s "名字" '$s|@uri'` 做百分号编码，组名带空格时必需。

```bash
# 列出所有组及当前选择
ssh egress 'curl -s 127.0.0.1:9090/proxies' | jq -r '.proxies|to_entries
  |map(select(.value.all!=null))|.[]|"\(.value.type)\t\(.key)\t-> \(.value.now)"'

# 看某个组有哪些成员
ssh egress 'curl -s "127.0.0.1:9090/proxies/Default%20Proxy"' | jq -r '.now, (.all[])'

# 切换（成功返回 204，无 body）
ssh egress 'curl -s -o /dev/null -w "%{http_code}\n" -X PUT \
  -H "Content-Type: application/json" -d "{\"name\":\"US Fixed IP\"}" \
  "127.0.0.1:9090/proxies/Default%20Proxy"'
```

`scripts/egress.sh` 就是这三条的包装，额外负责编码、校验返回码、打印回滚命令。

## 常见组名

不同订阅的命名差别很大，别照抄。用 `egress.sh list` 看实际名字。常见的形态：

- `Default Proxy` / `PROXY` / `🚀 节点选择` —— 手选总出口。
- `Auto` / `Express` / `URL-Test` —— 按延迟自动挑，会随网络状况漂移。
- `US Fixed IP` / `Static` / `IPLC` —— 固定出口，适合需要稳定 IP 的场景。

诊断顺序：`list` 看末条规则指向的组 → `members` 看它有没有你要的地区 →
如果地区在子组里，就把总组切到那个子组。

## 回到默认

脚本切换时会打印 `切换前` 的值，照它切回去即可。想让出口主机重启后回到配置文件的默认值，
删掉 `cache.db` 里对应的记录或直接重启进程也可以，但没必要——再切一次更简单。

## 安全提醒

`external-controller` 是没有鉴权的 HTTP 接口（除非配了 `secret`）。
确认它只监听 `127.0.0.1`，不要对公网或办公网开放：能调它的人可以改你的全部代理选择。
`scripts/egress.sh` 默认通过 ssh 在主机本机执行 curl，正是因为这个。
