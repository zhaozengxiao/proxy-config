# 自建代理部署笔记

> VLESS-Reality + Hysteria2,基于 sing-box
> 整理时间:2026-09-28
> 实测环境:Ubuntu 24.04 / x86_64 / 412MB 内存 / AWS Lightsail

---

## 目录

1. [方案选型](#一方案选型)
2. [部署步骤](#二部署步骤)
3. [客户端配置](#三客户端配置)
4. [验证方法](#四验证方法)
5. [踩坑记录](#五踩坑记录重要)
6. [故障排查](#六故障排查)
7. [运维命令](#七运维命令)
8. [安全建议](#八安全建议)

---

## 一、方案选型

### 为什么选 VLESS-Reality

| 方案 | 内存 | 抗封锁 | 需要域名 | 结论 |
|---|---|---|---|---|
| **VLESS-Reality** | ~40MB | ★★★★★ | ❌ 不需要 | ✅ 主选 |
| Hysteria2 | ~40MB(共用进程) | ★★★★ | 建议有 | ✅ 备用 |
| Shadowsocks-2022 | ~8MB | ★★★ | ❌ | 可作备选 |
| Trojan / VMess+TLS | ~20MB | ★★★ | ✅ 必须 | 无域名时排除 |
| 各类 Web 面板 | 150MB+ | — | — | ❌ 小内存不够 |

**Reality 的核心优势:**

1. **不需要域名、不需要证书** —— 借用真实大站的 TLS 握手做伪装
2. **抗主动探测** —— 探测者拿到的是真实网站的证书,拿不到代理特征
3. **443 端口最不显眼** —— 混在正常 HTTPS 流量里

### 为什么用 sing-box 而不是 Xray

两者都支持 Reality。选 sing-box 的理由:一个二进制同时能跑 Reality + Hysteria2,配置一份管理,内存更省。

**版本选择:** 用 **1.13.21** 而不是最新的 1.14.x。

> 实测 1.14.1 常驻内存 ~50MB,1.13.21 是 ~40MB。1.14 新增的 `libcronet.so` 只服务 cloudflared 等客户端特性,服务端做跳板用不到。

---

## 二、部署步骤

### 前置检查

```bash
# 系统架构
uname -m                    # 需要 x86_64

# 内存
free -m                     # 建议 ≥384MB

# 确认端口没被占用
ss -tlnp | grep -E ':(443|22)'
```

### 一键脚本

脚本在 `proxy-config/install.sh`(742 行),幂等可重跑。

**上传并执行:**

```bash
# 上传
scp install.sh root@<服务器IP>:/root/

# 执行(默认 443 端口)
ssh root@<服务器IP> 'cd /root && bash install.sh'

# 或指定端口
ssh root@<服务器IP> 'cd /root && REALITY_PORT=8443 HY2_PORT=8443 bash install.sh'

# 只装 Reality,不要 Hysteria2
ssh root@<服务器IP> 'cd /root && bash install.sh --no-hysteria2'
```

### 脚本做的 6 件事

| 阶段 | 内容 | 关键点 |
|---|---|---|
| 1 | 系统调优 | 1G Swap、BBR、TCP 调优、SSH 加固 |
| 2 | 安装 sing-box | 下载二进制、创建 nologin 用户 |
| 3 | **实测选 SNI** | 逐个真实测试伪装目标,只选可用的 |
| 4 | 生成配置 | UUID、Reality 密钥对、自签证书 |
| 5 | systemd 服务 | 安全沙箱、开机自启 |
| 6 | 防火墙 | nftables 默认 DROP,带自动回滚安全网 |

### 手动部署要点

如果不用脚本,关键配置如下。

**内核调优 `/etc/sysctl.d/99-proxy-tuning.conf`:**

```
vm.swappiness = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
fs.file-max = 1000000
```

**生成密钥:**

```bash
# Reality 密钥对
sing-box generate reality-keypair
# 输出:PrivateKey / PublicKey

# UUID
sing-box generate uuid

# short_id(8 字节十六进制)
sing-box generate rand --hex 8

# Hysteria2 密码
sing-box generate rand --base64 24
```

**核心配置 `/etc/sing-box/config.json`:**

```json
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
      "listen_port": 443,
      "users": [ { "uuid": "<UUID>", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.apple.com", "server_port": 443 },
          "private_key": "<PRIVATE_KEY>",
          "short_id": ["<SHORT_ID>"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": [ { "password": "<HY2_PASSWORD>" } ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/hy2.crt",
        "key_path": "/etc/sing-box/hy2.key"
      },
      "masquerade": "https://www.bing.com/"
    }
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
```

**systemd 服务 `/etc/systemd/system/sing-box.service`:**

```ini
[Unit]
Description=sing-box service (VLESS-Reality proxy)
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=singbox
Group=singbox

# 仅授予绑定特权端口的能力
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3
LimitNOFILE=1000000

# 安全沙箱
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
# ⚠️ 必须含 AF_NETLINK,否则启动失败
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallFilter=@system-service

ReadWritePaths=/var/lib/sing-box
StateDirectory=sing-box

MemoryMax=180M

[Install]
WantedBy=multi-user.target
```

**nftables 防火墙 `/etc/nftables.conf`:**

```
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

        # SSH 限速防爆破
        tcp dport 22 ct state new meter ssh_rl { ip saddr limit rate over 30/minute burst 10 packets } drop
        tcp dport 22 ct state new accept

        # 代理入口
        tcp dport 443 accept
        udp dport 443 accept
    }

    chain forward { type filter hook forward priority filter; policy drop; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
```

---

## 三、客户端配置

### Mihomo / Clash 配置

完整模板见 `proxy-config/mihomo-config.yaml`。核心部分:

```yaml
proxies:
  # 主节点
  - name: "US-Reality"
    type: vless
    server: <服务器IP>
    port: 443
    uuid: <UUID>
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: <PUBLIC_KEY>
      short-id: <SHORT_ID>

  # 备用节点
  - name: "US-Hysteria2"
    type: hysteria2
    server: <服务器IP>
    port: 443
    password: <HY2_PASSWORD>
    sni: www.bing.com
    skip-cert-verify: true
    alpn: [h3]
    up: "50 Mbps"
    down: "200 Mbps"

proxy-groups:
  # 自动故障转移:主节点挂了切备用
  - name: "🚀 节点选择"
    type: fallback
    proxies: ["US-Reality", "US-Hysteria2"]
    url: http://www.gstatic.com/generate_204
    interval: 180
```

### 分享链接格式

**VLESS-Reality:**
```
vless://<UUID>@<IP>:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=<PUBLIC_KEY>&sid=<SHORT_ID>&type=tcp&headerType=none#节点名
```

**Hysteria2:**
```
hysteria2://<PASSWORD>@<IP>:443/?sni=www.bing.com&insecure=1&alpn=h3#节点名
```

### 客户端注意事项

- 导入后**模式设为「规则」**,不要用「全局」
- **TUN 模式**按需开启。若开启,所有流量都走代理,排查问题时容易被误导(见踩坑记录)
- Hysteria2 用自签证书,需要 `skip-cert-verify: true`

---

## 四、验证方法

**验证要从三个层次做,只做一层会漏问题。**

### 第 1 层:配置语法

```bash
sing-box check -c /etc/sing-box/config.json
```

> ⚠️ **语法通过 ≠ 能跑。** 遇到过配置合法但运行时报错的情况。

### 第 2 层:服务真的起来了

```bash
systemctl is-active sing-box
ss -tlnp | grep 443    # TCP 监听
ss -ulnp | grep 443    # UDP 监听
```

### 第 3 层:端到端隧道(最重要)

**在服务器上构建测试客户端,真实走一遍流量:**

```bash
# 服务端自测 Reality
cat > /tmp/test.json <<EOF
{ "log":{"level":"error"},
  "inbounds":[{"type":"socks","tag":"s","listen":"127.0.0.1","listen_port":18600}],
  "outbounds":[{"type":"vless","tag":"v","server":"127.0.0.1","server_port":443,
    "uuid":"<UUID>","flow":"xtls-rprx-vision",
    "tls":{"enabled":true,"server_name":"www.apple.com",
      "utls":{"enabled":true,"fingerprint":"chrome"},
      "reality":{"enabled":true,"public_key":"<PUB>","short_id":"<SID>"}}}] }
EOF

sing-box run -c /tmp/test.json &
sleep 3
curl -s --socks5 127.0.0.1:18600 -o /dev/null -w "HTTP %{http_code}\n" https://www.google.com
```

**期望:`HTTP 200`。** 返回 `000` 说明隧道不通。

### 第 4 层:伪装效果

```bash
echo | openssl s_client -connect <IP>:443 -servername www.apple.com 2>/dev/null | grep -E 'subject=|Verify return'
```

**期望:看到苹果的真实证书,`Verify return code: 0`。**

### 第 5 层:外部可达性

```bash
# 从你自己的电脑测(不是服务器上)
timeout 8 bash -c 'echo > /dev/tcp/<IP>/443' && echo "通" || echo "不通"

# 稳定性抽测
for i in $(seq 1 10); do
  timeout 5 bash -c 'echo > /dev/tcp/<IP>/443' 2>/dev/null && echo -n "✓" || echo -n "✗"
done; echo
```

---

## 五、踩坑记录(重要)

这些都是实际踩过的,写下来避免重复。

### 1. `www.microsoft.com` 无法用作 Reality 目标 ⭐

**现象:** 配置校验通过、服务正常启动、伪装证书也正常,但**客户端连不上**。服务端日志:

```
REALITY: processed invalid connection
```

**排查过程:**
- 密钥对数学验证 ✅(用 x25519 独立推导,匹配)
- short_id 解码 ✅(服务端日志显示收到了正确的 ID)
- 系统时钟 ✅(NTP 同步正常)
- IPv6 干扰 ❌(排除,强制 IPv4 也一样)

**定位:** 做了对照实验,换 `www.apple.com` 后立即成功。`www.bing.com` / `aws.amazon.com` 也都正常,**只有微软不行**。

**结论:** 微软的 TLS 实现与 Reality 的代理握手不兼容。

**已固化到脚本:** SNI 候选列表即不含 microsoft,且脚本会**逐个实测**而非硬编码。

### 2. systemd 沙箱导致启动失败

**现象:** 服务无限重启,日志 `address family not supported by protocol`

**原因:** `RestrictAddressFamilies` 没包含 `AF_NETLINK`,而 sing-box 用它监控路由变化。

**修正:**
```ini
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
```

### 3. sing-box 1.13 的 DNS 语法变更

旧格式(1.12 之前)已废弃:
```json
{ "address": "https://1.1.1.1/dns-query" }   // ❌ 会报错
```

新格式:
```json
{ "type": "https", "server": "1.1.1.1" }     // ✅
```

### 4. DNS detour 指向空 direct 出站报错

**现象:** `detour to an empty direct outbound makes no sense`

**原因:** DNS server 的 `detour` 指向了 tag 为 `direct` 的空出站。

**修正:** 去掉 `detour`,让它走 `route.final`。

### 5. `pkill -f` 会杀掉自己的 shell ⭐

**现象:** 每次清理进程,SSH 就断开。

**原因:** `pkill -f 'abc.json'` 按**完整命令行**匹配,而我的 SSH 命令字符串里**包含了** `abc.json`,于是匹配到自己的 shell 并杀掉。

**修正:** 用精确 PID:
```bash
MP=$(pgrep -f "^/tmp/mihomo"); for P in $MP; do kill $P; done
```
或锚定匹配:`pkill -f "^/path/to/binary"`

### 6. SSH 限速规则把自己锁在外面 ⭐

**现象:** SSH `Connection timed out`,但 ping 通。

**原因:** nftables 里的 SSH 限速规则(每 IP 每分 N 个新连接),排障时反复重连,迅速耗尽配额 → 自己的 IP 被 drop。

**表现特征:** ping 通、TCP 22 不通。等 1-2 分钟自动恢复。

**修正:** 限速放宽到 **30/分钟 burst 10**(仍能挡爆破)。排障时注意别短时间反复重连。

### 7. 「连不上」不一定是服务器问题 ⭐⭐

**最坑的一个。** 现象:所有国际流量超时,但国内网站正常。

**误判过程:**
1. 怀疑端口问题 → 换端口,无效
2. 怀疑 IP 被封 → 换 IP,短暂可用后又不行
3. 怀疑家里网络 → 但国内目标完全稳定

**真实原因:** 电脑上 **FlClash 开着 TUN 模式 + 全局模式**,把**所有**流量都拦走了。配置里选的节点失效 → 表现为"所有国际流量不通"。

**关键鉴别证据:**
```
1.1.1.1:443     不通  ← 国际
8.8.8.8:443     不通  ← 国际
www.baidu.com   通    ← 国内
```

**如果连 1.1.1.1 和 8.8.8.8 都不通,但你根本没在用代理 → 一定是本地有东西接管了流量。**

**排查命令:**
```bash
# 检查代理进程
ps aux | grep -iE 'clash|mihomo|sing-box|v2ray'

# 检查 TUN 网卡
ip link show | grep -iE 'tun|utun|clash'

# 检查系统代理
gsettings get org.gnome.system.proxy mode

# 检查环境变量
env | grep -i proxy
```

---

## 六、故障排查

### 症状对照表

| 症状 | 可能原因 | 处理 |
|---|---|---|
| 服务起不来 | 配置错误 / 沙箱限制 | `journalctl -u sing-box -n 50` |
| 端口没监听 | 服务未启动 / 端口冲突 | `ss -tlnp \| grep 443` |
| 客户端握手失败 | 凭据不匹配 | 核对 UUID / 公钥 / short_id / SNI |
| 日志 `REALITY: processed invalid connection` | ①探测者无密钥(正常) ②客户端配置错 ③**SNI 目标不兼容** | 换 SNI 目标试试 |
| ping 通但 TCP 不通 | ①SSH 限速 ②本地代理接管 ③IP 被针对性阻断 | 见下方判断流程 |
| 所有国际流量不通 | **本地代理/TUN 接管** | 关掉本地代理再测 |
| 国内正常但国外不通 | 同上 | 同上 |

### 判断"ping 通但 TCP 不通"的流程

```
1. ping 通 + TCP 22 不通
   → 大概率是 SSH 限速,等 1-2 分钟重试

2. ping 通 + 所有端口不通 + 连 1.1.1.1 也不通
   → 本地有代理/TUN 接管流量,检查本机

3. ping 通 + 只有代理端口不通
   → 防火墙没放行,检查 nftables + 云平台安全组

4. ping 不通
   → 服务器宕机 / IP 被封 / 实例已停止

5. 部分时段通,部分时段不通
   → 线路拥塞 / 运营商国际出口问题
```

### IP 被封的特征

- 逐步恶化:先 TCP 时通时坏 → 后完全不通
- **ping 和 TCP 一起挂**(和"本地代理问题"的区别)
- 换 IP 后立即恢复

**注意:** AWS Lightsail 的网关会**代替已停止的实例回应 ICMP**,所以 ping 通**不能证明**服务器在运行。

---

## 七、运维命令

```bash
# ---- 服务 ----
systemctl status sing-box          # 状态
systemctl restart sing-box         # 重启
systemctl is-enabled sing-box      # 是否开机自启

# ---- 日志 ----
journalctl -u sing-box -f          # 实时日志
journalctl -u sing-box -p err -n 30  # 最近错误
journalctl -u sing-box --since '1 hour ago'

# ---- 配置 ----
sing-box check -c /etc/sing-box/config.json   # 改完必须校验!
cp /etc/sing-box/config.json{,.bak}            # 改前备份

# ---- 网络 ----
ss -tlnp | grep 443                # TCP 监听
ss -ulnp | grep 443                # UDP 监听
nft list ruleset                   # 防火墙规则

# ---- 资源 ----
free -m                            # 内存
systemctl show sing-box -p MemoryCurrent   # 服务占用
```

### 改配置的标准流程

```bash
# 1. 备份
sudo cp /etc/sing-box/config.json /etc/sing-box/config.json.bak

# 2. 修改
sudo nano /etc/sing-box/config.json

# 3. 校验(关键!别跳过)
sudo sing-box check -c /etc/sing-box/config.json

# 4. 重启
sudo systemctl restart sing-box

# 5. 验证
sudo systemctl is-active sing-box
journalctl -u sing-box -n 20
```

### 轮换凭据

```bash
# 备份旧凭据
sudo cp -a /root/.sing-box-secrets /root/.sing-box-secrets.bak

# 生成新的
sing-box generate uuid
sing-box generate reality-keypair
sing-box generate rand --base64 24

# 更新配置 → 校验 → 重启 → 同步更新客户端
```

---

## 八、安全建议

### 必须做的

1. **SSH 只允许密钥登录**
   ```
   PasswordAuthentication no
   PermitRootLogin prohibit-password
   ```

2. **防火墙默认 DROP**
   只放行必要端口(22 + 代理端口)

3. **服务以非 root 运行**
   专用用户 + 仅授予 `CAP_NET_BIND_SERVICE`

4. **凭据妥善保管**
   别提交到 Git、别发群里。拿到凭据 = 拿到代理使用权

### 建议做的

5. **绑定静态 IP**
   AWS Lightsail 绑定期间免费,避免 IP 变动

6. **定期轮换凭据**
   怀疑泄露时立即换 UUID / 密钥对 / 密码

7. **控制使用人数**
   用的人越多、流量特征越明显,越容易被针对

8. **准备备用方案**
   - Hysteria2 走 UDP,在 TCP 被干扰时可能还有救
   - 保留部署脚本,新机器 5 分钟就能重建

### 最后的保险:防火墙自动回滚

改防火墙前设一个定时回滚,防止把自己锁在服务器外:

```bash
# 创建回滚脚本
cat > /usr/local/sbin/nft-rollback.sh <<'EOF'
#!/bin/bash
if [ -f /run/nft-unconfirmed ]; then
  nft flush ruleset
  logger -t nft-rollback 'ALERT: 防火墙未确认,已回滚为全放行'
  rm -f /run/nft-unconfirmed
fi
EOF
chmod +x /usr/local/sbin/nft-rollback.sh

# 设置 3 分钟后触发
touch /run/nft-unconfirmed
systemd-run --on-active=3min --unit=nft-rollback-once /usr/local/sbin/nft-rollback.sh

# 改防火墙 ...

# 确认无误后取消
rm -f /run/nft-unconfirmed
systemctl stop nft-rollback-once.timer
```

---

## 附:文件清单

```
proxy-config/
├── install.sh              # 一键部署(幂等)
├── uninstall.sh            # 卸载
├── mihomo-config.yaml      # 客户端配置
├── vless-link.txt          # 分享链接
├── hysteria2-link.txt      # 分享链接
├── README-部署笔记.md       # 本文档
├── README-一键部署.md       # 脚本使用说明
└── README-运维手册.md       # 日常运维
```

**服务器端路径:**

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/sing-box` | 二进制 |
| `/etc/sing-box/config.json` | 配置 |
| `/etc/sing-box/hy2.crt/.key` | Hysteria2 自签证书 |
| `/root/.sing-box-secrets/` | 所有密钥(700 权限) |
| `/etc/nftables.conf` | 防火墙 |
| `/etc/systemd/system/sing-box.service` | 服务单元 |

---

## 一句话总结

> **部署本身很简单(脚本一键搞定),难的是排查——而排查的关键是:分清楚问题在服务器、在链路、还是在你自己电脑上。**
>
> 这次最大的教训:花了很多时间怀疑服务器,结果问题在本地客户端的 TUN 模式。
> **下次遇到"连不上",先测 `1.1.1.1`。如果连它都不通,先查自己电脑。**
