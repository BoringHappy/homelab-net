# Unified Container Network

统一的容器网络出口：把 **mihomo（代理）+ Tailscale + Cloudflare Mesh + Cloudflare Tunnel** 放进同一个网络命名空间，其他容器共享这一套网络。

## 架构

一个 `net` 容器持有唯一的网络命名空间，入口脚本同时拉起 4 个进程：

- **mihomo** 以 TUN 模式接管默认路由，按目标地址分流：
  - LAN、Tailscale（`100.64.0.0/10`）、Cloudflare Mesh/WARP（`100.96.0.0/12`）→ DIRECT，不经代理
  - 其余流量 → 走代理出站
- **入站流量天然不经过 mihomo**：进入容器自身 IP 的包由内核本地投递，不会进入 tun0（`strict-route: false`）。Tailscale / Mesh / Tunnel 的入站连接直接到达对应服务。

任一进程退出时容器整体退出，由 Docker 的 `restart` 策略整机拉起。

其他容器通过 `network_mode: service:net` 复用整个网络，出站自动按上述策略路由，入站自动经 Tailscale / Mesh / Tunnel 暴露。

## 目录结构

```
.
├── docker-compose.yml              # net 容器 + 示例业务容器
├── .env.example                    # 各服务认证信息模板（复制为 .env）
├── mihomo/
│   └── config.example.yaml         # mihomo 分流配置（挂载为 /etc/mihomo/config.yaml）
└── net/
    ├── Dockerfile                  # 单镜像：4 个网络组件（基础镜像仓库可用 REGISTRY 覆盖）
    ├── entrypoint.sh               # 启动脚本：同时拉起全部进程
    ├── cloudflared/
    │   └── config.example.yml      # tunnel ingress 白名单配置示例（本地管理模式）
    └── firewall.example.sh         # 容器内防火墙（iptables）示例脚本
```

## 快速开始

首次使用前，先编辑两个文件：

- `.env`：`cp .env.example .env` 后填写 `TS_AUTHKEY` / `TUNNEL_TOKEN` / `MESH_NODE_TOKEN`，并按需调整 macvlan 网卡（`MACVLAN_PARENT`）和固定 IP（`NET_IP`）
- `mihomo/config.example.yaml`：把示例的 `example-proxy` 替换成你自己的代理节点

默认使用 macvlan 模式（`docker-compose.yml`），之后一条命令完成构建和启动：

```bash
cp .env.example .env && docker compose up -d --build
```

启动后验证：

```bash
docker compose ps                          # 容器状态
docker compose logs -f net                 # 滚动查看启动日志
docker exec unified-net ip addr            # 查看 macvlan 固定 IP
docker exec unified-net tailscale status   # Tailscale 状态
docker exec unified-net warp-cli status    # Cloudflare Mesh 状态
docker exec unified-net curl -x http://127.0.0.1:7890 https://www.gstatic.com/generate_204   # 代理连通性
```

其他部署模式见下文，用法相同，只是加 `-f` 指定文件。

## 部署模式选择

仓库提供了 4 个 compose 文件，按你的网络环境选一个：

| 模式 | 文件 | 容器网络 | 局域网访问方式 | 适用场景 |
| --- | --- | --- | --- | --- |
| macvlan（默认） | `docker-compose.yml` | macvlan，固定 LAN IP | 局域网设备直连容器 IP | 容器要有独立 LAN IP |
| 宿主机 IP | `docker-compose.host-ip.yml` | 默认 bridge + 端口映射 | `宿主机IP:7890` 等 | 简单省事，不想折腾网络 |
| host 网络 | `docker-compose.host.yml` | 共享宿主机网络命名空间 | 宿主机 IP 全端口 | 整机透明代理网关 |
| ipvlan L2 | `docker-compose.ipvlan.yml` | ipvlan，固定 LAN IP | 局域网设备直连容器 IP | 上游网络限制 MAC 数量 |

