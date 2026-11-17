#!/usr/bin/env bash
# ============================================================
# ssh-tunnel.sh — 由 VPS 开关文件驱动的 ssh -R 反向隧道控制服务
#
# 开关机制（口令比对）:
#   每隔 poll_interval 秒读取一次 VPS 上的开关文件，取其首行内容，
#   与本地配置的 vps_password（隧道启动口令，明文）做比对:
#     口令一致   -> 隧道未启动则启动，已启动则不动
#     口令不一致 -> 隧道未关闭则关闭，已关闭则不动
#     读取失败   -> 按"不一致"处理（安全侧：不放行）
#   注意: 口令区分大小写；日志中永不打印口令明文。
#
# SSH 认证:
#   强制使用密钥认证（ssh_key 必填且文件必须存在），不再支持密码登录。
#
# 用法:
#   ssh-tunnel.sh daemon    前台常驻运行（配合 systemd）
#   ssh-tunnel.sh once      只执行一轮判断（调试 / cron 用）
#   ssh-tunnel.sh start     手动建立隧道
#   ssh-tunnel.sh stop      手动关闭隧道
#   ssh-tunnel.sh restart   手动重启隧道
#   ssh-tunnel.sh status    查看隧道状态
#   ssh-tunnel.sh check     打印解析后的配置（口令脱敏）
#   ssh-tunnel.sh reload    校验并应用配置变更
#
# 配置文件默认 /data/ssh-tunnel.yml
# 配置热生效：守护进程每轮调度前检查配置文件 mtime，变更即自动热加载
#   （auto_reload: 0 可关闭）。也可 systemctl reload ssh-tunnel 立即生效。
# ============================================================

set -uo pipefail

CONFIG_FILE="${SSH_TUNNEL_CONFIG:-/data/ssh-tunnel.yml}"

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
  VPS_PASSWORD="$(cfg_get vps_password '')"
  SWITCH_DIR="$(cfg_get switch_dir /data)"
  SWITCH_FILE="$(cfg_get switch_file ssh-tunnel-on-off)"
  REMOTE_PORT="$(cfg_get tunnel_remote_port 8080)"
  LOCAL_HOST="$(cfg_get tunnel_local_host 127.0.0.1)"
  LOCAL_PORT="$(cfg_get tunnel_local_port 80)"
  SSH_KEY="$(cfg_get ssh_key '')"
  POLL_INTERVAL="$(cfg_get poll_interval 30)"
  SSH_TIMEOUT="$(cfg_get ssh_timeout 15)"
  LOG_FILE="$(cfg_get log_file /data/ssh-tunnel.log)"
  RUNTIME_DIR="$(cfg_get runtime_dir /tmp)"
  ON_DAEMON_EXIT="$(cfg_get on_daemon_exit keep)"
  AUTO_RELOAD="$(cfg_get auto_reload 1)"

  [[ -n "$VPS_HOST" ]] || { cfg_err "vps_host 未配置"; return 1; }
  [[ -n "$VPS_USER" ]] || { cfg_err "vps_user 未配置"; return 1; }
  # vps_password 在此为「隧道启动口令」，须与 VPS 开关文件内容一致；不允许为空，
  # 否则任何空内容的开关文件都会被判为匹配，等于门户大开。
  [[ -n "$VPS_PASSWORD" ]] || { cfg_err "vps_password（隧道启动口令）未配置，不允许为空"; return 1; }
  # 强制密钥认证
  [[ -n "$SSH_KEY" ]] || { cfg_err "ssh_key 未配置（本脚本强制使用密钥认证）"; return 1; }
  [[ -f "$SSH_KEY" ]] || { cfg_err "ssh_key 文件不存在: $SSH_KEY"; return 1; }
  # 私钥权限过宽时 OpenSSH 会直接拒绝使用，提前给出明确提示
  local kperm
  kperm=$(stat -c %a "$SSH_KEY" 2>/dev/null)
  if [[ -n "$kperm" && "$kperm" != "600" && "$kperm" != "400" ]]; then
    log "警告: 私钥 ${SSH_KEY} 权限为 ${kperm}，OpenSSH 要求 600 或更严格，建议 chmod 600 ${SSH_KEY}"
  fi
  { [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] && [[ "$POLL_INTERVAL" -ge 1 ]]; } || { cfg_err "poll_interval 必须是不小于 1 的整数"; return 1; }
  { [[ "$SSH_TIMEOUT" =~ ^[0-9]+$ ]] && [[ "$SSH_TIMEOUT" -ge 1 ]]; } || { cfg_err "ssh_timeout 必须是不小于 1 的整数"; return 1; }
  { [[ "$VPS_PORT" =~ ^[0-9]+$ ]] && [[ "$VPS_PORT" -ge 1 ]]; } || { cfg_err "vps_port 必须是数字"; return 1; }
  { [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] && [[ "$REMOTE_PORT" -ge 1 ]]; } || { cfg_err "tunnel_remote_port 必须是数字"; return 1; }
  { [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [[ "$LOCAL_PORT" -ge 1 ]]; } || { cfg_err "tunnel_local_port 必须是数字"; return 1; }

  SWITCH_DIR="${SWITCH_DIR%/}"
  SWITCH_PATH="${SWITCH_DIR}/${SWITCH_FILE}"
  TARGET="${VPS_USER}@${VPS_HOST}"
  FORWARD="0.0.0.0:${REMOTE_PORT}:${LOCAL_HOST}:${LOCAL_PORT}"
  SOCK="${RUNTIME_DIR}/ssh-tunnel-${REMOTE_PORT}.sock"
  PIDFILE="${RUNTIME_DIR}/ssh-tunnel-${REMOTE_PORT}.pid"
  LOCKFILE="${RUNTIME_DIR}/ssh-tunnel-daemon.lock"

  mkdir -p "$RUNTIME_DIR" 2>/dev/null
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

  build_ssh_cmd
  return 0
}

