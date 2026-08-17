FROM debian:bookworm-slim

ARG TARGETARCH=amd64

# 版本锁定，需要升级时改这里再重新 build
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG TAILSCALE_VERSION=1.102.2
ARG CLOUDFLARED_VERSION=2026.7.2
ARG MIHOMO_VERSION=v1.19.30
ARG WARP_VERSION=2026.6.880.0

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# 基础依赖：curl/ca-certificates 用于下载，dbus 是 warp-svc 的前置，
# iproute2/iptables 是 warp-svc 和 mihomo 管理路由/防火墙所需
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus \
        iproute2 \
        iptables \
        jq \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# s6-overlay：多进程 supervisor，负责同时拉起 4 个服务并按依赖排序
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/s6-overlay-noarch.tar.xz
RUN if [ "${TARGETARCH}" = "arm64" ]; then S6_ARCH=aarch64; else S6_ARCH=x86_64; fi \
    && curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" -o /tmp/s6-overlay.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay.tar.xz \
    && rm -f /tmp/s6-overlay*.tar.xz

# Tailscale（内核态 TUN，需要 NET_ADMIN + /dev/net/tun）
RUN curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${TARGETARCH}.tgz" -o /tmp/tailscale.tgz \
    && tar -xzf /tmp/tailscale.tgz -C /tmp \
    && install -m 0755 "/tmp/tailscale_${TAILSCALE_VERSION}_${TARGETARCH}/tailscale" /usr/local/bin/tailscale \
    && install -m 0755 "/tmp/tailscale_${TAILSCALE_VERSION}_${TARGETARCH}/tailscaled" /usr/local/bin/tailscaled \
    && rm -rf /tmp/tailscale*

# cloudflared（Cloudflare Tunnel）
RUN curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${TARGETARCH}" -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared

# mihomo（代理内核，TUN 模式）
RUN curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${TARGETARCH}-${MIHOMO_VERSION}.gz" -o /tmp/mihomo.gz \
    && gunzip /tmp/mihomo.gz \
    && install -m 0755 /tmp/mihomo /usr/local/bin/mihomo \
    && rm -f /tmp/mihomo.gz

# Cloudflare One Client（Mesh 节点 = warp-svc + warp-cli）
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg -o /usr/share/keyrings/cloudflare-warp-archive-keyring.asc \
    && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.asc] https://pkg.cloudflareclient.com/ bookworm main" > /etc/apt/sources.list.d/cloudflare-client.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflare-warp=${WARP_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# 默认 mihomo 配置（compose 会用卷挂载覆盖）
COPY mihomo/config.example.yaml /etc/mihomo/config.yaml

# s6 服务定义 + 启用标记
COPY s6/ /etc/s6-overlay/s6-rc.d/
COPY user-bundles.d/ /etc/s6-overlay/user-bundles.d/
RUN chmod +x /etc/s6-overlay/s6-rc.d/*/run

ENTRYPOINT ["/init"]
