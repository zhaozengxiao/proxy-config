#!/usr/bin/env bash
#
# ============================================================
#  卸载脚本:回滚 install.sh 的所有改动
# ============================================================
#  用法:
#     sudo ./uninstall.sh              # 卸载服务与配置,保留密钥与防火墙
#     sudo ./uninstall.sh --all        # 全部清除(含密钥、防火墙、调优)
#     sudo ./uninstall.sh --keep-swap  # 保留 Swap
# ============================================================

set -euo pipefail

SB_BIN="/usr/local/bin/sing-box"
SB_ETC="/etc/sing-box"
SECRETS="/root/.sing-box-secrets"
PURGE=0
KEEP_SWAP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)       PURGE=1 ;;
    --keep-swap) KEEP_SWAP=1 ;;
    -h|--help)   sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "请用 root 运行: sudo $0" >&2; exit 1; }

echo
echo "========== 卸载 sing-box 代理 =========="

# --- 1. 停服务 ---
if systemctl list-unit-files 2>/dev/null | grep -q '^sing-box.service'; then
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload
  echo "[✓] 服务已停止并移除"
fi

# --- 2. 清理残留进程 ---
MP=$(pgrep -f "${SB_BIN} run" 2>/dev/null || true)
[[ -n "$MP" ]] && { for P in $MP; do kill "$P" 2>/dev/null || true; done; echo "[✓] 已清理残留进程"; }

# --- 3. 移除二进制 ---
[[ -f "$SB_BIN" ]] && { rm -f "$SB_BIN"; echo "[✓] 二进制已删除"; }

# --- 4. 配置 ---
if [[ $PURGE -eq 1 ]]; then
  rm -rf "$SB_ETC"
  rm -rf /var/lib/sing-box
  rm -rf "$SECRETS"
  id singbox >/dev/null 2>&1 && userdel singbox 2>/dev/null || true
  echo "[✓] 配置、密钥、用户已全部清除"
else
  rm -f "${SB_ETC}/hy2.crt" "${SB_ETC}/hy2.key"
  echo "[!] 已保留:${SB_ETC} (配置)、${SECRETS} (密钥)"
  echo "    如需彻底清除请用 --all"
fi

# --- 5. 防火墙 ---
if [[ $PURGE -eq 1 ]]; then
  cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
EOF
  nft -f /etc/nftables.conf 2>/dev/null || true
  systemctl disable nftables 2>/dev/null || true
  rm -f /usr/local/sbin/nft-rollback.sh
  systemctl stop nft-rollback-once.timer 2>/dev/null || true
  echo "[✓] 防火墙规则已清空(当前无过滤)"
else
  # 保留防火墙但放行服务端口,避免误伤
  echo "[!] 已保留防火墙规则(如需清除请用 --all)"
fi

# --- 6. 内核调优 / Swap ---
if [[ $PURGE -eq 1 ]]; then
  rm -f /etc/sysctl.d/99-proxy-tuning.conf
  sysctl --system >/dev/null 2>&1 || true
  rm -f /etc/ssh/sshd_config.d/99-hardening.conf
  sshd -t 2>/dev/null && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true) || true
  echo "[✓] 系统调优与 SSH 加固已回滚"
fi

if [[ $PURGE -eq 1 && $KEEP_SWAP -eq 0 ]]; then
  swapoff /swapfile 2>/dev/null || true
  rm -f /swapfile
  sed -i '\#^/swapfile#d' /etc/fstab
  echo "[✓] Swap 已移除"
elif [[ $KEEP_SWAP -eq 1 ]]; then
  echo "[!] 已保留 Swap"
fi

echo
echo "========== 卸载完成 =========="
[[ $PURGE -eq 0 ]] && echo "提示:加 --all 可彻底清除所有痕迹"
echo
