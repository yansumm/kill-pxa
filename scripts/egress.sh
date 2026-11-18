#!/usr/bin/env bash
# 查看/切换出口主机上的代理组选择（也就是"从哪个国家出去"）。
# 走 mihomo 的运行时 REST API：只改内存状态并落进 cache.db，不碰出口主机的配置文件。
set -euo pipefail

SSH_HOST=egress          # 通过这个 SSH 别名在出口主机上执行 curl（API 通常只监听它的 127.0.0.1）
API=http://127.0.0.1:9090
LOCAL=0

usage() {
  cat <<'EOF'
用法:
  egress.sh list                   列出所有可选组和当前选择
  egress.sh members <组名>          列出某个组的成员
  egress.sh now <组名>              只看某个组当前的选择
  egress.sh select <组名> <成员>     切换，并打印切换前的值（回滚就用这个值）

选项:
  --ssh <别名>   在出口主机上执行 curl 的 SSH 别名，默认 egress
  --local        就在本机访问，不经过 ssh（本机就是出口主机时用）
  --api <地址>   出口主机上的 mihomo external-controller，默认 http://127.0.0.1:9090
  --raw          输出 API 原始 JSON，自己用 jq 处理
EOF
}

die() { echo "错误: $*" >&2; exit 1; }

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh) SSH_HOST="${2:-}"; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --api) API="${2:-}"; shift 2 ;;
    --raw) RAW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "未知选项 $1" ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd=${args[0]:-}
[[ -n "$cmd" ]] || { usage; exit 1; }

# 组名常含空格（"Default Proxy"、"US Fixed IP"），拼进 URL 路径前必须百分号编码
enc() { jq -rn --arg s "$1" '$s|@uri'; }

# 所有参数原样交给 curl；不在本机执行时改为在出口主机上执行。
# printf %q 负责把本地参数安全地拼成远端命令行。
curl_run() {
  if [[ "$LOCAL" == 1 ]]; then
    curl "$@"
  else
    ssh -o BatchMode=yes "$SSH_HOST" -- "curl $(printf '%q ' "$@")"
  fi
}

# 取一个组的详情。组名打错时 mihomo 返回 404 和 {"message":"Resource not found"}，
# 没有 all/now 字段；原样往下传只会得到一片 null，所以在这里就判定为不存在。
fetch_group() {
  local group=$1 json
  json=$(curl_run -s -m 10 "${API}/proxies/$(enc "$group")")
  jq -e '.all != null' <<<"$json" >/dev/null 2>&1 \
    || die "组 \"${group}\" 不存在，或它不是有成员列表的组；用 egress.sh list 看实际组名"
  printf '%s' "$json"
}

case "$cmd" in
  list)
    json=$(curl_run -s -m 10 "${API}/proxies")
    [[ -n "$json" ]] || die "拿不到 /proxies；确认 --ssh / --api 正确，且出口主机上 external-controller 在监听"
    if [[ "${RAW:-}" == 1 ]]; then printf '%s\n' "$json"; exit 0; fi
    # 只有 Selector / Fallback / URLTest / LoadBalance 这类组才有 all 和 now 字段
    printf '%s' "$json" | jq -r '.proxies | to_entries
      | map(select(.value.all != null))
      | sort_by(.value.type)
      | .[] | "\(.value.type)\t\(.key)\t-> \(.value.now)"' | column -t -s $'\t'
    ;;
  members)
    group=${args[1]:-}; [[ -n "$group" ]] || die "需要组名"
    fetch_group "$group" | jq -r --arg g "$group" '"组: \($g)  当前: \(.now)", (.all[]? | "  \(.)")'
    ;;
  now)
    group=${args[1]:-}; [[ -n "$group" ]] || die "需要组名"
    fetch_group "$group" | jq -r '.now'
    ;;
  select)
    group=${args[1]:-}; member=${args[2]:-}
    [[ -n "$group" && -n "$member" ]] || die "需要组名和成员名"
    detail=$(fetch_group "$group")
    # 成员名打错时 API 只回 400，看不出是哪个字写错了；先在本地对一遍候选名单
    jq -e --arg m "$member" 'any(.all[]; . == $m)' <<<"$detail" >/dev/null \
      || die "组 \"${group}\" 里没有 \"${member}\"；用 egress.sh members \"${group}\" 看候选"
    before=$(jq -r '.now' <<<"$detail")
    echo "切换前: ${group} -> ${before}"
    # 成功时 mihomo 返回 204 空响应，所以只看状态码
    code=$(curl_run -s -m 10 -o /dev/null -w '%{http_code}' \
      -X PUT -H 'Content-Type: application/json' \
      -d "$(jq -rn --arg n "$member" '{name:$n}')" \
      "${API}/proxies/$(enc "$group")") || true
    [[ "$code" == 204 ]] || die "切换失败（HTTP ${code:-无响应}）"
    echo "切换后: ${group} -> $(fetch_group "$group" | jq -r '.now')"
    echo "回滚: egress.sh select \"$group\" \"$before\""
    ;;
  *) usage; exit 1 ;;
esac
