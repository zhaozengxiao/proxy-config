# 一键部署脚本

目录内容:
| 文件 | 用途 |
|---|---|
| `install.sh` | 一键部署(幂等,可重复运行) |
| `uninstall.sh` | 卸载/回滚 |
| `mihomo-config.yaml` | 客户端配置(Clash/Mihomo) |
| `vless-link.txt` / `hysteria2-link.txt` | 分享链接(注意含凭据) |

---

## 快速开始

在**目标服务器**上以 root 运行。

**方式一:一键执行(推荐)**

```bash
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh)
```

带参数:

```bash
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh) --skip-tuning
bash <(curl -sL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh) --status
```

**方式二:先下载再执行**

```bash
curl -fsSL https://raw.githubusercontent.com/zhaozengxiao/proxy-config/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

脚本会自动完成 6 个阶段:

1. **系统调优** — 创建 Swap、启用 BBR、TCP 调优、SSH 加固
2. **安装 sing-box** — 下载指定版本,创建专用用户
3. **实测选 SNI** — 逐个真实测试候选伪装目标,自动选可用的
4. **生成配置** — 生成 UUID/Reality 密钥对/自签证书,写入配置
5. **systemd 服务** — 配安全沙箱、开机自启
6. **防火墙** — nftables 默认 DROP,仅放行必要端口

结束后自动做**端到端验证**并打印客户端凭据。

---

## 参数

```bash
sudo ./install.sh --no-hysteria2      # 只部署 Reality
sudo ./install.sh --skip-tuning       # 跳过内核调优
sudo ./install.sh --skip-firewall     # 跳过防火墙(⚠️ 慎用)
sudo ./install.sh --status            # 查看状态
sudo ./install.sh --credentials       # 打印凭据与分享链接

# 自定义版本/端口
sudo SINGBOX_VERSION=1.13.21 REALITY_PORT=8443 ./install.sh
```

---

## 设计要点

### 幂等
重复运行不会重新生成密钥,不会破坏现有配置。可安全用于修复。

密钥存于 `/root/.sing-box-secrets/`,存在则复用;删除该目录即触发全新生成(轮换)。

### 自动选 SNI(重要)
脚本会**逐个实测**候选伪装目标能否完成 Reality 握手,**只选真正可用的**。

> 踩坑记录:`www.microsoft.com` 表面满足 TLS1.3+X25519,但实际无法用于 Reality 握手(服务端报 `REALITY: processed invalid connection`)。因此脚本不硬编码单一目标。

### 防火墙安全网
应用防火墙前会启动一个 **3 分钟定时任务**:若脚本中断或 SSH 被切断,自动回滚为全放行,防止把自己锁在服务器外。

### 失败即停
`set -euo pipefail`,任一步骤失败立即中止,不会留下半成品。

---

## 卸载

```bash
sudo ./uninstall.sh              # 停服务、删二进制,保留密钥/配置/防火墙
sudo ./uninstall.sh --all        # 全部清除(含密钥、防火墙、调优、Swap)
sudo ./uninstall.sh --all --keep-swap   # 全部清除但保留 Swap
```

---

## 验证过的环境

- Ubuntu 24.04.4 LTS / x86_64
- AWS Lightsail `ap-northeast-1`,2 vCPU / 414MB 内存
- sing-box 1.13.21

本脚本已在**真实干净环境**完整测试:全新部署 → 重复运行(幂等)→ 重启持久化 → 隧道连通,全部通过。

---

## 部署后

1. 用 `mihomo-config.yaml` 导入客户端
2. 或使用 `--credentials` 输出的分享链接
3. 详细运维见 `README-运维手册.md`
