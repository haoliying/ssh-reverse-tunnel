#!/usr/bin/env bash
# ============================================================
# ssh-tunnel-lite.sh — 多隧道 ssh -R 反向隧道（单脚本自守护，不依赖 systemd）
#
# 一个 VPS + 一个配置文件 + 多条映射。每条隧道一个独立守护进程，
# 独立重连、独立启停；start 会同时拉起所有选中的隧道。
#
# 认证: 强制 SSH 密钥。VPS 连接信息在配置文件里只写一份（全局段）。
#
# ------------------------------------------------------------
# 配置文件格式（段式，推荐）:
#
#   vps_host: 1.2.3.4          # 全局段：VPS 连接信息，只写一份
#   vps_port: 22
#   vps_user: root
#   ssh_key: /data/keys/id_rsa
#   remote_bind_addr: 0.0.0.0
#
#   [tunnel:web]               # 每条映射一个段，名字自定义
#   remote_port: 8080
#   local_host: 127.0.0.1
#   local_port: 80
#
#   [tunnel:ssh]
#   remote_port: 2222
#   local_port: 22
#   enabled: 1                 # 可选，0/no/false 时 start all 会跳过
#
#   段内可用键: remote_port(必填) / local_host / local_port /
#              remote_bind_addr / enabled / log_file
#   全局可用键: vps_host / vps_port / vps_user / ssh_key /
#              remote_bind_addr / check_interval / health_check /
#              health_interval / ssh_timeout / start_timeout / log_file
#
# 兼容: 旧扁平格式（tunnel_remote_port / tunnel_local_host /
#       tunnel_local_port）会被当成一条名为 default 的隧道。
# ------------------------------------------------------------
#
# 用法:
#   ./ssh-tunnel-lite.sh start   -f conf/ssh.conf              # 启动全部
#   ./ssh-tunnel-lite.sh start   -f conf/ssh.conf web ssh      # 只启动这两条
#   ./ssh-tunnel-lite.sh start   -f conf/ssh.conf -t web,ssh   # 同上
#   ./ssh-tunnel-lite.sh stop    -f conf/ssh.conf              # 停止全部
#   ./ssh-tunnel-lite.sh stop    -f conf/ssh.conf web          # 只停 web
#   ./ssh-tunnel-lite.sh status  -f conf/ssh.conf
#   ./ssh-tunnel-lite.sh list    -f conf/ssh.conf              # 列出隧道及状态
#   ./ssh-tunnel-lite.sh restart -f conf/ssh.conf
#   ./ssh-tunnel-lite.sh dump    -f conf/ssh.conf              # 诊断解析结果
#   ./ssh-tunnel-lite.sh selfinfo                             # 确认部署版本
#   ./ssh-tunnel-lite.sh daemon  -f conf/ssh.conf -t web       # 前台跑一条，调试用
#
# 旧用法（完全保留）:
#   ./ssh-tunnel-lite.sh start  -s 1.2.3.4 -r 8080 -p 80
#   ./ssh-tunnel-lite.sh stop   -s 1.2.3.4 -r 8080
#   ./ssh-tunnel-lite.sh start  -f conf/ssh.conf -p 8080
#   （给了 -r 就是"单条命令行隧道"模式，只借用配置里的 VPS 信息）
#
# 选项:
#   -f, --file PATH          配置文件
#   -t, --tunnel NAME        指定要操作的隧道名/端口，可重复或逗号分隔
#   -s, --host HOST          VPS 地址（覆盖配置文件）
#   -k, --key-file PATH      私钥文件（覆盖配置文件）
#   -r, --remote-port PORT   单条命令行隧道模式
#   -H, --local-host ADDR    单条模式：内网地址
#   -p, --local-port PORT    单条模式：内网端口
#   -h, --help               帮助
# ============================================================

set -uo pipefail

# 脚本版本：报错和 status 里都会打出来，便于确认服务器上跑的是哪一份
SCRIPT_VER="2026-11-16.1"

# ---------------- 脚本内常量（不读任何环境变量，要改就改这里） ----------------
VPS_HOST=""                  # VPS 地址
VPS_USER="root"              # VPS 登录用户名
VPS_PORT="22"                # VPS 的 SSH 端口
KEY_FILE="/data/keys/id_rsa" # 私钥文件

# 调参常量（一般不用动）
CHECK_INTERVAL=10            # 每隔多少秒检查隧道存活
HEALTH_CHECK=1               # 1=开启深度探测 / 0=只查本地进程
HEALTH_INTERVAL=60           # 深度探测间隔（秒）
SSH_TIMEOUT=15               # 单次 ssh 操作超时（秒）
START_TIMEOUT=30             # start 后等待就绪的最长时间（秒）
REMOTE_BIND="0.0.0.0"        # VPS 侧监听地址，0.0.0.0=对外可访问

SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# ---------------- 参数状态 ----------------
ACTION=""
CONFIG_FILE=""
declare -a TUNNEL_CLI=()     # -t / 位置参数收集的隧道名
CLI_HOST=0; CLI_KEY=0; CLI_RPORT=0; CLI_LHOST=0; CLI_LPORT=0
REMOTE_PORT=""               # 单条命令行隧道模式用
LOCAL_HOST="127.0.0.1"
LOCAL_PORT="80"

# ---------------- 配置解析结果 ----------------
# 不用关联数组：bash 4.2 在 set -u 下对空关联数组/嵌套下标有坑，
# 改用「键数组 + 值数组」线性查表，配置文件几十行，性能完全够。
declare -a G_KEYS=() G_VALS=()      # 全局段 key/value
declare -a T_KEYS=() T_VALS=()      # 隧道段 "name.key"/value
declare -a T_NAMES=()               # 段名（按出现顺序）

# ---------------- 隧道清单（build_tunnels 产出） ----------------
declare -a TUN_NAMES=() TUN_RPORT=() TUN_LHOST=() TUN_LPORT=()
declare -a TUN_BIND=() TUN_LOG=() TUN_ENABLED=()
declare -a SELECTED=()              # 本次要操作的隧道索引