# ---------------- 配置热加载 ----------------
# 配置文件的修改时间（Linux coreutils）
config_mtime() { stat -c %Y "$CONFIG_FILE" 2>/dev/null || printf '0'; }

# 运行中重新加载配置：
#   - 新配置非法 -> 完整回滚到上一次的有效配置，服务继续跑（不会因为写错配置而挂掉）
#   - 隧道标识（socket 路径）变化 -> 先按旧标识收掉旧隧道，避免留下无人管理的孤儿进程
reload_config() {
  local old_sock old_pidfile cur_sock snapfile v changed=0

  old_sock="$SOCK"; old_pidfile="$PIDFILE"
  # 快照写成临时文件再 source：
  #  - 不能用 declare -p：在函数内 eval "declare -- X=..." 会把变量变成局部变量，
  #    函数一返回就丢失，回滚形同虚设
  #  - 文件天然保留换行，赋值语句作用于已存在的全局变量，%q 负责安全转义
  snapfile="${RUNTIME_DIR}/.cfg-snapshot.$$"
  : > "$snapfile" 2>/dev/null || snapfile="/tmp/.cfg-snapshot.$$"
  {
    for v in VPS_HOST VPS_PORT VPS_USER VPS_PASSWORD SWITCH_DIR SWITCH_FILE \
             REMOTE_PORT LOCAL_HOST LOCAL_PORT SSH_KEY POLL_INTERVAL SSH_TIMEOUT \
             LOG_FILE RUNTIME_DIR ON_DAEMON_EXIT AUTO_RELOAD \
             SWITCH_PATH TARGET FORWARD SOCK PIDFILE LOCKFILE; do
      printf '%s=%q\n' "$v" "${!v-}"
    done
  } > "$snapfile"

  if ! load_config; then
    log "配置重载失败，已回滚并继续使用上一次的有效配置"
    source "$snapfile"
    rm -f "$snapfile"
    build_ssh_cmd
    return 1
  fi
  rm -f "$snapfile"

  [[ "$old_sock" != "$SOCK" ]] && changed=1

  # 用 -e 而非 -S：陈旧/残留的 socket 文件同样要收掉，否则会留下无人管理的孤儿
  if [[ "$changed" == "1" ]] && [[ -e "$old_sock" ]]; then
    log "隧道标识已变更（${old_sock} -> ${SOCK}），先关闭旧隧道"
    cur_sock="$SOCK"
    SOCK="$old_sock"; PIDFILE="$old_pidfile"
    tunnel_stop
    SOCK="$cur_sock"
  fi

  log "配置已重载生效（${CONFIG_FILE}）"
  return 0
}

# 检测配置文件是否被改动，改动则热加载
auto_reload_if_changed() {
  [[ "${AUTO_RELOAD:-1}" == "1" ]] || return 0
  local m
  m="$(config_mtime)"
  [[ -n "${CONFIG_MTIME:-}" ]] || { CONFIG_MTIME="$m"; return 0; }
  if [[ "$m" != "$CONFIG_MTIME" ]]; then
    CONFIG_MTIME="$m"
    log "检测到配置文件变更，自动热加载"
    reload_config
  fi
  return 0
}