```bash
# macvlan（默认）
docker compose up -d --build

# 宿主机 IP
docker compose -f docker-compose.host-ip.yml up -d --build

# host 网络（整机代理网关，注意影响全宿主机的路由）
docker compose -f docker-compose.host.yml up -d --build

# ipvlan
docker compose -f docker-compose.ipvlan.yml up -d --build
```

注意事项：

- macvlan / ipvlan 只在 **Linux 且宿主机网卡能直通**时可用，Docker Desktop（macOS/Windows）、WSL2、大部分云主机不支持，那种环境用 host-ip 模式。
- macvlan / ipvlan 下，**宿主机自身无法直连容器 IP**（Linux 内核刻意隔离），宿主机访问走发布端口——两个文件都同时保留了默认 bridge 网络，端口发布才有效。
- host 模式下 mihomo TUN 会接管宿主机默认路由，**整台机器的非 LAN 流量都会走代理**，只在你确实想要整机代理时用。
- 4 个文件共用同一个 `container_name: unified-net`，同一台机器只能同时运行其中一个。
- 局域网固定 IP 相关变量（`MACVLAN_PARENT` 等）只被 macvlan / ipvlan 文件使用，其余模式忽略。

## 本地覆盖文件

- `docker-compose.override.yml`：会被 `docker compose up` **自动合并**进 `docker-compose.yml`，适合放本机专属的端口/卷/网络调整（已 gitignore）。
- `docker-compose.local.yml`：不会被自动加载，需要显式指定：`docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build`（已 gitignore）。

## 环境变量（.env）

