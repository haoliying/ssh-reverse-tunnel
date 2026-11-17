#!/usr/bin/env bash
# ============================================================
# ssh-tunnel-direct.sh — 纯 ssh -R 反向隧道（无远程开关，强制密钥认证）
#
# 形态: 单脚本自守护，不依赖 systemd。
#   start   把自己 fork 到后台常驻，循环检测隧道，断了自动重连
#   stop    通知后台守护进程退出，并优雅关闭隧道（ssh -O exit）
#
# 用法:
#   ./ssh-tunnel-direct.sh start     后台启动（常驻、自动重连）
#   ./ssh-tunnel-direct.sh stop      优雅停止
#   ./ssh-tunnel-direct.sh restart   重启
#   ./ssh-tunnel-direct.sh status    隧道状态 + 对端端口是否真的在监听
#   ./ssh-tunnel-direct.sh check     打印解析后的配置
#   ./ssh-tunnel-direct.sh daemon    前台运行（调试用，Ctrl+C 停止）
#
# 配置文件默认 /data/ssh-tunnel-direct.yml
# 注意: 无配置热加载，改完配置请 stop 再 start
# ============================================================

set -uo pipefail

CONFIG_FILE="${SSH_TUNNEL_CONFIG:-/data/ssh-tunnel-direct.yml}"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# ---------------- 配置读取（仅支持扁平 key: value） ----------------
cfg_get() {
  local key="$1" default="${2:-}" line v
  line=$(grep -E "^[[:space:]]*${key}[[:space:]]*:" "$CONFIG_FILE" 2>/dev/null | tail -n1)
  if [[ -z "$line" ]]; then printf '%s' "$default"; return 0; fi
  v=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//")
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^\".*\"$ || "$v" =~ ^\'.*\'$ ]]; then
    v="${v:1:${#v}-2}"
  else
    v="${v%%#*}"
    v="${v%"${v##*[![:space:]]}"}"
  fi
  [[ -z "$v" ]] && v="$default"
  printf '%s' "$v"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || { cfg_err "配置文件不存在: $CONFIG_FILE"; return 1; }

  VPS_HOST="$(cfg_get vps_host '')"
  VPS_PORT="$(cfg_get vps_port 22)"
  VPS_USER="$(cfg_get vps_user '')"
  SSH_KEY="$(cfg_get ssh_key '')"
  REMOTE_BIND="$(cfg_get remote_bind_addr 0.0.0.0)"
  REMOTE_PORT="$(cfg_get tunnel_remote_port 8080)"
  LOCAL_HOST="$(cfg_get tunnel_local_host 127.0.0.1)"
  LOCAL_PORT="$(cfg_get tunnel_local_port 80)"
  CHECK_INTERVAL="$(cfg_get check_interval 10)"
  HEALTH_CHECK="$(cfg_get health_check 1)"
  HEALTH_INTERVAL="$(cfg_get health_interval 60)"
  SSH_TIMEOUT="$(cfg_get ssh_timeout 15)"
  START_TIMEOUT="$(cfg_get start_timeout 30)"
  LOG_FILE="$(cfg_get log_file /data/ssh-tunnel-direct.log)"
  RUNTIME_DIR="$(cfg_get runtime_dir /tmp)"

  [[ -n "$VPS_HOST" ]] || { cfg_err "vps_host 未配置"; return 1; }
  [[ -n "$VPS_USER" ]] || { cfg_err "vps_user 未配置"; return 1; }
  [[ -n "$SSH_KEY" ]] || { cfg_err "ssh_key 未配置（强制密钥认证）"; return 1; }
  [[ -f "$SSH_KEY" ]] || { cfg_err "ssh_key 文件不存在: $SSH_KEY"; return 1; }
  { [[ "$VPS_PORT" =~ ^[0-9]+$ ]] && [[ "$VPS_PORT" -ge 1 ]]; } || { cfg_err "vps_port 必须是数字"; return 1; }
  { [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] && [[ "$REMOTE_PORT" -ge 1 ]]; } || { cfg_err "tunnel_remote_port 必须是数字"; return 1; }
  { [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [[ "$LOCAL_PORT" -ge 1 ]]; } || { cfg_err "tunnel_local_port 必须是数字"; return 1; }
  { [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$CHECK_INTERVAL" -ge 1 ]]; } || { cfg_err "check_interval 必须是不小于 1 的整数"; return 1; }
  { [[ "$HEALTH_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$HEALTH_INTERVAL" -ge "$CHECK_INTERVAL" ]]; } || { cfg_err "health_interval 必须是不小于 check_interval 的整数"; return 1; }
  { [[ "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$SSH_TIMEOUT" -ge 1 ]]; } || { cfg_err "ssh_timeout 必须是不小于 1 的整数"; return 1; }

  local kperm
  kperm=$(stat -c %a "$SSH_KEY" 2>/dev/null)
  if [[ -n "$kperm" && "$kperm" != "600" && "$kperm" != "400" ]]; then
    log "警告: 私钥 ${SSH_KEY} 权限为 ${kperm}，OpenSSH 要求 600 或更严格，建议 chmod 600 ${SSH_KEY}"
  fi

  RUNTIME_DIR="${RUNTIME_DIR%/}"
  TARGET="${VPS_USER}@${VPS_HOST}"
  FORWARD="${REMOTE_BIND}:${REMOTE_PORT}:${LOCAL_HOST}:${LOCAL_PORT}"
  SOCK="${RUNTIME_DIR}/ssh-tunnel-direct-${REMOTE_PORT}.sock"
  PIDFILE="${RUNTIME_DIR}/ssh-tunnel-direct.pid"
  LOCKFILE="${RUNTIME_DIR}/ssh-tunnel-direct.lock"

  mkdir -p "$RUNTIME_DIR" 2>/dev/null
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

  build_ssh_cmd
  return 0
}

# 构造 ssh 命令 —— 强制密钥认证
build_ssh_cmd() {
  SSH_CMD=(ssh -i "$SSH_KEY")
  SSH_CMD+=(-o "StrictHostKeyChecking=accept-new")
  SSH_CMD+=(-o "ConnectTimeout=10")
  SSH_CMD+=(-o "ServerAliveInterval=60")
  SSH_CMD+=(-o "ServerAliveCountMax=3")
  SSH_CMD+=(-o "ExitOnForwardFailure=yes")
  SSH_CMD+=(-o "IdentitiesOnly=yes")
  SSH_CMD+=(-o "BatchMode=yes")
  [[ "$VPS_PORT" != "22" ]] && SSH_CMD+=(-p "$VPS_PORT")
  return 0
}

# ---------------- 基础工具 ----------------
log() {
  local line="[$(date '+%F %T')] $*"
  printf '%s\n' "$line"
  [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null
  return 0
}
die() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  [[ -n "${LOG_FILE:-}" ]] && printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
  exit 1
}
cfg_err() {
  printf '[%s] CONFIG ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  [[ -n "${LOG_FILE:-}" ]] && printf '[%s] CONFIG ERROR: %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
  return 1
}

usage() {
  cat <<EOF
用法: $(basename "$0") {start|stop|restart|status|check|daemon}

  start    后台启动守护进程（常驻，隧道断开自动重连）
  stop     优雅停止守护进程并关闭隧道
  restart  重启
  status   隧道状态 + 对端端口监听情况
  check    打印解析后的配置
  daemon   前台运行（调试用，Ctrl+C 停止）

配置文件: ${CONFIG_FILE}
EOF
}

# ---------------- 隧道状态与控制 ----------------
# 匹配 "-NTMS <sock>" 或 "-fNMS <sock>" 两种启动方式的 ssh 进程
tunnel_pid() {
  local p
  p="$(pgrep -f -- "MS ${SOCK}" 2>/dev/null | head -n1)"
  [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

is_up() {
  local p
  if p="$(tunnel_pid)"; then
    [[ -n "$p" ]] && return 0
  fi
  # 进程没了但残留 socket，顺手清掉，否则下次 -M 会因 socket 已存在而失效
  [[ -e "$SOCK" ]] && rm -f "$SOCK"
  return 1
}

# 对端端口是否真的在监听（走 ControlMaster 复用连接，开销很小）
remote_listening() {
  is_up || return 1
  timeout 10 ssh -i "$SSH_KEY" -S "$SOCK" -o "ConnectTimeout=5" -o "BatchMode=yes" "$TARGET" \
    "ss -tln 2>/dev/null | grep -q ':${REMOTE_PORT}\$' || netstat -tln 2>/dev/null | grep -q ':${REMOTE_PORT}\$'" \
    >/dev/null 2>&1
}

tunnel_start() {
  local pid i
  [[ -e "$SOCK" ]] && rm -f "$SOCK"

  log "建立隧道 ${VPS_HOST}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}"
  if ! timeout "$SSH_TIMEOUT" "${SSH_CMD[@]}" -fNMS "$SOCK" -R "$FORWARD" "$TARGET" >>"$LOG_FILE" 2>&1; then
    log "隧道建立失败（详见日志尾部）"
    return 1
  fi

  for i in $(seq 1 20); do
    pid="$(tunnel_pid)" && break
    sleep 0.5
  done
  if [[ -z "${pid:-}" ]]; then
    log "警告: 未找到 ssh 进程，隧道可能未真正建立"
    return 1
  fi
  log "隧道已建立，本地 ssh PID=${pid}"
  return 0
}

# 优雅关闭：先走 ssh -O exit，让对端 sshd 主动撤掉监听
tunnel_stop() {
  local pid i
  pid="$(tunnel_pid)" || pid=""

  if [[ -S "$SOCK" ]]; then
    log "关闭隧道（ssh -O exit）"
    ssh -i "$SSH_KEY" -S "$SOCK" -O exit "$TARGET" >/dev/null 2>&1
    for i in $(seq 1 10); do
      is_up || break
      sleep 1
    done
  fi

  if is_up; then
    log "控制连接无响应，降级为 SIGTERM"
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 5); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "仍无响应，使用 SIGKILL（对端端口可能短暂残留）"
      kill -9 "$pid" 2>/dev/null
    fi
  fi

  rm -f "$SOCK"
  log "隧道已关闭"
  return 0
}

# ---------------- 守护进程 ----------------
RUN=1

# 可中断的 sleep：拆成 1 秒，保证 stop 信号能秒级响应
sleep_loop() {
  local n="${1:-1}" i=0
  while [[ "$RUN" == "1" && $i -lt "$n" ]]; do
    sleep 1
    i=$((i + 1))
  done
  return 0
}

daemon_loop() {
  local elapsed=0

  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    die "已有守护进程在运行（锁: $LOCKFILE）"
  fi
  printf '%s\n' "$$" > "$PIDFILE"

  trap 'RUN=0' TERM INT
  log "守护进程启动 PID=$$ 隧道=${VPS_HOST}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT} 检查间隔=${CHECK_INTERVAL}s"

  # 首次建立
  tunnel_start

  while [[ "$RUN" == "1" ]]; do
    sleep_loop "$CHECK_INTERVAL"
    [[ "$RUN" == "1" ]] || break

    if ! is_up; then
      log "检测到隧道已断开，重新建立"
      tunnel_start
      elapsed=0
      continue
    fi

    # 定期深度探测：进程在但连接半死的情况也能发现
    if [[ "$HEALTH_CHECK" == "1" ]]; then
      elapsed=$((elapsed + CHECK_INTERVAL))
      if [[ $elapsed -ge "$HEALTH_INTERVAL" ]]; then
        elapsed=0
        if ! remote_listening; then
          log "对端 ${REMOTE_PORT} 探测失败，判定隧道失效，重建"
          tunnel_stop
          tunnel_start
        fi
      fi
    fi
  done

  log "收到关闭指令，停止守护进程 PID=$$"
  tunnel_stop
  rm -f "$PIDFILE"
  return 0
}

daemon_pid() {
  local pid=""
  [[ -f "$PIDFILE" ]] && pid="$(head -n1 "$PIDFILE" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    printf '%s' "$pid"
    return 0
  fi
  return 1
}

# ---------------- 子命令 ----------------
do_start() {
  local pid i dpid=""

  if pid="$(daemon_pid)"; then
    log "守护进程已在运行 PID=${pid}，无需重复启动"
    do_status
    return 0
  fi
  rm -f "$PIDFILE"

  log "后台启动守护进程"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$SELF" _daemon >>"$LOG_FILE" 2>&1 &
  else
    nohup "$SELF" _daemon >>"$LOG_FILE" 2>&1 &
  fi
  disown 2>/dev/null || true

  for i in $(seq 1 "$START_TIMEOUT"); do
    dpid="$(daemon_pid)" && break
    sleep 1
  done

  if [[ -z "${dpid:-}" ]]; then
    log "守护进程未能在 ${START_TIMEOUT}s 内启动，请查看日志: ${LOG_FILE}"
    return 1
  fi

  log "守护进程已启动 PID=${dpid}"
  for i in $(seq 1 "$START_TIMEOUT"); do
    is_up && break
    sleep 1
  done

  if is_up; then
    log "隧道已就绪"
  else
    log "警告: 隧道尚未建立，检查 VPS 的 GatewayPorts 是否为 yes，详情见 ${LOG_FILE}"
  fi
  return 0
}

do_stop() {
  local pid

  if ! pid="$(daemon_pid)"; then
    log "守护进程未在运行"
    rm -f "$PIDFILE"
    if is_up; then
      log "发现残留隧道，尝试关闭"
      tunnel_stop
    fi
    return 0
  fi

  log "通知守护进程退出 PID=${pid}"
  kill -TERM "$pid" 2>/dev/null

  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done

  if kill -0 "$pid" 2>/dev/null; then
    log "守护进程未响应，SIGKILL"
    kill -9 "$pid" 2>/dev/null
    if is_up; then
      tunnel_stop
    fi
  fi

  rm -f "$PIDFILE"
  log "已停止"
  return 0
}

do_status() {
  local pid dpid
  if dpid="$(daemon_pid)"; then
    log "守护进程: 运行中 PID=${dpid}"
  else
    log "守护进程: 未运行"
  fi

  if pid="$(tunnel_pid)"; then
    log "隧道状态: 运行中  ssh PID=${pid}  socket=${SOCK}"
    if remote_listening; then
      log "对端 ${VPS_HOST}:${REMOTE_PORT} 正在监听 -> ${LOCAL_HOST}:${LOCAL_PORT}"
    else
      log "对端未在监听 ${REMOTE_PORT}，检查 VPS 的 GatewayPorts 是否为 yes"
    fi
  else
    log "隧道状态: 未运行"
  fi
}

do_check() {
  cat <<EOF
配置文件    : ${CONFIG_FILE}
VPS         : ${VPS_USER}@${VPS_HOST}:${VPS_PORT}
SSH 认证    : 密钥 ${SSH_KEY}（强制密钥，不支持密码登录）
隧道映射    : ${VPS_HOST}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}
对端监听地址: ${REMOTE_BIND}
检查间隔    : ${CHECK_INTERVAL} 秒
深度探测    : ${HEALTH_CHECK}（每 ${HEALTH_INTERVAL} 秒探测对端端口）
SSH 超时    : ${SSH_TIMEOUT} 秒
启动等待    : ${START_TIMEOUT} 秒
日志        : ${LOG_FILE}
运行目录    : ${RUNTIME_DIR}
EOF
}

# ---------------- main ----------------
case "${1:-}" in
  start)   load_config || exit 1; do_start ;;
  stop)    load_config || exit 1; do_stop ;;
  restart) load_config || exit 1; do_stop; sleep 1; do_start ;;
  status)  load_config || exit 1; do_status ;;
  check)   load_config || exit 1; do_check ;;
  daemon)  load_config || exit 1; daemon_loop ;;
  _daemon) load_config || exit 1; daemon_loop ;;
  -h|--help|help|"") usage ;;
  *)       usage; exit 1 ;;
esac