# 构造到 VPS 的 ssh 命令 —— 强制密钥认证
build_ssh_cmd() {
  SSH_CMD=(ssh -i "$SSH_KEY")
  SSH_CMD+=(-o "StrictHostKeyChecking=accept-new")
  SSH_CMD+=(-o "ConnectTimeout=10")
  SSH_CMD+=(-o "ServerAliveInterval=60")
  SSH_CMD+=(-o "ServerAliveCountMax=3")
  SSH_CMD+=(-o "ExitOnForwardFailure=yes")
  SSH_CMD+=(-o "IdentitiesOnly=yes")   # 只用指定的私钥，避免受 ssh-agent 中其他密钥干扰
  SSH_CMD+=(-o "BatchMode=yes")        # 非交互：密钥不可用/需口令时直接失败，而不是卡住等待输入
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
# 配置类错误：只记录不 exit，让调用方能回滚到上一次的有效配置
cfg_err() {
  printf '[%s] CONFIG ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  [[ -n "${LOG_FILE:-}" ]] && printf '[%s] CONFIG ERROR: %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
  return 1
}

usage() {
  cat <<EOF
用法: $(basename "$0") {daemon|once|start|stop|restart|status|check}

  daemon    前台常驻，按开关文件周期性调度隧道
  once      只跑一轮判断
  start     手动建立隧道
  stop      手动关闭隧道
  restart   手动重启隧道
  status    查看隧道状态
  check     打印解析后的配置（密码脱敏）
  reload    校验并应用配置变更

配置文件: ${CONFIG_FILE}
守护进程运行中修改该文件会自动热加载（最多延迟一个 poll_interval）
EOF
}

# ---------------- 开关文件读取（口令比对） ----------------
# 输出 match / mismatch；无法获取时输出 unreachable 并返回非 0
# 远端只做「取首行 + 去掉 CR 与首尾空白」，口令不做大小写转换，也绝不打印到日志
read_switch() {
  local out rc
  out=$(timeout "$SSH_TIMEOUT" "${SSH_CMD[@]}" "$TARGET" \
        "cat '${SWITCH_PATH}' 2>/dev/null | head -n1 | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'" 2>/dev/null)
  rc=$?
  if [[ $rc -ne 0 ]]; then
    printf 'unreachable'
    return $rc
  fi
  if [[ -n "$out" && "$out" == "$VPS_PASSWORD" ]]; then
    printf 'match'
  else
    printf 'mismatch'
  fi
  return 0
}

# ---------------- 隧道状态与控制 ----------------
tunnel_pid() {
  local p
  p="$(pgrep -f -- "-fNMS ${SOCK}" 2>/dev/null | head -n1)"
  [[ -n "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

is_up() {
  local p
  if p="$(tunnel_pid)"; then
    [[ -n "$p" ]] && return 0
  fi
  # 进程没了但残留 socket，顺手清掉
  [[ -S "$SOCK" ]] && rm -f "$SOCK"
  return 1
}

remote_listening() {
  is_up || return 1
  timeout 10 ssh -S "$SOCK" -o "ConnectTimeout=5" "$TARGET" \
    "ss -tln 2>/dev/null | grep -q ':${REMOTE_PORT}\$' || netstat -tln 2>/dev/null | grep -q ':${REMOTE_PORT}\$'" \
    >/dev/null 2>&1
}

tunnel_start() {
  local pid i
  mkdir -p "$RUNTIME_DIR"
  [[ -S "$SOCK" ]] && rm -f "$SOCK"

  log "启动隧道 ${VPS_HOST}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}"
  if ! timeout "$SSH_TIMEOUT" "${SSH_CMD[@]}" -fNMS "$SOCK" -R "$FORWARD" "$TARGET" >>"$LOG_FILE" 2>&1; then
    log "隧道启动失败（详见日志尾部）"
    return 1
  fi

  for i in $(seq 1 20); do
    pid="$(tunnel_pid)" && break
    sleep 0.5
  done
  if [[ -n "${pid:-}" ]]; then
    echo "$pid" > "$PIDFILE"
    log "隧道已启动，本地 ssh PID=${pid}"
  else
    log "警告：未找到 ssh 进程，隧道可能未真正建立"
    return 1
  fi

  for i in $(seq 1 10); do
    if remote_listening; then
      log "对端 ${REMOTE_PORT} 已监听，隧道就绪"
      return 0
    fi
    sleep 1
  done
  log "警告：隧道已建立但未检测到对端 ${REMOTE_PORT} 监听，检查 VPS 的 GatewayPorts 是否为 yes"
  return 0
}

tunnel_stop() {
  local pid i
  pid="$(tunnel_pid)" || pid=""

  if [[ -S "$SOCK" ]]; then
    log "关闭隧道（ssh -O exit）"
    ssh -S "$SOCK" -O exit "$TARGET" >/dev/null 2>&1
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
    rm -f "$SOCK"
  fi

  rm -f "$PIDFILE" "$SOCK"
  log "隧道已关闭"
  return 0
}

# ---------------- 期望状态对齐 ----------------
ensure_up() {
  if is_up; then
    log "口令匹配，隧道已在运行，无需操作"
    return 0
  fi
  tunnel_start
}

ensure_down() {
  if is_up; then
    tunnel_stop
  else
    log "口令不匹配，隧道已关闭，无需操作"
  fi
  return 0
}

# 一轮调度
tick() {
  local state rc
  state="$(read_switch)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    log "无法获取开关文件 ${SWITCH_PATH}（exit=$rc），按不放行处理"
    ensure_down
    return 0
  fi

  case "$state" in
    match)    log "开关文件 ${SWITCH_PATH} 口令匹配 -> 放行"; ensure_up ;;
    mismatch) log "开关文件 ${SWITCH_PATH} 口令不匹配 -> 不放行"; ensure_down ;;
    *)        log "开关文件内容异常，按不放行处理"; ensure_down ;;
  esac
  return 0
}

# ---------------- 守护进程 ----------------
DAEMON_RUN=1

daemon() {
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    die "已有守护进程实例在运行（锁: $LOCKFILE）"
  fi

  CONFIG_MTIME="$(config_mtime)"
  log "守护进程启动 PID=$$ 配置=${CONFIG_FILE} 开关=${VPS_USER}@${VPS_HOST}:${SWITCH_PATH} 间隔=${POLL_INTERVAL}s 自动热加载=${AUTO_RELOAD}"
  trap 'DAEMON_RUN=0' TERM INT
  trap 'DAEMON_RUN=0; log "收到 HUP，重载配置"; reload_config; CONFIG_MTIME="$(config_mtime)"; DAEMON_RUN=1' HUP

  while [[ "$DAEMON_RUN" == "1" ]]; do
    auto_reload_if_changed
    tick
    local i=0
    while [[ "$DAEMON_RUN" == "1" && $i -lt "$POLL_INTERVAL" ]]; do
      sleep 1
      i=$((i + 1))
    done
  done

  log "守护进程退出"
  if [[ "$ON_DAEMON_EXIT" == "close" ]]; then
    log "on_daemon_exit=close，关闭隧道"
    ensure_down
  else
    log "on_daemon_exit=keep，保持隧道现状"
  fi
  return 0
}

# ---------------- 子命令 ----------------
do_status() {
  local pid; pid="$(tunnel_pid)" || pid=""
  if is_up; then
    log "隧道状态: 运行中  PID=${pid:-未知}  socket=${SOCK}"
    if remote_listening; then
      log "对端 ${VPS_HOST}:${REMOTE_PORT} 正在监听 -> ${LOCAL_HOST}:${LOCAL_PORT}"
    else
      log "对端未在监听 ${REMOTE_PORT}，检查 VPS 的 GatewayPorts"
    fi
  else
    log "隧道状态: 未运行"
  fi

  local state rc
  state="$(read_switch)"; rc=$?
  case "$state" in
    match)    log "开关文件 ${SWITCH_PATH}: 口令匹配（放行）" ;;
    mismatch) log "开关文件 ${SWITCH_PATH}: 口令不匹配（不放行）" ;;
    *)        log "开关文件 ${SWITCH_PATH}: 无法获取（不放行）" ;;
  esac
}

