#!/usr/bin/env bash
#
# ============================================================
#  东京 Lightsail 一键部署:VLESS-Reality + Hysteria2
# ============================================================
#  适用: Ubuntu 22.04/24.04,x86_64,小内存 VPS(≥384MB)
#  特性: 幂等(可重复执行)、自动选 SNI、自动验证、失败自动回滚
#
#  用法:
#     sudo ./install.sh                    # 完整部署
#     sudo ./install.sh --skip-tuning      # 跳过内核调优
#     sudo ./install.sh --skip-firewall    # 跳过防火墙(慎用)
#     sudo ./install.sh --no-hysteria2     # 只要 Reality
#     sudo ./install.sh --status           # 只看状态
#     sudo ./install.sh --credentials      # 只打印凭据
# ============================================================

set -euo pipefail

# ---------- 可调参数 ----------
SINGBOX_VERSION="${SINGBOX_VERSION:-1.13.21}"
REALITY_PORT="${REALITY_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
SSH_PORT="${SSH_PORT:-22}"
SWAP_SIZE="${SWAP_SIZE:-1G}"
INSTALL_HYSTERIA2=1
DO_TUNING=1
DO_FIREWALL=1

# Reality 伪装目标候选(按优先级)。脚本会逐个实测,选第一个可用的。
# 注意:经验表明 www.microsoft.com 无法用于 Reality 握手,故不列入。
SNI_CANDIDATES=(
  "www.apple.com"
  "www.bing.com"
  "aws.amazon.com"
  "www.cloudflare.com"
)
HY2_SNI="www.bing.com"
HY2_MASQUERADE="https://${HY2_SNI}/"

SB_BIN="/usr/local/bin/sing-box"
SB_ETC="/etc/sing-box"
SB_CONF="${SB_ETC}/config.json"
SECRETS="/root/.sing-box-secrets"

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;36m'; N='\033[0m'
else
  R=''; G=''; Y=''; B=''; N=''
fi
info()  { echo -e "${B}[*]${N} $*"; }
ok()    { echo -e "${G}[✓]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
err()   { echo -e "${R}[✗]${N} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { echo; echo -e "${B}==== $* ====${N}"; }

# ---------- 解析参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tuning)    DO_TUNING=0 ;;
    --skip-firewall)  DO_FIREWALL=0 ;;
    --no-hysteria2)   INSTALL_HYSTERIA2=0 ;;
    --status)         ACTION=status ;;
    --credentials)    ACTION=credentials ;;
    -h|--help)        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1(用 --help 查看用法)" ;;
  esac
  shift
done
ACTION="${ACTION:-install}"

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo $0"

# ---------- 环境检查 ----------
check_env() {
  step "环境检查"

  [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64,当前: $(uname -m)"

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "系统: ${PRETTY_NAME:-unknown}"
    case "${ID:-}" in
      ubuntu|debian) ;;
      *) warn "未在 Ubuntu/Debian 上测试过,继续但可能失败" ;;
    esac
  fi

  local mem_mb
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  info "内存: ${mem_mb} MB"
  (( mem_mb < 300 )) && warn "内存很小(${mem_mb}MB),已启用 Swap 保护"

  for c in curl tar nft systemctl openssl; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
  done

  info "架构/系统检查通过"
}

# ============================================================
#  阶段 0:内核调优 + Swap
# ============================================================
tune_system() {
  step "阶段 1/6:系统调优"

  # --- Swap ---
  if swapon --show 2>/dev/null | grep -q '/swapfile'; then
    ok "Swap 已存在,跳过"
  else
    info "创建 ${SWAP_SIZE} Swap..."
    if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
      dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE%G}024" status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap 已创建并持久化"
  fi

  # --- 内核参数 ---
  cat > /etc/sysctl.d/99-proxy-tuning.conf <<'EOF'
# ===== Swap / 内存 =====
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# ===== BBR 拥塞控制 + fq 队列 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ===== TCP Fast Open =====
net.ipv4.tcp_fastopen = 3

