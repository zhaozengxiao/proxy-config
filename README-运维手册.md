# 东京 Lightsail 代理 — 运维手册

服务器:`43.207.68.215` (Tokyo, AWS Lightsail, Ubuntu 24.04)

---

## 一、客户端导入

### 方式 1:Clash / Mihomo 配置文件(推荐)

文件:`mihomo-config.yaml`

导入 Clash Verge / Clash Meta / Mihomo:
1. 打开客户端 → 「订阅」→ 新建 → 类型选 **Local / 本地文件**
2. 选择 `mihomo-config.yaml`
3. 首次使用会提示下载 GeoIP/GeoSite 数据库,允许即可

> 若客户端不自动下载 Geo 数据,手动放到客户端的 `work` 目录:
> - `geoip.metadb`:https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb
> - `geosite.dat`:https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat

### 方式 2:分享链接

**主节点(Reality):**
```
vless://56b7901b-43e7-41ba-b207-56971cdd70ae@43.207.68.215:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=nC-giNT6HwvbrhQ28-ALHbGs0k2vtrnt3hYDe6b_hms&sid=83887fe7a5d094e2&type=tcp&headerType=none#JP-Tokyo-Reality
```

**备用节点(Hysteria2):**
```
hysteria2://drfDF+OhkzcPBLYpRFSrDjdB8RgvxTPA@43.207.68.215:443/?sni=www.bing.com&insecure=1&alpn=h3#JP-Tokyo-Hysteria2
```

---

## 二、配置参数(备查)

| 项 | 值 |
|---|---|
| 服务器 | `43.207.68.215` |
| 主入口 | VLESS-Reality,TCP/443 |
| UUID | `56b7901b-43e7-41ba-b207-56971cdd70ae` |
| Reality 公钥 | `nC-giNT6HwvbrhQ28-ALHbGs0k2vtrnt3hYDe6b_hms` |
| short_id | `83887fe7a5d094e2`(备用 `639092f70460c0ce`) |
| Reality SNI | `www.apple.com` |
| flow | `xtls-rprx-vision` |
| 备用入口 | Hysteria2,UDP/443 |
| Hysteria2 密码 | `drfDF+OhkzcPBLYpRFSrDjdB8RgvxTPA` |
| Hysteria2 SNI | `www.bing.com`(自签证书) |

> ⚠️ **不要公开以上任何凭据。** 拿到就等于拿到你的代理。

---

## 三、服务器运维

### 连接服务器
```bash
cd /home/zhaozengxiao/dsh/666
ssh -i LightsailDefaultKey-ap-northeast-1.pem ubuntu@43.207.68.215
```

### 常用命令
```bash
# 状态
sudo systemctl status sing-box

# 重启
sudo systemctl restart sing-box

# 看实时日志
sudo journalctl -u sing-box -f

# 看最近错误
sudo journalctl -u sing-box -p err -n 30

# 校验配置(改动后必做)
sudo sing-box check -c /etc/sing-box/config.json

# 看防火墙
sudo nft list ruleset

# 看内存
free -m
```

### 改配置流程(重要)
```bash
sudo cp /etc/sing-box/config.json /etc/sing-box/config.json.bak
sudo nano /etc/sing-box/config.json
sudo sing-box check -c /etc/sing-box/config.json   # 必须先校验!
sudo systemctl restart sing-box
sudo systemctl status sing-box
```

---

## 四、故障排查

| 症状 | 检查 | 处理 |
|---|---|---|
| 连不上 | `sudo systemctl is-active sing-box` | `sudo systemctl restart sing-box` |
| 端口没在听 | `sudo ss -tlnp \| grep 443` | 看日志 `journalctl -u sing-box -n 50` |
| 客户端握手失败 | 服务端日志有 `REALITY: processed invalid connection` | 确认客户端 UUID/公钥/short_id/SNI 与服务端一致 |
| 突然全断 | Lightsail 控制台看实例状态 | 可能 IP 被封,见下节 |
| 内存吃紧 | `free -m` | 检查是否有残留进程 `ps aux \| grep sing-box` |

### 日志里的正常现象
```
REALITY: processed invalid connection
```
这是**正常的** —— 表示有人端口扫描但密钥不对,已被正确拒绝。说明抗探测在工作。

---

## 五、IP 被封的应对

Reality 能防**协议识别**,但防不了 **IP 封锁**。若某天国内直连不通但国外正常:

1. **先换备用入口**:客户端切到 Hysteria2 节点(UDP/443),TCP 被墙时 UDP 常还有救
2. **换 IP**:Lightsail 可解绑/绑定静态 IP(AWS 控制台 → Networking → Static IP)
3. **确认是否真被封**:
   ```bash
   # 从国内网络测试
   ping 43.207.68.215
   curl -v https://43.207.68.215:443 --max-time 5
   ```

---

## 六、安全注意

- **凭据泄露 = 代理被白嫖**。别把 `mihomo-config.yaml` 或分享链接提交到 Git / 发群里。
- 若怀疑泄露,**轮换凭据**:
  ```bash
  # 换 UUID
  sing-box generate uuid
  # 换 Reality 密钥对
  sing-box generate reality-keypair
  # 换 Hysteria2 密码
  sing-box generate rand --base64 24
  ```
  改完需同步更新客户端配置。
- 服务器已开启:仅密钥 SSH、防火墙默认 DROP、服务以非 root 运行、systemd 安全沙箱。

---

## 七、当前部署状态

```
sing-box   active + enabled (开机自启)
  ├─ TCP/443  VLESS-Reality  → 伪装 www.apple.com
  └─ UDP/443  Hysteria2      → 伪装 www.bing.com
nftables   enabled, 默认 DROP,仅放行 22/443(tcp+udp),SSH 限速 30/分钟
Swap       1G (已持久化)
内核       BBR + fq + TCP fastopt
内存       414MB 总量,服务占 ~24-42MB
```

### 备份文件位置
| 文件 | 说明 |
|---|---|
| `/etc/sing-box/config.json` | 当前配置 |
| `/etc/sing-box/*.bak-*` | 各阶段配置备份 |
| `/etc/nftables.conf` | 防火墙规则 |
| `/root/sb-secrets/` | 所有密钥(UUID/Reality/Hysteria2),权限 700 |
| `/etc/sing-box/INSTALL-INFO` | 安装元数据 |
| `/root/backup-stage0/` | 阶段 0 的 SSH/grub 备份 |
