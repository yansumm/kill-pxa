#!/usr/bin/env bash
# 常驻 SSH 端口转发：把出口主机的代理端口映到本机，供本地 Clash 客户端使用。
# macOS 用 launchd(KeepAlive)，Linux 用 systemd --user(Restart=always)。
# 守护进程存在的理由只有一个：VPN 掉线重连后隧道自己回来，不用人工再敲一遍 ssh。
set -euo pipefail

NAME=egress
LOCAL_PORT=17890
REMOTE_PORT=7890
SSH_HOST=
SSH_USER=
SSH_KEY=
SSH_PORT=22

usage() {
  cat <<'EOF'
用法:
  tunnel.sh install --ssh-host <主机> [--ssh-user <用户名>] [--ssh-key <私钥路径>]
                    [--ssh-port 22] [--local-port 17890] [--remote-port 7890] [--name egress]
  tunnel.sh status | restart | uninstall [--name egress]

参数:
  --ssh-host    出口主机地址（install 必填）
  --remote-port 出口主机上代理的端口，默认 7890，需为 mixed 或 http 端口
  --local-port  本机监听端口，默认 17890；本地 profile 的 port 必须与它一致
  --name        SSH 别名与服务名前缀，默认 egress
EOF
}

die() { echo "错误: $*" >&2; exit 1; }

# 先取子命令，再解析选项；路径都依赖 --name，所以解析完才计算路径
cmd=${1:-}
[[ -n "$cmd" ]] || { usage; exit 1; }
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-host) SSH_HOST=${2:-}; shift 2 ;;
    --ssh-user) SSH_USER=${2:-}; shift 2 ;;
    --ssh-key) SSH_KEY=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    --local-port) LOCAL_PORT=${2:-}; shift 2 ;;
    --remote-port) REMOTE_PORT=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数 $1" ;;
  esac
done

CONFIG=~/.ssh/config
UNIT_LABEL="com.${NAME}.tunnel"
PLIST=~/Library/LaunchAgents/${UNIT_LABEL}.plist
SYSTEMD_UNIT=~/.config/systemd/user/${NAME}-tunnel.service
LOG_FILE="${TMPDIR:-/tmp}/${NAME}-tunnel.log"
# 端口记在状态文件里，之后的 status/restart 不再需要重复传参
STATE_FILE=~/.config/${NAME}-tunnel.env
# 只删本脚本写入的别名段，~/.ssh/config 里其他内容不受影响
BEGIN_MARK="# >>> ${NAME} tunnel >>>"
END_MARK="# <<< ${NAME} tunnel <<<"

strip_ssh_block() {
  [[ -f "$CONFIG" ]] || return 0
  python3 - "$CONFIG" "$BEGIN_MARK" "$END_MARK" <<'PY'
import sys
path, begin, end = sys.argv[1:4]
lines = open(path).read().splitlines(True)
out, skip = [], False
for line in lines:
    if line.strip() == begin:
        skip = True
    if not skip:
        out.append(line)
    if line.strip() == end:
        skip = False
open(path, "w").writelines(out)
PY
}

write_ssh_block() {
  [[ -n "$SSH_HOST" ]] || die "install 需要 --ssh-host"
  touch "$CONFIG"
  chmod 600 "$CONFIG"
  # 先删旧段再写，重复 install 不会堆出多份同名别名
  strip_ssh_block
  # 删掉本脚本的段之后这个别名还能解析出别的主机名，说明 config 里另有一段同名 Host。
  # ssh 只认第一个匹配的段，我们的段会被它整个盖住，隧道会连到那个旧地址上。
  # 停在这里让人处理，不要静默改写别人写的配置。
  foreign=$(ssh -G -F "$CONFIG" "$NAME" 2>/dev/null | awk '$1=="hostname"{print $2}') || true
  if [[ -n "$foreign" && "$foreign" != "$NAME" ]]; then
    die "~/.ssh/config 里已有一段 ${NAME}（HostName ${foreign}），它会盖住本脚本的段；换个 --name，或先删掉那段"
  fi
  {
    echo "$BEGIN_MARK"
    echo "Host ${NAME}"
    echo "  HostName ${SSH_HOST}"
    [[ -n "$SSH_USER" ]] && echo "  User ${SSH_USER}"
    [[ -n "$SSH_KEY" ]] && echo "  IdentityFile ${SSH_KEY}"
    echo "  Port ${SSH_PORT}"
    echo "  IdentitiesOnly yes"
    # 30s 无响应就发探测，连续 3 次没回应即判定连接已死，交给守护进程重启
    echo "  ServerAliveInterval 30"
    echo "  ServerAliveCountMax 3"
    # 端口绑不上时直接退出，避免"进程还活着但隧道没建"的假活状态
    echo "  ExitOnForwardFailure yes"
    echo "  LocalForward 127.0.0.1:${LOCAL_PORT} 127.0.0.1:${REMOTE_PORT}"
    echo "$END_MARK"
  } >> "$CONFIG"
}