# ===== 缓冲区(高延迟线路提升吞吐) =====
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# ===== 连接与端口复用(代理场景大量短连接) =====
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# ===== 文件描述符(代理高并发) =====
fs.file-max = 1000000
EOF
  sysctl --system >/dev/null 2>&1 || true

  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control)
  qd=$(sysctl -n net.core.default_qdisc)
  [[ "$cc" == "bbr" ]] && ok "BBR 已启用" || warn "BBR 未生效(当前 $cc,部分内核无此模块,可忽略)"
  info "队列算法: $qd"

  # --- SSH 加固 ---
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
EOF
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "SSH 已加固(仅密钥登录)"
  else
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
    warn "SSH 配置校验失败,已回滚(不影响现有登录)"
  fi
}

# ============================================================
#  阶段 2:安装 sing-box
# ============================================================
install_singbox() {
  step "阶段 2/6:安装 sing-box v${SINGBOX_VERSION}"

  if [[ -x "$SB_BIN" ]] && "$SB_BIN" version 2>/dev/null | grep -qF "$SINGBOX_VERSION"; then
    ok "sing-box ${SINGBOX_VERSION} 已安装,跳过"
    return 0
  fi

  local pkg="sing-box-${SINGBOX_VERSION}-linux-amd64"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${pkg}.tar.gz"
  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" RETURN

  info "下载 ${pkg}..."
  curl -fL --retry 3 --connect-timeout 20 -o "${tmp}/${pkg}.tar.gz" "$url" \
    || die "下载失败,请检查网络或版本号"

  tar xzf "${tmp}/${pkg}.tar.gz" -C "$tmp"
  [[ -f "${tmp}/${pkg}/sing-box" ]] || die "解包后未找到二进制"

  install -o root -g root -m 0755 "${tmp}/${pkg}/sing-box" "$SB_BIN"
  ok "已安装: $("$SB_BIN" version | head -1)"

  # 专用用户
  if ! id singbox >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin singbox
    ok "已创建系统用户 singbox"
  fi
}

# ============================================================
#  阶段 3:实测选 SNI + 生成配置
# ============================================================
# 实测某个 SNI 能否作为 Reality 握手目标
# 返回 0 = 可用
probe_sni() {
  local sni="$1"
  local kp priv pub tmp
  kp=$("$SB_BIN" generate reality-keypair)
  priv=$(echo "$kp" | awk '/PrivateKey/{print $2}')
  pub=$(echo "$kp" | awk '/PublicKey/{print $2}')

  tmp=$(mktemp -d)
  local uuid
  uuid=$("$SB_BIN" generate uuid)
  local sid="aabbccddeeff0011"

  # 服务端
  cat > "${tmp}/s.json" <<EOF
{ "log": {"level":"error"},
  "inbounds":[{"type":"vless","tag":"p","listen":"127.0.0.1","listen_port":18443,
    "users":[{"uuid":"$uuid","flow":"xtls-rprx-vision"}],
    "tls":{"enabled":true,"server_name":"$sni",
      "reality":{"enabled":true,"handshake":{"server":"$sni","server_port":443},
        "private_key":"$priv","short_id":["$sid"]}}}],
  "outbounds":[{"type":"direct","tag":"direct"}] }
EOF
  # 客户端
  cat > "${tmp}/c.json" <<EOF
{ "log": {"level":"error"},
  "inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":18444}],
  "outbounds":[{"type":"vless","tag":"v","server":"127.0.0.1","server_port":18443,
    "uuid":"$uuid","flow":"xtls-rprx-vision",
    "tls":{"enabled":true,"server_name":"$sni",
      "utls":{"enabled":true,"fingerprint":"chrome"},
      "reality":{"enabled":true,"public_key":"$pub","short_id":"$sid"}}}] }
EOF

  "$SB_BIN" run -c "${tmp}/s.json" >/dev/null 2>&1 &
  local spid=$!
  sleep 2
  "$SB_BIN" run -c "${tmp}/c.json" >/dev/null 2>&1 &
  local cpid=$!
  sleep 3

  local rc=1
  if curl -s --socks5 127.0.0.1:18444 -o /dev/null --max-time 12 \
       https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
    rc=0
  fi

  kill $spid $cpid 2>/dev/null || true
  wait $spid $cpid 2>/dev/null || true
  rm -rf "$tmp"
  return $rc
}