# ---------------- 当前正在操作的隧道上下文 ----------------
CUR_NAME=""
LOG_TAG=""                  # log() 输出前缀

usage() {
  cat <<'EOF'
用法: ssh-tunnel-lite.sh <动作> [隧道名...] [选项]

动作:
  start     启动隧道（默认全部；可指定名字只启动其中几条）
  stop      优雅停止
  restart   重启
  status    逐条显示状态 + 对端监听情况
  list      列出配置文件里的所有隧道及运行状态
  dump      诊断: 打印配置解析结果与原始字节
  selfinfo  诊断: 打印脚本版本、路径、校验值
  daemon    前台运行一条隧道（调试用，需 -t 指定）

隧道选择:
  不写名字 = 全部（可用 all 显式表示）
  名字可写在动作后面，也可用 -t 指定，支持逗号分隔:
    start web ssh        /  start -t web,ssh
    stop  8080           （也可用 remote_port 当名字）
  enabled: 0 的隧道在「全部」模式下会跳过，显式点名仍可启动

选项:
  -f, --file PATH          配置文件（VPS 信息只写一份，多个 [tunnel:名字] 段）
  -t, --tunnel NAME        指定隧道，可重复或逗号分隔
  -s, --host HOST          VPS 地址（覆盖配置文件）
  -k, --key-file PATH      私钥文件（覆盖配置文件）
  -r, --remote-port PORT   单条命令行隧道模式（沿用旧用法）
  -H, --local-host ADDR    单条模式：内网地址（默认 127.0.0.1）
  -p, --local-port PORT    单条模式：内网端口（默认 80）
  -h, --help               显示本帮助

配置文件（段式）:
  vps_host: 1.2.3.4
  vps_user: root
  ssh_key: /data/keys/id_rsa

  [tunnel:web]
  remote_port: 8080
  local_port: 80

  [tunnel:ssh]
  remote_port: 2222
  local_port: 22

示例:
  ./ssh-tunnel-lite.sh start  -f conf/ssh.conf
  ./ssh-tunnel-lite.sh start  -f conf/ssh.conf web ssh
  ./ssh-tunnel-lite.sh stop   -f conf/ssh.conf web
  ./ssh-tunnel-lite.sh status -f conf/ssh.conf
  ./ssh-tunnel-lite.sh list   -f conf/ssh.conf
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
out() { printf '%s\n' "$*"; }

log() {
  local line="[$(date '+%F %T')]${LOG_TAG:+ [$LOG_TAG]} $*"
  printf '%s\n' "$line"
  [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null
  return 0
}

# ---------------- 值清洗 ----------------
# 配置文件常被 Windows 编辑器或从文档复制带入不可见字符，统一按字节清理。
# 锁 LC_ALL=C：UTF-8 locale 下 sed 会把 [\x80-\x8b] 当成 collation range 报错。
# 顺带处理全角数字 ０-９、全角引号 “ ” ‘ ’、BOM、NBSP、各类 Unicode 空格。
sanitize_val() {
  printf '%s' "$1" \
    | LC_ALL=C sed -e 's/\xef\xbb\xbf//g' \
                     -e 's/\xc2\xa0/ /g' \
                     -e 's/\xe2\x80[\x80-\x8b]/ /g' \
                     -e 's/\xe2\x80\xaf/ /g' \
                     -e 's/\xe3\x80\x80/ /g' \
                     -e 's/\xe2\x80[\x98\x99\x9c\x9d]//g' \
                     -e 's/\xef\xbc\x90/0/g' \
                     -e 's/\xef\xbc\x91/1/g' \
                     -e 's/\xef\xbc\x92/2/g' \
                     -e 's/\xef\xbc\x93/3/g' \
                     -e 's/\xef\xbc\x94/4/g' \
                     -e 's/\xef\xbc\x95/5/g' \
                     -e 's/\xef\xbc\x96/6/g' \
                     -e 's/\xef\xbc\x97/7/g' \
                     -e 's/\xef\xbc\x98/8/g' \
                     -e 's/\xef\xbc\x99/9/g' \
    | LC_ALL=C tr -d '\000-\037\177'
}

trim_val() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 顺序不能反：先 trim 再清洗的话，Unicode 空格转换出的普通空格就没人裁了。
clean_scalar() { trim_val "$(sanitize_val "$1")"; }

# 把一个配置值彻底归一化：清洗 -> trim -> 剥引号/截注释 -> 再 trim。
# 「再 trim」不能省：引号内的空格、注释前的对齐空格是变换后才暴露的。
# 注意「引号值 + 行内注释」（如  local_port: "80  "  # 说明）：
# 必须先按配对引号把值截出来，否则末尾的注释会让「以引号结尾」的判断失效，
# 截完注释后剩下一个带引号的字符串，引号就剥不掉了。
norm_value() {
  local v q tail
  v="$(clean_scalar "$1")"
  if [[ "$v" == \"* || "$v" == \'* ]]; then
    q="${v:0:1}"
    tail="${v:1}"
    if [[ "$tail" == *"$q"* ]]; then
      v="${q}${tail%%"$q"*}${q}"      # 引号内的 # 不算注释
    fi
  else
    v="${v%%#*}"
  fi
  v="$(trim_val "$v")"
  if [[ "$v" =~ ^\".*\"$ || "$v" =~ ^\'.*\'$ ]]; then
    v="${v:1:${#v}-2}"
  fi
  trim_val "$v"
}

# 端口校验：纯数字且 >= 1。值里混入不可见字符时直接把字节打出来。
check_port() {
  local name="$1" val="$2" ctrl hex trimmed
  if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -ge 1 ]]; then
    return 0
  fi
  hex=$(printf '%s' "$val" | od -An -tx1 -v | tr -s ' ' | tr -d '\n' | sed 's/^ //')
  printf 'ERROR: %s 必须是数字（脚本版本 %s）\n' "$name" "$SCRIPT_VER" >&2
  printf '       当前值(可见)   : [%s]\n' "$(printf '%s' "$val" | cat -A | tr -d '\n')" >&2
  printf '       当前值(十六进制): %s\n' "$hex" >&2
  trimmed="$(trim_val "$val")"
  if [[ "$trimmed" =~ ^[0-9]+$ ]] && [[ "$trimmed" -ge 1 ]]; then
    printf '       数字本身是 %s，只是首尾多了 %s 个空白字符（0x20）\n' \
      "$trimmed" "$(( ${#val} - ${#trimmed} ))" >&2
    printf '       常见来源: 对齐用的行尾空格、引号内的空格、行内注释前的空格\n' >&2
    printf '       本版已自动裁剪；若仍报此错，用 selfinfo 核对脚本版本\n' >&2
    printf '       定位: 执行 %s dump -f %s 查看原始字节\n' "${SELF##*/}" "${CONFIG_FILE:-<配置文件>}" >&2
    exit 1
  fi
  ctrl=$(printf '%s' "$val" | tr -cd '[:cntrl:]' | wc -c | tr -d ' ')
  if [[ "${ctrl:-0}" -gt 0 ]]; then
    printf '       含 %s 个控制字符，多半是 CRLF 换行，处理: sed -i "s/\\r$//" %s\n' "$ctrl" "${CONFIG_FILE:-配置文件}" >&2
  else
    printf '       含非数字字节（常见原因: 全角空格、NBSP、全角数字、复制带出的不可见字符）\n' >&2
    printf '       处理: sed -i -e "s/\\xef\\xbb\\xbf//g" -e "s/[[:space:]]*$//" %s\n' "${CONFIG_FILE:-配置文件}" >&2
  fi
  printf '       定位: 执行 %s dump -f %s 查看原始字节\n' "${SELF##*/}" "${CONFIG_FILE:-<配置文件>}" >&2
  exit 1
}

# 相对路径转绝对路径：守护进程 fork 后必须还能找到配置文件
abspath() {
  local p="$1" d
  [[ "$p" == /* ]] && { printf '%s' "$p"; return 0; }
  [[ "$p" =~ ^[A-Za-z]:[/\\] ]] && { printf '%s' "$p"; return 0; }  # Windows 盘符
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd)" || { printf '%s' "$p"; return 0; }
  printf '%s/%s' "$d" "$(basename "$p")"
}

# ---------------- 配置文件解析 ----------------
# 结果放进 G_KEYS/G_VALS（全局段）与 T_KEYS/T_VALS（"段名.键"）。
set_kv() {
  local sec="$1" k="$2" v="$3" i key
  if [[ -z "$sec" ]]; then
    for ((i=0; i<${#G_KEYS[@]}; i++)); do
      if [[ "${G_KEYS[$i]}" == "$k" ]]; then G_VALS[$i]="$v"; return 0; fi
    done
    G_KEYS+=("$k"); G_VALS+=("$v")
  else
    key="${sec}.${k}"
    for ((i=0; i<${#T_KEYS[@]}; i++)); do
      if [[ "${T_KEYS[$i]}" == "$key" ]]; then T_VALS[$i]="$v"; return 0; fi
    done
    T_KEYS+=("$key"); T_VALS+=("$v")
  fi
  return 0
}

g() {  # g <全局键> [默认值]
  local k="$1" d="${2:-}" i
  for ((i=0; i<${#G_KEYS[@]}; i++)); do
    if [[ "${G_KEYS[$i]}" == "$k" ]]; then printf '%s' "${G_VALS[$i]}"; return 0; fi
  done
  printf '%s' "$d"
}

t() {  # t <段名> <键> [默认值]
  local key="$1.$2" d="${3:-}" i
  for ((i=0; i<${#T_KEYS[@]}; i++)); do
    if [[ "${T_KEYS[$i]}" == "$key" ]]; then printf '%s' "${T_VALS[$i]}"; return 0; fi
  done
  printf '%s' "$d"
}

load_conf() {
  G_KEYS=(); G_VALS=(); T_KEYS=(); T_VALS=(); T_NAMES=()
  [[ -n "$CONFIG_FILE" ]] || return 0
  [[ -f "$CONFIG_FILE" ]] || die "-f 指定的配置文件不存在: $CONFIG_FILE"

  local line key val sec="" header nm n=0 i
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="$(clean_scalar "$line")"
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue
    line="${line//$'\xef\xbc\x9a'/:}"     # 全角冒号 -> 半角

    # 段头 [tunnel:名字]
    if [[ "${line:0:1}" == "[" ]]; then
      header="$(trim_val "${line%%#*}")"
      [[ "$header" =~ ^\[tunnel:(.+)\]$ ]] || \
        die "配置文件第 ${n} 行: 段头格式应为 [tunnel:名字]，实际: ${line}"
      nm="$(trim_val "${BASH_REMATCH[1]}")"
      [[ -n "$nm" ]] || die "配置文件第 ${n} 行: [tunnel:] 缺少隧道名"
      [[ "$nm" != *:* ]] || die "配置文件第 ${n} 行: 隧道名不能含冒号: ${nm}"
      for ((i=0; i<${#T_NAMES[@]}; i++)); do
        [[ "${T_NAMES[$i]}" == "$nm" ]] && die "配置文件第 ${n} 行: 隧道名重复: ${nm}"
      done
      T_NAMES+=("$nm"); sec="$nm"
      continue
    fi

    [[ "$line" == *:* ]] || die "配置文件第 ${n} 行: 缺少冒号: ${line}"
    key="$(trim_val "${line%%:*}")"
    val="$(norm_value "${line#*:}")"
    [[ -n "$key" ]] || die "配置文件第 ${n} 行: 键为空"
    set_kv "$sec" "$key" "$val"
  done < "$CONFIG_FILE"
  return 0
}

# 全局项（VPS 与调参）应用到脚本变量，并做最终归一化
apply_globals() {
  [[ "$CLI_HOST" == "0" ]] && VPS_HOST="$(g vps_host "$VPS_HOST")"
  [[ "$CLI_KEY"  == "0" ]] && KEY_FILE="$(g ssh_key "$KEY_FILE")"
  VPS_USER="$(g vps_user "$VPS_USER")"
  VPS_PORT="$(g vps_port "$VPS_PORT")"
  REMOTE_BIND="$(g remote_bind_addr "$REMOTE_BIND")"
  CHECK_INTERVAL="$(g check_interval "$CHECK_INTERVAL")"
  HEALTH_CHECK="$(g health_check "$HEALTH_CHECK")"
  HEALTH_INTERVAL="$(g health_interval "$HEALTH_INTERVAL")"
  SSH_TIMEOUT="$(g ssh_timeout "$SSH_TIMEOUT")"
  START_TIMEOUT="$(g start_timeout "$START_TIMEOUT")"

  VPS_HOST="$(clean_scalar "${VPS_HOST:-}")"
  VPS_USER="$(clean_scalar "${VPS_USER:-}")"
  VPS_PORT="$(clean_scalar "${VPS_PORT:-}")"
  KEY_FILE="$(clean_scalar "${KEY_FILE:-}")"
  REMOTE_BIND="$(clean_scalar "${REMOTE_BIND:-}")"
  CHECK_INTERVAL="$(clean_scalar "${CHECK_INTERVAL:-}")"
  HEALTH_CHECK="$(clean_scalar "${HEALTH_CHECK:-}")"
  HEALTH_INTERVAL="$(clean_scalar "${HEALTH_INTERVAL:-}")"
  SSH_TIMEOUT="$(clean_scalar "${SSH_TIMEOUT:-}")"
  START_TIMEOUT="$(clean_scalar "${START_TIMEOUT:-}")"
  return 0
}

# 构造隧道清单。三种模式:
#   A 给了 -r             -> 单条命令行隧道（完全沿用旧用法）
#   B 配置里有 [tunnel:x] -> 多条
#   C 旧扁平格式          -> 一条名为 default 的隧道
build_tunnels() {
  TUN_NAMES=(); TUN_RPORT=(); TUN_LHOST=(); TUN_LPORT=()
  TUN_BIND=(); TUN_LOG=(); TUN_ENABLED=()

  local gd_bind g_log def_lh def_lp
  gd_bind="$(g remote_bind_addr "$REMOTE_BIND")"
  g_log="$(g log_file '')"
  def_lh="$(g tunnel_local_host "$(g local_host '127.0.0.1')")"
  def_lp="$(g tunnel_local_port "$(g local_port '80')")"

  # 模式 A
  if [[ "$CLI_RPORT" == "1" ]]; then
    TUN_NAMES+=("cli");       TUN_RPORT+=("$REMOTE_PORT")
    TUN_LHOST+=("$LOCAL_HOST"); TUN_LPORT+=("$LOCAL_PORT")
    TUN_BIND+=("$gd_bind");   TUN_LOG+=("$g_log"); TUN_ENABLED+=("1")
    return 0
  fi

  # 模式 B
  if (( ${#T_NAMES[@]} > 0 )); then
    local i nm r lh lp b lg en
    # 多隧道模式下 -H/-p 没有明确归属，提醒一声，别静默忽略
    if [[ "$CLI_LHOST" == "1" || "$CLI_LPORT" == "1" ]]; then
      printf '警告: 多隧道模式下 -H/-p 不生效，请在 [tunnel:名字] 段内写 local_host/local_port\n' >&2
    fi
    for ((i=0; i<${#T_NAMES[@]}; i++)); do
      nm="${T_NAMES[$i]}"
      r="$(t "$nm" remote_port "$(t "$nm" tunnel_remote_port '')")"
      if [[ -z "$r" ]]; then
        [[ "${ALLOW_EMPTY:-0}" == "1" ]] && continue
        die "隧道 [${nm}] 缺少 remote_port"
      fi
      lh="$(t "$nm" local_host "$(t "$nm" tunnel_local_host "$def_lh")")"
      lp="$(t "$nm" local_port "$(t "$nm" tunnel_local_port "$def_lp")")"
      b="$(t "$nm" remote_bind_addr "$gd_bind")"
      lg="$(t "$nm" log_file "$g_log")"
      en="$(t "$nm" enabled 1)"
      TUN_NAMES+=("$nm");     TUN_RPORT+=("$r")
      TUN_LHOST+=("$lh");     TUN_LPORT+=("$lp")
      TUN_BIND+=("$b");       TUN_LOG+=("$lg"); TUN_ENABLED+=("$en")
    done
  else
    # 模式 C：旧扁平格式。保留 -p/-H 命令行覆盖，向后兼容旧用法
    local flat_r
    flat_r="$(g tunnel_remote_port '')"
    [[ "$CLI_LHOST" == "1" ]] && def_lh="$LOCAL_HOST"
    [[ "$CLI_LPORT" == "1" ]] && def_lp="$LOCAL_PORT"
    if [[ -z "$flat_r" ]]; then
      [[ "${ALLOW_EMPTY:-0}" == "1" ]] && return 0
      die "配置文件里没有任何隧道：请写 [tunnel:名字] 段，或用 -r 指定端口"
    fi
    TUN_NAMES+=("default"); TUN_RPORT+=("$flat_r")
    TUN_LHOST+=("$def_lh"); TUN_LPORT+=("$def_lp")
    TUN_BIND+=("$gd_bind"); TUN_LOG+=("$g_log"); TUN_ENABLED+=("1")
  fi

  # remote_port 重复检查：socket/pid/lock 都按端口命名，撞了会互相抢
  local i j
  for ((i=0; i<${#TUN_RPORT[@]}; i++)); do
    for ((j=i+1; j<${#TUN_RPORT[@]}; j++)); do
      [[ "${TUN_RPORT[$i]}" == "${TUN_RPORT[$j]}" ]] && \
        die "隧道 [${TUN_NAMES[$i]}] 与 [${TUN_NAMES[$j]}] 的 remote_port 重复: ${TUN_RPORT[$i]}"
    done
  done
  return 0
}

is_disabled() {
  local en="${1:-1}"
  en="${en,,}"
  case "$en" in 0|no|false|off|disabled) return 0 ;; esac
  return 1
}

# 选出本次要操作的隧道索引，放进 SELECTED
select_tunnels() {
  SELECTED=()
  local i j w part found all=0
  local -a wants=() parts=()

  for ((i=0; i<${#TUNNEL_CLI[@]}; i++)); do
    w="$(clean_scalar "${TUNNEL_CLI[$i]}")"
    [[ -n "$w" ]] || continue
    [[ "$w" == "all" ]] && { all=1; continue; }
    # 支持逗号分隔
    IFS=',' read -r -a parts <<< "$w"
    for ((j=0; j<${#parts[@]}; j++)); do
      part="$(trim_val "${parts[$j]}")"
      [[ -n "$part" ]] && wants+=("$part")
    done
  done

  if (( all == 1 || ${#wants[@]} == 0 )); then
    for ((i=0; i<${#TUN_NAMES[@]}; i++)); do
      # enabled: 0 的隧道在「全部」模式下跳过
      is_disabled "${TUN_ENABLED[$i]}" && continue
      SELECTED+=("$i")
    done
    (( ${#SELECTED[@]} > 0 )) || die "没有可操作的隧道（全部被 enabled: 0 禁用）"
    return 0
  fi

  # 显式点名：忽略 enabled，按名字或 remote_port 匹配
  for ((i=0; i<${#wants[@]}; i++)); do
    w="${wants[$i]}"; found=0
    for ((j=0; j<${#TUN_NAMES[@]}; j++)); do
      if [[ "${TUN_NAMES[$j]}" == "$w" || "${TUN_RPORT[$j]}" == "$w" ]]; then
        # 去重
        local dup=0 q
        for ((q=0; q<${#SELECTED[@]}; q++)); do
          [[ "${SELECTED[$q]}" == "$j" ]] && dup=1
        done
        (( dup == 0 )) && SELECTED+=("$j")
        found=1
        break
      fi
    done
    if (( found == 0 )); then
      printf 'ERROR: 找不到隧道: %s\n       可用: ' "$w" >&2
      for ((j=0; j<${#TUN_NAMES[@]}; j++)); do
        printf '%s(%s) ' "${TUN_NAMES[$j]}" "${TUN_RPORT[$j]}" >&2
      done
      printf '\n' >&2
      exit 1
    fi
  done
  return 0
}

# 把某条隧道的上下文设为"当前"，后续所有单隧道函数直接复用
apply_tunnel() {
  local i="$1"
  CUR_NAME="${TUN_NAMES[$i]}"
  REMOTE_PORT="${TUN_RPORT[$i]}"
  LOCAL_HOST="${TUN_LHOST[$i]}"
  LOCAL_PORT="${TUN_LPORT[$i]}"
  REMOTE_BIND="${TUN_BIND[$i]}"
  LOG_TAG="$CUR_NAME"

  check_port "remote_port（隧道 ${CUR_NAME}）" "$REMOTE_PORT"
  check_port "local_port（隧道 ${CUR_NAME}）" "$LOCAL_PORT"

  TARGET="${VPS_USER}@${VPS_HOST}"
  FORWARD="${REMOTE_BIND}:${REMOTE_PORT}:${LOCAL_HOST}:${LOCAL_PORT}"
  SOCK="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.sock"
  PIDFILE="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.pid"
  LOCKFILE="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.lock"
  LOG_FILE="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.log"
  [[ -n "${TUN_LOG[$i]}" ]] && LOG_FILE="${TUN_LOG[$i]}"
  return 0
}

# ---------------- 参数解析 ----------------
parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  ACTION="$1"; shift
  case "$ACTION" in
    start|stop|restart|status|list|daemon|_daemon|dump|selfinfo|about) ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf 'ERROR: 未知动作: %s\n\n' "$ACTION" >&2; usage; exit 1 ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--host)         VPS_HOST="${2:-}";   CLI_HOST=1;  shift 2 ;;
      -k|--key-file)     KEY_FILE="${2:-}";   CLI_KEY=1;   shift 2 ;;
      -r|--remote-port) REMOTE_PORT="${2:-}"; CLI_RPORT=1; shift 2 ;;
      -H|--local-host)  LOCAL_HOST="${2:-}";  CLI_LHOST=1; shift 2 ;;
      -p|--local-port)  LOCAL_PORT="${2:-}";  CLI_LPORT=1; shift 2 ;;
      -f|--file)        CONFIG_FILE="${2:-}"
                        [[ -n "$CONFIG_FILE" ]] || die "-f/--file 需要一个配置文件路径参数"
                        shift 2 ;;
      -t|--tunnel)      [[ -n "${2:-}" ]] || die "-t/--tunnel 需要一个隧道名"
                        TUNNEL_CLI+=("$2"); shift 2 ;;
      -h|--help)        usage; exit 0 ;;
      -*)               printf 'ERROR: 未知选项: %s\n\n' "$1" >&2; usage; exit 1 ;;
      *)                TUNNEL_CLI+=("$1"); shift ;;
    esac
  done

  # 命令行值也过一遍清洗（可能是从 Windows 脚本/文档粘贴来的）
  [[ "$CLI_HOST"  == "1" ]] && VPS_HOST="$(clean_scalar "$VPS_HOST")"
  [[ "$CLI_KEY"   == "1" ]] && KEY_FILE="$(clean_scalar "$KEY_FILE")"
  [[ "$CLI_RPORT" == "1" ]] && REMOTE_PORT="$(clean_scalar "$REMOTE_PORT")"
  [[ "$CLI_LHOST" == "1" ]] && LOCAL_HOST="$(clean_scalar "$LOCAL_HOST")"
  [[ "$CLI_LPORT" == "1" ]] && LOCAL_PORT="$(clean_scalar "$LOCAL_PORT")"

  # -f 转绝对路径，保证 fork 出去的守护进程仍能读到同一个文件
  [[ -n "$CONFIG_FILE" ]] && CONFIG_FILE="$(abspath "$CONFIG_FILE")"
  return 0
}

validate_globals() {
  check_port "vps_port" "$VPS_PORT"
  [[ -n "$VPS_HOST" ]] || die "未指定 VPS 地址：请加 -s/--host，或在配置文件全局段写 vps_host"
  [[ -n "$KEY_FILE" ]] || die "未指定私钥文件：请加 -k/--key-file，或在配置文件写 ssh_key"
  if [[ ! -f "$KEY_FILE" ]]; then
    local kdir
    kdir="$(dirname "$KEY_FILE")"
    printf 'ERROR: 私钥文件不存在: %s\n' "$KEY_FILE" >&2
    if [[ -d "$kdir" ]]; then
      printf '       目录 %s 下现有文件: %s\n' "$kdir" "$(ls -1 "$kdir" 2>/dev/null | tr '\n' ' ')" >&2
    fi
    exit 1
  fi
  local kperm
  kperm=$(stat -c %a "$KEY_FILE" 2>/dev/null)
  if [[ -n "$kperm" && "$kperm" != "600" && "$kperm" != "400" ]]; then
    printf '警告: 私钥 %s 权限为 %s，OpenSSH 要求 600 或更严格，建议 chmod 600 %s\n' \
      "$KEY_FILE" "$kperm" "$KEY_FILE"
  fi
  return 0
}

# ---------------- 基础工具 ----------------
build_ssh_cmd() {
  SSH_CMD=(ssh)
  [[ -n "$KEY_FILE" ]] && SSH_CMD+=(-i "$KEY_FILE")
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

# ---------------- 隧道状态与控制 ----------------
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
  [[ -e "$SOCK" ]] && rm -f "$SOCK"
  return 1
}

# 对端端口是否真的在监听（走 ControlMaster 复用连接，开销很小）
remote_listening() {
  is_up || return 1
  timeout 10 "${SSH_CMD[@]}" -S "$SOCK" -o "ConnectTimeout=5" "$TARGET" \
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
    "${SSH_CMD[@]}" -S "$SOCK" -O exit "$TARGET" >/dev/null 2>&1
    for i in $(seq 1 10); do
      is_up || break
      sleep 1
    done
  fi
  if is_up; then
    log "控制连接无响应，降级为 SIGTERM"
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 5); do
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
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

sleep_loop() {  # 可中断 sleep：拆成 1 秒，保证 stop 信号秒级响应
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
    die "端口 ${REMOTE_PORT} 的隧道已有守护进程在运行（锁: $LOCKFILE）"
  fi
  printf '%s\n' "$$" > "$PIDFILE"

  trap 'RUN=0' TERM INT
  log "守护进程启动 PID=$$ 脚本版本=${SCRIPT_VER} 登录=${VPS_USER}@${VPS_HOST}:${VPS_PORT} 私钥=${KEY_FILE}${CONFIG_FILE:+ 配置=${CONFIG_FILE}}"
  log "隧道映射 ${VPS_HOST}:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT} 检查间隔=${CHECK_INTERVAL}s"

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

# ---------------- 子命令：启动 ----------------
# 只 fork，不等待：多条隧道可以真正"同时"拉起
fork_daemon() {
  local dargs
  rm -f "$PIDFILE"
  log "后台启动守护进程"
  dargs=(_daemon -t "$CUR_NAME")
  if [[ "$CLI_RPORT" == "1" ]]; then
    # 单条命令行隧道模式：把最终值全部透传，子进程不依赖任何隧道段。
    # -f 仍需带上（VPS 全局信息在里面），但 -r 必须同传，
    # 否则子进程会退回读配置里的隧道段，端口和父进程不一致。
    dargs+=(-s "$VPS_HOST" -k "$KEY_FILE" -r "$REMOTE_PORT" \
            -H "$LOCAL_HOST" -p "$LOCAL_PORT")
    [[ -n "$CONFIG_FILE" ]] && dargs+=(-f "$CONFIG_FILE")
  elif [[ -n "$CONFIG_FILE" ]]; then
    # 段式/旧扁平配置：子进程按 -t 重读该段。
    dargs+=(-f "$CONFIG_FILE")
    [[ "$CLI_HOST" == "1" ]] && dargs+=(-s "$VPS_HOST")
    [[ "$CLI_KEY"  == "1" ]] && dargs+=(-k "$KEY_FILE")
    # 旧扁平格式（无 [tunnel:] 段）下 -H/-p 覆盖同样要透传，
    # 否则守护进程会按配置文件里的旧 local_port 建隧道。
    if (( ${#T_NAMES[@]} == 0 )); then
      [[ "$CLI_LHOST" == "1" ]] && dargs+=(-H "$LOCAL_HOST")
      [[ "$CLI_LPORT" == "1" ]] && dargs+=(-p "$LOCAL_PORT")
    fi
  else
    # 兜底：无配置文件且无 -r（正常会在 build_tunnels 被拦下）
    dargs+=(-s "$VPS_HOST" -k "$KEY_FILE" -r "$REMOTE_PORT" \
            -H "$LOCAL_HOST" -p "$LOCAL_PORT")
  fi
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$SELF" "${dargs[@]}" >>"$LOG_FILE" 2>&1 &
  else
    nohup "$SELF" "${dargs[@]}" >>"$LOG_FILE" 2>&1 &
  fi
  disown 2>/dev/null || true
  return 0
}

do_start_all() {
  local j idx ok=0 fail=0 t remain
  local -a NEW_IDX=()

  out "配置文件: ${CONFIG_FILE:-（无，命令行模式）}"
  out "VPS     : ${VPS_USER}@${VPS_HOST}:${VPS_PORT}  私钥=${KEY_FILE}"
  out "本次启动 ${#SELECTED[@]} 条隧道"

  # 阶段 1：全部并发 fork
  for ((j=0; j<${#SELECTED[@]}; j++)); do
    idx="${SELECTED[$j]}"
    apply_tunnel "$idx"
    if daemon_pid >/dev/null 2>&1; then
      out "  [${CUR_NAME}] VPS:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}  已在运行，跳过"
      continue
    fi
    fork_daemon
    NEW_IDX+=("$idx")
    out "  [${CUR_NAME}] VPS:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}  已投递启动"
  done

  (( ${#NEW_IDX[@]} == 0 )) && { out "全部隧道已在运行，无需启动"; return 0; }

  # 阶段 2：统一等待所有守护进程出现（不是一条一条串行等）
  for ((t=0; t<START_TIMEOUT; t++)); do
    remain=0
    for ((j=0; j<${#NEW_IDX[@]}; j++)); do
      apply_tunnel "${NEW_IDX[$j]}"
      daemon_pid >/dev/null 2>&1 || remain=$((remain + 1))
    done
    (( remain == 0 )) && break
    sleep 1
  done

  # 阶段 3：统一等待隧道建立
  for ((t=0; t<START_TIMEOUT; t++)); do
    remain=0
    for ((j=0; j<${#NEW_IDX[@]}; j++)); do
      apply_tunnel "${NEW_IDX[$j]}"
      is_up || remain=$((remain + 1))
    done
    (( remain == 0 )) && break
    sleep 1
  done

  # 阶段 4：逐条报告
  out "---- 启动结果 ----"
  for ((j=0; j<${#NEW_IDX[@]}; j++)); do
    apply_tunnel "${NEW_IDX[$j]}"
    if daemon_pid >/dev/null 2>&1 && is_up; then
      out "  [OK]   ${CUR_NAME}  VPS:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}"
      ok=$((ok + 1))
    else
      out "  [FAIL] ${CUR_NAME}  VPS:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}  详见 ${LOG_FILE}"
      fail=$((fail + 1))
    fi
  done
  out "汇总: 成功 ${ok} 条，失败 ${fail} 条"
  (( fail == 0 ))
}

# ---------------- 子命令：停止 ----------------
do_stop_all() {
  local j idx pid ok=0 t remain
  local -a STOP_IDX=() STOP_PID=()

  out "本次停止 ${#SELECTED[@]} 条隧道"

  # 阶段 1：先给所有守护进程发 TERM，让它们并行收尾
  for ((j=0; j<${#SELECTED[@]}; j++)); do
    idx="${SELECTED[$j]}"
    apply_tunnel "$idx"
    if pid="$(daemon_pid)"; then
      kill -TERM "$pid" 2>/dev/null
      STOP_IDX+=("$idx"); STOP_PID+=("$pid")
      out "  [${CUR_NAME}] 已通知退出 PID=${pid}"
    else
      rm -f "$PIDFILE"
      if is_up; then
        log "发现残留隧道，尝试关闭"
        tunnel_stop
      fi
      out "  [${CUR_NAME}] 未在运行"
      ok=$((ok + 1))
    fi
  done

  # 阶段 2：统一等待退出
  for ((t=0; t<30; t++)); do
    remain=0
    for ((j=0; j<${#STOP_PID[@]}; j++)); do
      kill -0 "${STOP_PID[$j]}" 2>/dev/null && remain=$((remain + 1))
    done
    (( remain == 0 )) && break
    sleep 1
  done

  # 阶段 3：没退出的强杀，并清理隧道
  for ((j=0; j<${#STOP_IDX[@]}; j++)); do
    apply_tunnel "${STOP_IDX[$j]}"
    pid="${STOP_PID[$j]}"
    if kill -0 "$pid" 2>/dev/null; then
      out "  [${CUR_NAME}] 守护进程未响应，SIGKILL"
      kill -9 "$pid" 2>/dev/null
      is_up && tunnel_stop
    fi
    rm -f "$PIDFILE"
    out "  [OK]   ${CUR_NAME} 已停止"
    ok=$((ok + 1))
  done
  out "汇总: 已处理 ${ok} 条"
  return 0
}

do_restart_all() {
  do_stop_all
  sleep 1
  do_start_all
}

# ---------------- 子命令：状态 / 列表 ----------------
do_status_all() {
  local j idx dstate tstate lstate
  out "脚本版本: ${SCRIPT_VER}"
  out "配置文件: ${CONFIG_FILE:-（无，命令行模式）}"
  out "VPS     : ${VPS_USER}@${VPS_HOST}:${VPS_PORT}  私钥=${KEY_FILE}"
  printf '%-14s %-30s %-14s %-10s %s\n' "隧道" "映射" "守护进程" "隧道" "对端监听"
  for ((j=0; j<${#SELECTED[@]}; j++)); do
    idx="${SELECTED[$j]}"
    apply_tunnel "$idx"
    if dstate="$(daemon_pid)"; then dstate="PID ${dstate}"; else dstate="未运行"; fi
    if is_up; then
      tstate="运行中"
      if remote_listening; then lstate="是"; else lstate="否（检查 GatewayPorts）"; fi
    else
      tstate="未运行"; lstate="-"
    fi
    printf '%-14s %-30s %-14s %-10s %s\n' \
      "$CUR_NAME" "VPS:${REMOTE_PORT} -> ${LOCAL_HOST}:${LOCAL_PORT}" \
      "$dstate" "$tstate" "$lstate"
  done
  out "提示: 每条隧道的对端探测最多 10 秒，隧道多时 status 会相应变慢；快速查看用 list"
  return 0
}

do_list() {
  local i nm dpid
  out "配置文件: ${CONFIG_FILE:-（无，命令行模式）}"
  out "VPS     : ${VPS_USER}@${VPS_HOST}:${VPS_PORT}"
  out "共 ${#TUN_NAMES[@]} 条隧道:"
  printf '%-14s %-10s %-30s %-10s %s\n' "名字" "VPS端口" "映射" "启用" "状态"
  LOG_TAG=""
  for ((i=0; i<${#TUN_NAMES[@]}; i++)); do
    nm="${TUN_NAMES[$i]}"
    # 只设 runtime 路径，不做端口校验，保证损坏的配置也能列出来
    REMOTE_PORT="${TUN_RPORT[$i]}"
    SOCK="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.sock"
    PIDFILE="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.pid"
    LOG_FILE="/tmp/ssh-tunnel-lite-${REMOTE_PORT}.log"
    dpid="未运行"
    if daemon_pid >/dev/null 2>&1; then dpid="PID $(daemon_pid)"; fi
    is_disabled "${TUN_ENABLED[$i]}" && dpid="未启用"
    printf '%-14s %-10s %-30s %-10s %s\n' \
      "$nm" "$REMOTE_PORT" "VPS:${REMOTE_PORT} -> ${TUN_LHOST[$i]}:${TUN_LPORT[$i]}" \
      "$(is_disabled "${TUN_ENABLED[$i]}" && echo 0 || echo 1)" "$dpid"
  done
  out ""
  if [[ -n "$CONFIG_FILE" ]]; then
    out "启动全部: ${SELF##*/} start -f ${CONFIG_FILE}"
    out "启动部分: ${SELF##*/} start -f ${CONFIG_FILE} <名字> [<名字>...]"
  else
    out "当前为命令行模式，无需 -f；映射由 -r/-H/-p 指定"
  fi
  return 0
}

# ---------------- 诊断 ----------------
do_dump() {
  local i k v hex nm
  printf '脚本版本  : %s\n' "$SCRIPT_VER"
  printf '配置文件  : %s\n' "${CONFIG_FILE:-（未用 -f 指定）}"
  printf '解析优先级: 命令行 > 配置文件 > 脚本顶部常量\n\n'

  printf '[全局段]\n'
  for ((i=0; i<${#G_KEYS[@]}; i++)); do
    k="${G_KEYS[$i]}"; v="${G_VALS[$i]}"
    hex=$(printf '%s' "$v" | od -An -tx1 -v | tr -s ' ' | tr -d '\n' | sed 's/^ //')
    printf '  %-22s [%s]  %s\n' "$k" "$v" "$hex"
  done
  (( ${#G_KEYS[@]} == 0 )) && printf '  (空)\n'

  printf '\n[隧道段] 共 %s 个\n' "${#T_NAMES[@]}"
  for ((i=0; i<${#T_NAMES[@]}; i++)); do
    nm="${T_NAMES[$i]}"
    printf '  [%s]\n' "$nm"
    local j
    for ((j=0; j<${#T_KEYS[@]}; j++)); do
      [[ "${T_KEYS[$j]}" == "${nm}."* ]] || continue
      k="${T_KEYS[$j]#${nm}.}"; v="${T_VALS[$j]}"
      hex=$(printf '%s' "$v" | od -An -tx1 -v | tr -s ' ' | tr -d '\n' | sed 's/^ //')
      printf '    %-20s [%s]  %s\n' "$k" "$v" "$hex"
    done
  done

  printf '\n[合并后的隧道清单]\n'
  for ((i=0; i<${#TUN_NAMES[@]}; i++)); do
    printf '  %-14s VPS:%s -> %s:%s  bind=%s enabled=%s log=%s\n' \
      "${TUN_NAMES[$i]}" "${TUN_RPORT[$i]}" \
      "${TUN_LHOST[$i]}" "${TUN_LPORT[$i]}" "${TUN_BIND[$i]}" \
      "${TUN_ENABLED[$i]}" "${TUN_LOG[$i]:-（按端口默认）}"
  done

  printf '\n[当前生效的全局值]\n'
  printf '  vps_host=%s vps_port=%s vps_user=%s ssh_key=%s\n' \
    "${VPS_HOST:-<空>}" "$VPS_PORT" "$VPS_USER" "${KEY_FILE:-<空>}"
  printf '  check_interval=%s health_check=%s health_interval=%s\n' \
    "$CHECK_INTERVAL" "$HEALTH_CHECK" "$HEALTH_INTERVAL"

  if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    printf '\n文件里所有含 port 的行（^M 表示 CR）:\n'
    grep -n -i 'port' "$CONFIG_FILE" 2>/dev/null | cat -A
  fi
  return 0
}

do_selfinfo() {
  printf '脚本版本  : %s\n' "$SCRIPT_VER"
  printf '脚本路径  : %s\n' "$SELF"
  printf '脚本校验  : %s\n' "$(cksum "$SELF" 2>/dev/null || echo 'cksum 不可用')"
  printf 'bash 版本 : %s\n' "$BASH_VERSION"
  printf 'locale    : %s\n' "${LC_ALL:-${LANG:-unset}}"
  printf '多隧道支持: %s\n' "$(grep -q 'build_tunnels' "$SELF" 2>/dev/null && echo '是' || echo '否（旧版，请替换脚本）')"
}

# ---------------- main ----------------
parse_args "$@"

case "$ACTION" in
  selfinfo|about) do_selfinfo; exit 0 ;;
esac

load_conf
apply_globals
# 诊断动作允许配置里没有隧道，否则配置写坏时连 dump 都打不开
case "$ACTION" in dump|list) ALLOW_EMPTY=1 ;; esac
build_tunnels

case "$ACTION" in
  dump) do_dump; exit 0 ;;
  list) do_list; exit 0 ;;
esac

validate_globals
build_ssh_cmd
select_tunnels

case "$ACTION" in
  start)   do_start_all ;;
  stop)    do_stop_all ;;
  restart) do_restart_all ;;
  status)  do_status_all ;;
  daemon|_daemon)
    if (( ${#SELECTED[@]} != 1 )); then
      out "提示: daemon 一次只跑一条隧道，已取第一条（建议用 -t 明确指定）"
    fi
    apply_tunnel "${SELECTED[0]}"
    daemon_loop ;;
esac
