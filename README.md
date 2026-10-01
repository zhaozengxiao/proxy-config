# proxy-config

在全新 Ubuntu VPS 上**一键部署** VLESS-Reality + Hysteria2 代理(sing-box)。

- 幂等 —— 可重复运行,不会重新生成密钥、不破坏现有配置
- 自动实测选 SNI —— 逐个验证伪装目标能否完成 Reality 握手,只选真正可用的
- 失败自动回滚 —— 防火墙出错或 SSH 被切断时自动恢复,不会把自己锁在服务器外
- 端到端验证 —— 部署完自动跑通隧道并打印客户端凭据

适用: **Ubuntu 22.04 / 24.04,x86_64,小内存 VPS(≥384MB)**

---

## 快速开始

在**目标服务器**上以 root 运行。

### 方式一:一键执行(推荐)

```bash
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh)
```

脚本会自动完成 6 个阶段:

1. **系统调优** — 创建 Swap、启用 BBR、TCP 调优、SSH 加固
2. **安装 sing-box** — 下载指定版本,创建专用用户
3. **实测选 SNI** — 逐个真实测试候选伪装目标,自动选可用的
4. **生成配置** — 生成 UUID / Reality 密钥对 / 自签证书,写入配置
5. **systemd 服务** — 配安全沙箱、开机自启
6. **防火墙** — nftables 默认 DROP,仅放行必要端口

### 方式二:先下载再执行

```bash
curl -fsSL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

### 查看帮助

```bash
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh) --help
```

---

## 参数

所有参数既可用于一键执行,也可用于本地 `./install.sh`。下面以本地写法为例。

| 参数 | 说明 |
|---|---|
| `--no-hysteria2` | 只部署 Reality,不装 Hysteria2 |
| `--skip-tuning` | 跳过内核调优(Swap / BBR / TCP / SSH 加固) |
| `--skip-firewall` | 跳过防火墙配置(⚠️ 慎用) |
| `--status` | 只查看当前运行状态,不做任何改动 |
| `--credentials` | 只打印凭据与分享链接 |
| `-h` / `--help` | 显示用法 |

```bash
sudo ./install.sh --no-hysteria2      # 只部署 Reality
sudo ./install.sh --skip-tuning       # 跳过内核调优
sudo ./install.sh --status            # 查看状态
sudo ./install.sh --credentials       # 打印凭据与分享链接
```

### 环境变量

可用环境变量覆盖默认值,同样适用于一键执行:

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SNI` | 自动实测选择 | 指定 Reality 伪装 SNI(跳过自动选) |
| `REALITY_PORT` | `443` | Reality 监听端口 |
| `HY2_PORT` | `443` | Hysteria2 监听端口 |
| `SSH_PORT` | `22` | SSH 端口(防火墙按此放行) |
| `SWAP_SIZE` | `1G` | Swap 大小 |
| `SINGBOX_VERSION` | `1.13.21` | sing-box 版本 |

```bash
# 本地执行
sudo REALITY_PORT=8443 SINGBOX_VERSION=1.13.21 ./install.sh

# 一键执行
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh) --no-hysteria2
```

---

## 卸载

```bash
# 一键卸载
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/uninstall.sh)

# 本地卸载
sudo ./uninstall.sh                    # 停服务、删二进制,保留密钥/配置/防火墙
sudo ./uninstall.sh --all              # 全部清除(含密钥、防火墙、调优、Swap)
sudo ./uninstall.sh --all --keep-swap  # 全部清除但保留 Swap
```

| 参数 | 说明 |
|---|---|
| (无) | 卸载服务与配置,保留密钥与防火墙规则 |
| `--all` | 彻底清除,含密钥、防火墙、内核调优、Swap |
| `--keep-swap` | 配合 `--all` 使用,保留 Swap |

---

## 仓库文件

| 文件 | 用途 |
|---|---|
| `install.sh` | 一键部署(幂等,可重复运行) |
| `uninstall.sh` | 卸载 / 回滚 |
| `README-一键部署.md` | 部署脚本说明 |
| `README-运维手册.md` | 日常运维、排障 |
| `README-部署笔记.md` | 完整部署过程与踩坑记录 |

> 部署后会在服务器上生成 `mihomo-config.yaml`(客户端配置)与 `vless-link.txt` / `hysteria2-link.txt`(分享链接)。
> 这些文件**含凭据,已在 `.gitignore` 中排除,不会进入本仓库**。请通过 `--credentials` 或服务器上的 `/root/.sing-box-secrets/` 获取。

---

## 设计要点

### 幂等

重复运行不会重新生成密钥,不会破坏现有配置,可安全用于修复。

密钥存于 `/root/.sing-box-secrets/`,存在则复用;删除该目录即触发全新生成(轮换)。

### 自动选 SNI(重要)

脚本会**逐个实测**候选伪装目标能否完成 Reality 握手,**只选真正可用的**。

> 踩坑记录:`www.microsoft.com` 表面满足 TLS1.3 + X25519,但实际无法用于 Reality 握手
> (服务端报 `REALITY: processed invalid connection`)。因此脚本不硬编码单一目标。

### 防火墙安全网

应用防火墙前会启动一个 **3 分钟定时任务**:若脚本中断或 SSH 被切断,自动回滚为全放行,防止把自己锁在服务器外。

### 失败即停

`set -euo pipefail`,任一步骤失败立即中止,不会留下半成品。

---

## 部署后

1. 用 `--credentials` 输出的分享链接导入客户端
2. 或在服务器上取 `mihomo-config.yaml` 导入 Clash / Mihomo
3. 查看状态:`sudo ./install.sh --status`
4. 详细运维见 [`README-运维手册.md`](README-运维手册.md)

常用命令:

```bash
sudo systemctl restart sing-box      # 重启服务
sudo journalctl -u sing-box -f       # 查看日志
```

---

## 验证过的环境

- Ubuntu 24.04.4 LTS / x86_64
- AWS Lightsail `ap-northeast-1`,2 vCPU / 414MB 内存
- sing-box 1.13.21

已在**真实干净环境**完整测试:全新部署 → 重复运行(幂等)→ 重启持久化 → 隧道连通,全部通过。