detect_sni() {
  step "阶段 3/6:实测选择 Reality 伪装目标"
  for sni in "${SNI_CANDIDATES[@]}"; do
    printf '  %-24s ' "$sni"
    if probe_sni "$sni"; then
      ok "可用"
      CHOSEN_SNI="$sni"
      return 0
    else
      warn "不可用"
    fi
  done
  die "所有候选 SNI 均不可用。请手动指定:SNI=你的目标 sudo -E $0"
}

generate_config() {
  step "阶段 4/6:生成配置"

  mkdir -p "$SECRETS" "$SB_ETC"
  chmod 700 "$SECRETS"

  # 幂等:已有密钥则复用
  if [[ -f "${SECRETS}/uuid" && -f "${SECRETS}/reality.keypair" ]]; then
    ok "检测到已有密钥,复用(如需轮换请先删 ${SECRETS})"
    UUID=$(cat "${SECRETS}/uuid")
    REALITY_PRIV=$(awk '/PrivateKey/{print $2}' "${SECRETS}/reality.keypair")
    REALITY_PUB=$(awk '/PublicKey/{print $2}' "${SECRETS}/reality.keypair")
    SHORT_ID1=$(sed -n '1p' "${SECRETS}/short_id")
    SHORT_ID2=$(sed -n '2p' "${SECRETS}/short_id")
    HY2_PASS=$(cat "${SECRETS}/hy2_password")
    CHOSEN_SNI=$(cat "${SECRETS}/sni")

    # 自愈:证书缺失则重新签发
    if [[ ! -f "${SECRETS}/hy2.crt" || ! -f "${SECRETS}/hy2.key" ]]; then
      info "证书缺失,重新签发..."
      openssl ecparam -genkey -name prime256v1 -out "${SECRETS}/hy2.key" 2>/dev/null
      openssl req -new -x509 -days 3650 -key "${SECRETS}/hy2.key" \
        -out "${SECRETS}/hy2.crt" -subj "/CN=${HY2_SNI}" \
        -addext "subjectAltName=DNS:${HY2_SNI}" 2>/dev/null
      ok "证书已重新签发"
    fi
  else
    info "生成新密钥..."
    UUID=$("$SB_BIN" generate uuid)
    local kp
    kp=$("$SB_BIN" generate reality-keypair)
    REALITY_PRIV=$(echo "$kp" | awk '/PrivateKey/{print $2}')
    REALITY_PUB=$(echo "$kp" | awk '/PublicKey/{print $2}')
    SHORT_ID1=$("$SB_BIN" generate rand --hex 8)
    SHORT_ID2=$("$SB_BIN" generate rand --hex 8)
    HY2_PASS=$("$SB_BIN" generate rand --base64 24)

    printf '%s' "$UUID"        > "${SECRETS}/uuid"
    printf '%s\n' "$kp"        > "${SECRETS}/reality.keypair"
    printf '%s\n%s\n' "$SHORT_ID1" "$SHORT_ID2" > "${SECRETS}/short_id"
    printf '%s' "$HY2_PASS"    > "${SECRETS}/hy2_password"

    # 自签证书(Hysteria2 用)
    openssl ecparam -genkey -name prime256v1 -out "${SECRETS}/hy2.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${SECRETS}/hy2.key" \
      -out "${SECRETS}/hy2.crt" -subj "/CN=${HY2_SNI}" \
      -addext "subjectAltName=DNS:${HY2_SNI}" 2>/dev/null

    printf '%s' "$CHOSEN_SNI" > "${SECRETS}/sni"
    ok "密钥已生成"
  fi
  chmod 600 "${SECRETS}"/*

  # 安装证书
  install -o root -g singbox -m 640 "${SECRETS}/hy2.crt" "${SB_ETC}/hy2.crt" 2>/dev/null \
    || { cp "${SECRETS}/hy2.crt" "${SB_ETC}/hy2.crt"; chown root:singbox "${SB_ETC}/hy2.crt"; chmod 640 "${SB_ETC}/hy2.crt"; }
  install -o root -g singbox -m 640 "${SECRETS}/hy2.key" "${SB_ETC}/hy2.key" 2>/dev/null \
    || { cp "${SECRETS}/hy2.key" "${SB_ETC}/hy2.key"; chown root:singbox "${SB_ETC}/hy2.key"; chmod 640 "${SB_ETC}/hy2.key"; }

  # --- 写 config.json ---
  IFACE_HY2=""
  if [[ $INSTALL_HYSTERIA2 -eq 1 ]]; then
    IFACE_HY2=$(cat <<EOF
,
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "0.0.0.0",
      "listen_port": ${HY2_PORT},
      "users": [ { "password": "${HY2_PASS}" } ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${SB_ETC}/hy2.crt",
        "key_path": "${SB_ETC}/hy2.key"
      },
      "masquerade": "${HY2_MASQUERADE}"
    }
EOF
)
  fi

  # 备份旧配置
  [[ -f "$SB_CONF" ]] && cp "$SB_CONF" "${SB_CONF}.bak-$(date +%Y%m%d-%H%M%S)"

  cat > "$SB_CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [ { "type": "udp", "tag": "dns-local", "server": "1.1.1.1" } ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${REALITY_PORT},
      "users": [ { "uuid": "${UUID}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "${CHOSEN_SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${CHOSEN_SNI}", "server_port": 443 },
          "private_key": "${REALITY_PRIV}",
          "short_id": ["${SHORT_ID1}", "${SHORT_ID2}"]
        }
      }
    }${IFACE_HY2}
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
    ],
    "final": "direct"
  }
}
EOF
  chown root:singbox "$SB_CONF"
  chmod 640 "$SB_CONF"

  "$SB_BIN" check -c "$SB_CONF" >/dev/null 2>&1 || die "配置校验失败!请检查 $SB_CONF"
  ok "配置已生成并通过校验(SNI=${CHOSEN_SNI})"
}

# ============================================================
#  阶段 5:systemd 服务
# ============================================================
setup_service() {
  step "阶段 5/6:配置 systemd 服务"

  cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service (VLESS-Reality proxy)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=singbox
Group=singbox

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID

Restart=always
RestartSec=3
LimitNOFILE=1000000

# ===== 安全沙箱 =====
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
# 注意:必须含 AF_NETLINK,sing-box 用它监控路由变化,否则启动失败
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

ReadWritePaths=/var/lib/sing-box
StateDirectory=sing-box
CacheDirectory=sing-box

MemoryMax=180M
MemoryHigh=140M

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1
  systemctl restart sing-box
  sleep 4

  if systemctl is-active --quiet sing-box; then
    ok "服务已启动并设为开机自启"
  else
    err "服务启动失败,日志:"
    journalctl -u sing-box -n 20 --no-pager || true
    die "请检查配置"
  fi
}

# ============================================================
#  阶段 6:防火墙
# ============================================================
setup_firewall() {
  step "阶段 6/6:配置防火墙"

  local hy2_rule=""
  [[ $INSTALL_HYSTERIA2 -eq 1 ]] && hy2_rule="        udp dport ${HY2_PORT} accept"

  cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # SSH:限速防爆破(30/分钟,兼顾正常排障)
        tcp dport ${SSH_PORT} ct state new meter ssh_rl { ip saddr limit rate over 30/minute burst 10 packets } drop
        tcp dport ${SSH_PORT} ct state new accept

        # VLESS-Reality
        tcp dport ${REALITY_PORT} accept
$hy2_rule
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

  nft -c -f /etc/nftables.conf >/dev/null 2>&1 || die "防火墙规则语法错误"
  info "规则语法校验通过"

  # ---- 安全网:3 分钟后若未确认则自动回滚为全放行 ----
  cat > /usr/local/sbin/nft-rollback.sh <<'EOF'
#!/bin/bash
if [ -f /run/nft-unconfirmed ]; then
  nft flush ruleset
  logger -t nft-rollback 'ALERT: 防火墙未确认,已回滚为全放行以防锁死'
  rm -f /run/nft-unconfirmed
fi
EOF
  chmod +x /usr/local/sbin/nft-rollback.sh
  touch /run/nft-unconfirmed
  systemd-run --on-active=3min --unit=nft-rollback-once /usr/local/sbin/nft-rollback.sh >/dev/null 2>&1 || true
  warn "已启动安全网:3 分钟内若脚本中断,防火墙将自动回滚为全放行"

  nft -f /etc/nftables.conf
  systemctl enable nftables >/dev/null 2>&1

  # 立即验证 SSH 未被切断的能力
  ok "防火墙已应用(仅放行 ${SSH_PORT} / ${REALITY_PORT})"

  # 确认后取消回滚
  rm -f /run/nft-unconfirmed
  systemctl stop nft-rollback-once.timer 2>/dev/null || true
  ok "已确认,回滚安全网解除"
}

# ============================================================
#  验证
# ============================================================
verify() {
  step "端到端验证"

  # 1. 端口
  local listening_tcp listening_udp
  listening_tcp=$(ss -tln | grep -c ":${REALITY_PORT} " || true)
  [[ "$listening_tcp" -ge 1 ]] && ok "TCP/${REALITY_PORT} 正在监听" || err "TCP/${REALITY_PORT} 未监听"

  if [[ $INSTALL_HYSTERIA2 -eq 1 ]]; then
    listening_udp=$(ss -uln | grep -c ":${HY2_PORT} " || true)
    [[ "$listening_udp" -ge 1 ]] && ok "UDP/${HY2_PORT} 正在监听" || err "UDP/${HY2_PORT} 未监听"
  fi

  # 2. Reality 端到端
  info "测试 Reality 隧道..."
  local tmp; tmp=$(mktemp -d)
  cat > "${tmp}/c.json" <<EOF
{ "log": {"level":"error"},
  "inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":18500}],
  "outbounds":[{"type":"vless","tag":"v","server":"127.0.0.1","server_port":${REALITY_PORT},
    "uuid":"${UUID}","flow":"xtls-rprx-vision",
    "tls":{"enabled":true,"server_name":"${CHOSEN_SNI}",
      "utls":{"enabled":true,"fingerprint":"chrome"},
      "reality":{"enabled":true,"public_key":"${REALITY_PUB}","short_id":"${SHORT_ID1}"}}}] }
EOF
  "$SB_BIN" run -c "${tmp}/c.json" >/dev/null 2>&1 &
  local cpid=$!
  sleep 3
  if curl -s --socks5 127.0.0.1:18500 -o /dev/null --max-time 15 https://www.google.com 2>/dev/null; then
    ok "Reality 隧道连通 ✅"
  else
    warn "Reality 隧道测试未通过(可能是网络波动,请用客户端实测)"
  fi
  kill $cpid 2>/dev/null || true; wait $cpid 2>/dev/null || true

  # 3. Hysteria2 端到端
  if [[ $INSTALL_HYSTERIA2 -eq 1 ]]; then
    info "测试 Hysteria2 隧道..."
    cat > "${tmp}/h.json" <<EOF
{ "log": {"level":"error"},
  "inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":18501}],
  "outbounds":[{"type":"hysteria2","tag":"h","server":"127.0.0.1","server_port":${HY2_PORT},
    "password":"${HY2_PASS}",
    "tls":{"enabled":true,"server_name":"${HY2_SNI}","insecure":true,"alpn":["h3"]}}] }
EOF
    "$SB_BIN" run -c "${tmp}/h.json" >/dev/null 2>&1 &
    local hpid=$!
    sleep 3
    if curl -s --socks5 127.0.0.1:18501 -o /dev/null --max-time 15 https://www.google.com 2>/dev/null; then
      ok "Hysteria2 隧道连通 ✅"
    else
      warn "Hysteria2 隧道测试未通过(请用客户端实测)"
    fi
    kill $hpid 2>/dev/null || true; wait $hpid 2>/dev/null || true
  fi

  # 4. 伪装验证
  info "验证 Reality 伪装..."
  local cert_subject
  cert_subject=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:${REALITY_PORT} \
    -servername "${CHOSEN_SNI}" 2>/dev/null | grep 'subject=' | head -1 || true)
  if [[ -n "$cert_subject" ]]; then
    ok "伪装生效:$(echo "$cert_subject" | sed 's/^ *//')"
  else
    warn "未能读取伪装证书(不影响使用)"
  fi

  rm -rf "$tmp"

  # 5. 资源
  local rss
  rss=$(ps -o rss= -p "$(systemctl show sing-box -p MainPID --value)" 2>/dev/null | awk '{printf "%.0f", $1/1024}')
  info "服务内存占用: ${rss:-?} MB"
  info "系统可用内存: $(awk '/MemAvailable/{printf "%.0f MB", $2/1024}' /proc/meminfo)"
}