do_check() {
  cat <<EOF
配置文件    : ${CONFIG_FILE}
VPS         : ${VPS_USER}@${VPS_HOST}:${VPS_PORT}
SSH 认证    : 密钥 ${SSH_KEY}（强制密钥，不支持密码登录）
启动口令    : 已设置，${#VPS_PASSWORD} 位（明文永不打印到日志）
开关文件    : ${SWITCH_PATH}（首行内容须与启动口令完全一致才放行）
隧道映射    : ${VPS_HOST}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}
轮询间隔    : ${POLL_INTERVAL} 秒
SSH 超时    : ${SSH_TIMEOUT} 秒
自动热加载  : ${AUTO_RELOAD}（1=改配置自动生效 / 0=需手动 reload）
日志        : ${LOG_FILE}
运行目录    : ${RUNTIME_DIR}
退出时动作  : ${ON_DAEMON_EXIT}（keep=保持现状 / close=关闭隧道）
EOF
}

# ---------------- main ----------------
case "${1:-daemon}" in
  daemon)  load_config || exit 1; daemon ;;
  once)    load_config || exit 1; tick ;;
  start)   load_config || exit 1; ensure_up ;;
  stop)    load_config || exit 1; ensure_down ;;
  restart) load_config || exit 1; ensure_down; sleep 1; ensure_up ;;
  status)  load_config || exit 1; do_status ;;
  check)   load_config || exit 1; do_check ;;
  reload)  load_config || exit 1; reload_config ;;
  -h|--help|help) usage ;;
  *)       usage; exit 1 ;;
esac