install_macos() {
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${UNIT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>${NAME}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- 退出后至少隔 15s 再试，VPN 还没起来时不要空转 -->
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>${LOG_FILE}</string>
  <key>StandardErrorPath</key><string>${LOG_FILE}</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/${UNIT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart -k "gui/$(id -u)/${UNIT_LABEL}"
}

install_linux() {
  mkdir -p "$(dirname "$SYSTEMD_UNIT")"
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=${NAME} SSH tunnel to remote proxy
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes ${NAME}
Restart=always
RestartSec=15
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "${NAME}-tunnel.service"
}

save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf 'LOCAL_PORT=%s\nREMOTE_PORT=%s\n' "$LOCAL_PORT" "$REMOTE_PORT" > "$STATE_FILE"
}

load_state() { [[ -f "$STATE_FILE" ]] && . "$STATE_FILE"; }

case "$cmd" in
  install)
    write_ssh_block
    # 先确认别名真的解析成我们要的地址和转发，再交给守护进程；写错了在这一步就停
    resolved=$(ssh -G -F "$CONFIG" "$NAME" 2>/dev/null) || die "读不了 ${CONFIG}，检查 ssh 配置有没有语法错误"
    # ssh -G 输出的主机名一律小写，直接比较会把大写地址误判成错误
    want_host=$(printf '%s' "$SSH_HOST" | tr 'A-Z' 'a-z')
    grep -qx "hostname ${want_host}" <<<"$resolved" || die "别名 \"${NAME}\" 的 HostName 不是 ${SSH_HOST}"
    grep -qx "localforward \[127.0.0.1\]:${LOCAL_PORT} \[127.0.0.1\]:${REMOTE_PORT}" <<<"$resolved" \
      || die "别名 \"${NAME}\" 的 LocalForward 与预期不符"
    if [[ "$(uname -s)" == "Darwin" ]]; then install_macos; else install_linux; fi
    save_state
    sleep 2
    exec "$0" status --name "$NAME" --local-port "$LOCAL_PORT"
    ;;
  status)
    load_state
    if [[ "$(uname -s)" == "Darwin" ]]; then
      launchctl print "gui/$(id -u)/${UNIT_LABEL}" 2>/dev/null | grep -E 'state =|pid =' || echo "未安装或未运行"
    else
      systemctl --user --no-pager status "${NAME}-tunnel.service" 2>&1 | head -6 || true
    fi
    if nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null; then
      echo "隧道端口 127.0.0.1:${LOCAL_PORT} 已监听"
      # 端口开着不代表链路通，真打一次外部请求
      curl -s -m 15 -x "http://127.0.0.1:${LOCAL_PORT}" https://ipinfo.io/json | head -c 400 \
        || echo "（请求失败，查看日志 ${LOG_FILE}）"
    else
      echo "隧道端口 127.0.0.1:${LOCAL_PORT} 未监听，查看日志 ${LOG_FILE}"
    fi
    ;;
  restart)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      launchctl kickstart -k "gui/$(id -u)/${UNIT_LABEL}"
    else
      systemctl --user restart "${NAME}-tunnel.service"
    fi
    ;;
  uninstall)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      launchctl bootout "gui/$(id -u)/${UNIT_LABEL}" 2>/dev/null || true
      rm -f "$PLIST"
    else
      systemctl --user disable --now "${NAME}-tunnel.service" 2>/dev/null || true
      rm -f "$SYSTEMD_UNIT"
    fi
    strip_ssh_block
    rm -f "$STATE_FILE"
    echo "已卸载 ${NAME} 的隧道与 SSH 别名"
    ;;
  *) usage; exit 1 ;;
esac