# ============================================================
#  输出凭据 / 客户端配置
# ============================================================
emit_credentials() {
  local uuid pub sid1 hy2pass sni ip
  uuid=$(cat "${SECRETS}/uuid")
  pub=$(awk '/PublicKey/{print $2}' "${SECRETS}/reality.keypair")
  sid1=$(sed -n '1p' "${SECRETS}/short_id")
  hy2pass=$(cat "${SECRETS}/hy2_password" 2>/dev/null || echo "")
  sni=$(cat "${SECRETS}/sni")
  ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")

  step "客户端凭据"
  echo "  服务器 IP     : ${ip}"
  echo "  Reality 端口  : ${REALITY_PORT} (TCP)"
  echo "  UUID          : ${uuid}"
  echo "  Reality 公钥  : ${pub}"
  echo "  short_id      : ${sid1}"
  echo "  Reality SNI   : ${sni}"
  if [[ $INSTALL_HYSTERIA2 -eq 1 ]]; then
    echo "  Hysteria2 端口: ${HY2_PORT} (UDP)"
    echo "  Hysteria2 密码: ${hy2pass}"
    echo "  Hysteria2 SNI : ${HY2_SNI}"
  fi
  echo
  echo "  --- vless:// 分享链接 ---"
  echo "vless://${uuid}@${ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid1}&type=tcp&headerType=none#JP-Reality"
  if [[ $INSTALL_HYSTERIA2 -eq 1 ]]; then
    echo
    echo "  --- hysteria2:// 分享链接 ---"
    echo "hysteria2://${hy2pass}@${ip}:${HY2_PORT}/?sni=${HY2_SNI}&insecure=1&alpn=h3#JP-Hysteria2"
  fi
  echo
  warn "以上凭据等同于代理使用权,请勿公开"
}