| 变量 | 服务 | 说明 |
| --- | --- | --- |
| `REGISTRY` | 构建 | 基础镜像仓库，默认 `docker.io`，可换成镜像源/私有仓库 |
| `TS_AUTHKEY` | Tailscale | 登录密钥，[管理后台](https://login.tailscale.com/admin/settings/keys)生成 |
| `TS_AUTH_SERVER` | Tailscale | 可选，自定义控制服务器（如 Headscale），默认空 = 官方控制平面 |
| `TS_HOSTNAME` | Tailscale | 可选，节点名 |
| `TS_EXTRA_ARGS` | Tailscale | 可选，`tailscale up` 附加参数，如 `--advertise-routes=192.168.1.0/24` |
| `TUNNEL_TOKEN` | Cloudflare Tunnel | 隧道 token（优先于凭据文件方式） |
| `TUNNEL_ID` / `TUNNEL_CRED_FILE` | Cloudflare Tunnel | 可选，凭据文件方式（文件放在 `cfd-state` 卷或挂载目录） |
| `TUNNEL_CONFIG` | Cloudflare Tunnel | 可选，本地管理模式的 ingress 白名单配置（见下文「限制 Tunnel」一节） |
| `MESH_NODE_TOKEN` | Cloudflare Mesh | Mesh 节点 token，控制台 *Networking → Mesh → Add a node* |
| `SERVICES` | 服务选择 | 逗号分隔，可选 `mihomo` / `tailscale` / `mesh` / `cloudflared`，默认全部启动 |
| `LAN_SUBNET` | 防火墙 | 可选，容器内防火墙示例脚本使用的局域网网段 |
| `TZ` | 通用 | 时区 |

`.env` 已被 `.gitignore` 忽略，不会提交到仓库。

### 选择性启动

不需要某个组件时，在 `.env` 里用 `SERVICES` 指定即可，未启用的组件不会启动：

```bash
SERVICES=mihomo,tailscale        # 只要代理 + tailscale
SERVICES=mesh,cloudflared        # 只要 mesh + 隧道
SERVICES=mihomo                  # 只做透明代理网关
```

注意：`dbus` 会随 `mesh` 自动启停，不需要单独配置。

## 挂载与持久化

| 挂载 | 容器路径 | 作用 |
| --- | --- | --- |
| `./mihomo/config.example.yaml` | `/etc/mihomo/config.yaml` | mihomo 配置 |
| `./net/cloudflared/config.yml`（可选） | `/etc/cloudflared/config.yml` | tunnel ingress 白名单（本地管理模式，默认注释） |
| `./net/firewall.sh`（可选） | `/etc/firewall.sh` | 容器内防火墙脚本，entrypoint 在启动服务前执行（默认注释） |
| `ts-state` 卷 | `/var/lib/tailscale` | Tailscale 节点身份，删除卷 = 重新登录 |
| `warp-state` 卷 | `/var/lib/cloudflare-warp` | Mesh 注册状态，删除卷 = 重新注册 |
| `cfd-state` 卷 | `/etc/cloudflared` | cloudflared 凭据文件目录 |

## 限制 Cloudflare Tunnel 只转发部分服务

Tunnel 只能转发你明确列出的服务，做法取决于启动方式：

**方式一：token 模式（`TUNNEL_TOKEN`）**

隧道配置在 Cloudflare 控制台管理：*Zero Trust → Networks → Tunnels → 你的隧道 → Public Hostnames*。在那里只添加你想暴露的域名，并指向对应的本地服务（如 `http://localhost:8080`）。没有添加的域名不会有入口规则，tunnel 不会转发它们。

**方式二：凭据文件模式（`TUNNEL_ID` + `TUNNEL_CRED_FILE`）**

用本地配置文件定义 ingress 白名单：

```yaml
ingress:
  - hostname: app.example.com
    service: http://localhost:8080
  - hostname: dashboard.example.com
    service: http://127.0.0.1:3000
  - service: http_status:404   # 兜底：未列出的 hostname 一律 404
```

配置从上往下匹配，命中即停止；最后一条不写 `hostname` 的 `http_status:404` 是兜底，未显式列出的请求全部被拒。完整示例见 [net/cloudflared/config.example.yml](net/cloudflared/config.example.yml)。

启用步骤：

1. `cp net/cloudflared/config.example.yml net/cloudflared/config.yml`，改成你自己的 tunnel id 和服务地址
2. 在 compose 的 `volumes` 里取消注释 `./net/cloudflared/config.yml:/etc/cloudflared/config.yml:ro`
3. `.env` 里设置 `TUNNEL_CONFIG=/etc/cloudflared/config.yml`（并保留 `TUNNEL_ID` / `TUNNEL_CRED_FILE`）

补充：ingress 白名单限制的是「tunnel 转发到哪些本地服务」。所有服务共享同一个网络命名空间，cloudflared 本身能访问本机任意端口；如果想要进程级的纵深防御，把 cloudflared 改成独立用户运行，再用 iptables 的 `--uid-owner` 规则限制它只能连接指定端口（见下文的防火墙示例）。

## 容器内防火墙（iptables，不是 ufw）

容器里**不要用 ufw**：它是面向宿主机的 iptables 前端，依赖 systemd / 网络管理器，默认策略也是按宿主机场景设计的，放进容器基本不可用。本容器已经安装了 `iptables` 并带有 `NET_ADMIN` / `NET_RAW` 权限，直接写 iptables 规则即可（Debian 12 的 `iptables` 是 nft 后端）。

仓库提供 [net/firewall.example.sh](net/firewall.example.sh)：把脚本挂载到 `/etc/firewall.sh`，entrypoint 会在启动各服务之前执行它。示例包含：

- 幂等初始化：只清自定义链，不动 mihomo / Docker 的链
- 局域网网段（macvlan/ipvlan）只放行 mihomo 的 7890/9090，其余拒绝
- 注释掉的 OUTPUT 限制示例（进程级限制需要先让 cloudflared 跑在独立用户下）

启用步骤：

1. `cp net/firewall.example.sh net/firewall.sh`，按需改规则
2. 在 compose 的 `volumes` 里取消注释 `./net/firewall.sh:/etc/firewall.sh:ro`
3. 重启 net 容器

注意：其他业务容器通过 `network_mode: service:net` 共享本容器的网络命名空间，防火墙规则会影响它们；host 模式下还会影响宿主机本身（`iptables` 操作的是宿主机的表），务必小心。

## 其他容器复用

业务容器只需三行配置即可继承整套网络能力：

```yaml
services:
  my-app:
    image: your-app
    network_mode: service:net
    depends_on:
      - net
```

注意：

- 共享 netns 的所有容器共用同一个 IP，端口发布统一在 `net` 服务上声明（本仓库只默认发布了 mihomo 的 7890/9090，业务端口请自行加）。
- 容器间通过 `localhost` / `127.0.0.1` 互通。
- 需要独立 IP 或强隔离的服务，建议放在独立 bridge 网络，把默认路由指向 mihomo 容器做网关（进阶用法）。
- 网络容器内建 DNS：mihomo 监听 `127.0.0.1:53`（fake-ip），同 netns 的服务可直接使用。

## 常见问题

- **`/dev/net/tun` 不存在**：宿主机需要创建并挂载 `tun` 设备（`modprobe tun`），或确认 Docker 以 root 运行。
- **想重新注册 Tailscale / Mesh**：删掉对应卷再重启：`docker compose down -v` 会清掉全部状态卷（慎用），或 `docker volume rm` 指定卷。
- **cloudflared 出站走了代理**：这是设计行为（非 LAN/tailscale/mesh 的流量都走 mihomo）。若不想隧道依赖代理，把 [cloudflare.com/ips-v4](https://www.cloudflare.com/ips-v4) 的段加进 mihomo 配置的 DIRECT 规则（示例配置第 4 节有注释）。
- **启动顺序**：entrypoint 先启动 mihomo 并等其 DNS（`127.0.0.1:53`）就绪，再拉起 mesh / tailscale / cloudflared，避免启动期域名解析失败；mihomo 配置里 Tailscale / Mesh 网段已 DIRECT，业务流量不经过代理。注意：这些组件的注册/登录等控制面流量属于“非排除网段”，会走 mihomo 出站，想让控制面直连就把 Cloudflare/Tailscale 公网段加进 DIRECT。
- **代理节点不通**：mihomo 配置里的 `example-proxy` 只是占位，替换成真实节点或订阅后重启 `net`。

## 自动重启

任一核心进程（mihomo / tailscaled / warp-svc / cloudflared）退出时，容器随之退出，由 `restart: unless-stopped` 整体重启。Docker 对重启自带指数退避，不会高频硬重启。

## 局域网固定 IP（macvlan）

容器同时挂在默认桥接网络和 macvlan 网络上：桥接网络负责端口发布（宿主机通过 `宿主机IP:7890` 访问），macvlan 给容器一个固定 LAN IP（局域网设备直接访问 `192.168.5.50:7890` 使用代理）。

网卡、网段、网关、固定 IP 全部在 `.env` 里配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MACVLAN_PARENT` | `enp3s0` | 宿主机物理网卡名，**网卡变了只改这里** |
| `MACVLAN_SUBNET` | `192.168.5.0/24` | 局域网网段 |
| `MACVLAN_GATEWAY` | `192.168.5.1` | 主路由 IP |
| `NET_IP` | `192.168.5.50` | 容器固定 IP（建议选 DHCP 池之外的地址） |

注意事项：

- 网卡名（如 `enp3s0`）不同机器可能不同，更换宿主机或网卡时只需改 `.env`，不用动 compose。
- macvlan 的限制：**宿主机自己无法直接访问 macvlan 容器的 IP**（需要额外在宿主机建 macvlan 子接口），局域网其他设备不受影响。
- 挂上 macvlan 后，LAN 网段是容器的本地接口子网，mihomo 的 `auto-route` 会保持直连，与配置里的 LAN DIRECT 规则一致。
- 不需要局域网固定 IP 时，删掉 compose 里 `net` 服务的 `networks` 段和文件底部的 `networks` 定义即可。
- 想从宿主机访问容器服务时走发布端口（`宿主机IP:7890` / `宿主机IP:9090`），或额外在宿主机上建 macvlan 子接口；ipvlan 同样隔离宿主机直连，不能解决这个问题。
- mihomo 的 DNS（fake-ip 模式）只适合容器内部使用，**不要**让局域网设备把 `192.168.5.50:53` 当作 DNS 服务器，否则会拿到无法路由的 fake IP。
