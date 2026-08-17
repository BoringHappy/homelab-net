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
└── net/
    ├── Dockerfile                  # 单镜像：4 个网络组件
    ├── entrypoint.sh               # 启动脚本：同时拉起全部进程
    ├── mihomo/
    │   └── config.example.yaml     # mihomo 分流配置（挂载为 /etc/mihomo/config.yaml）
```

## 快速开始

```bash
# 1. 准备环境变量（填写各服务的认证 token）
cp .env.example .env
vi .env

# 2. 把 mihomo 配置里的 example-proxy 替换成你自己的代理节点
vi net/mihomo/config.example.yaml

# 3. 构建并启动
docker compose up -d --build

# 4. 查看状态
docker compose logs -f net
```

## 环境变量（.env）

| 变量 | 服务 | 说明 |
| --- | --- | --- |
| `TS_AUTHKEY` | Tailscale | 登录密钥，[管理后台](https://login.tailscale.com/admin/settings/keys)生成 |
| `TS_HOSTNAME` | Tailscale | 可选，节点名 |
| `TS_EXTRA_ARGS` | Tailscale | 可选，`tailscale up` 附加参数，如 `--advertise-routes=192.168.1.0/24` |
| `TUNNEL_TOKEN` | Cloudflare Tunnel | 隧道 token（优先于凭据文件方式） |
| `TUNNEL_ID` / `TUNNEL_CRED_FILE` | Cloudflare Tunnel | 可选，凭据文件方式（文件放在 `cfd-state` 卷或挂载目录） |
| `MESH_NODE_TOKEN` | Cloudflare Mesh | Mesh 节点 token，控制台 *Networking → Mesh → Add a node* |
| `TZ` | 通用 | 时区 |

`.env` 已被 `.gitignore` 忽略，不会提交到仓库。

## 挂载与持久化

| 挂载 | 容器路径 | 作用 |
| --- | --- | --- |
| `./net/mihomo/config.example.yaml` | `/etc/mihomo/config.yaml` | mihomo 配置 |
| `ts-state` 卷 | `/var/lib/tailscale` | Tailscale 节点身份，删除卷 = 重新登录 |
| `warp-state` 卷 | `/var/lib/cloudflare-warp` | Mesh 注册状态，删除卷 = 重新注册 |
| `cfd-state` 卷 | `/etc/cloudflared` | cloudflared 凭据文件目录 |

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
- **代理节点不通**：mihomo 配置里的 `example-proxy` 只是占位，替换成真实节点或订阅后重启 `net`。