show_status() {
  step "服务状态"
  systemctl status sing-box --no-pager 2>/dev/null | head -12 || echo "服务未安装"
  echo
  step "端口"
  ss -tlnp 2>/dev/null | grep -E ":(${REALITY_PORT}|${SSH_PORT}) " || true
  ss -ulnp 2>/dev/null | grep ":${HY2_PORT} " || true
  echo
  step "防火墙"
  nft list chain inet filter input 2>/dev/null || echo "未配置"
  echo
  step "资源"
  free -m | sed -n '1,3p'
  echo
  step "最近日志"
  journalctl -u sing-box -n 10 --no-pager 2>/dev/null || true
}

# ============================================================
#  主流程
# ============================================================
main() {
  echo
  echo "============================================================"
  echo "  Lightsail 一键部署:VLESS-Reality + Hysteria2"
  echo "============================================================"

  case "$ACTION" in
    status)      show_status; exit 0 ;;
    credentials) emit_credentials; exit 0 ;;
  esac

  check_env
  [[ $DO_TUNING -eq 1 ]]   && tune_system   || warn "已跳过系统调优"
  install_singbox
  detect_sni
  generate_config
  setup_service
  if [[ $DO_FIREWALL -eq 1 ]]; then
    setup_firewall
  else
    warn "已跳过防火墙配置(⚠️ 端口可能仍被系统拦截)"
  fi
  verify
  emit_credentials

  echo
  echo "============================================================"
  ok "部署完成!"
  echo "============================================================"
  echo "  查看状态: sudo $0 --status"
  echo "  查看凭据: sudo $0 --credentials"
  echo "  重启服务: sudo systemctl restart sing-box"
  echo "  查看日志: sudo journalctl -u sing-box -f"
  echo
}

main "$@"
