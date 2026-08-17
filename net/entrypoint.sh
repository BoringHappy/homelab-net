#!/bin/bash
# Unified Container Network entrypoint
# 同时拉起 mihomo / tailscale / cloudflare mesh / cloudflare tunnel，
# 任一进程退出时整个容器退出，由 docker restart 策略整体重启。

PIDS=""

start() {
    "$@" &
    PIDS="$PIDS $!"
}

echo "[init] starting unified network stack"

# ---------- dbus（warp-svc 前置依赖） ----------
mkdir -p /run/dbus
start dbus-daemon --system --nofork --nopidfile

# ---------- Cloudflare One Client（Mesh 节点） ----------
start warp-svc
for i in $(seq 1 30); do
    warp-cli --accept-tos status >/dev/null 2>&1 && break
    sleep 1
done

if [ -n "${MESH_NODE_TOKEN:-}" ]; then
    if [ -f /var/lib/cloudflare-warp/reg.json ]; then
        echo "[mesh] already registered"
    else
        echo "[mesh] registering Mesh node"
        warp-cli --accept-tos connector new "${MESH_NODE_TOKEN}" \
            || echo "[mesh] registration failed, check warp logs"
    fi
    warp-cli --accept-tos connect 2>/dev/null || echo "[mesh] connect failed"
else
    echo "[mesh] MESH_NODE_TOKEN not set, skip"
fi

# ---------- Tailscale ----------
SOCK=/var/run/tailscale/tailscaled.sock
start tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket="${SOCK}"
for i in $(seq 1 30); do
    [ -S "${SOCK}" ] && break
    sleep 1
done

if tailscale --socket="${SOCK}" status >/dev/null 2>&1; then
    echo "[tailscale] already logged in"
elif [ -n "${TS_AUTHKEY:-}" ]; then
    echo "[tailscale] logging in"
    tailscale --socket="${SOCK}" up \
        --authkey="${TS_AUTHKEY}" \
        ${TS_HOSTNAME:+--hostname="${TS_HOSTNAME}"} \
        ${TS_EXTRA_ARGS:-} \
        || echo "[tailscale] up failed, check tailscaled logs"
else
    echo "[tailscale] TS_AUTHKEY not set, skip login"
fi

# ---------- mihomo（TUN 模式，接管默认路由） ----------
start mihomo -d /etc/mihomo

# ---------- cloudflared（Cloudflare Tunnel） ----------
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "[cloudflared] starting tunnel with TUNNEL_TOKEN"
    start cloudflared --no-autoupdate tunnel run --token "${TUNNEL_TOKEN}"
elif [ -n "${TUNNEL_ID:-}" ] && [ -n "${TUNNEL_CRED_FILE:-}" ]; then
    echo "[cloudflared] starting tunnel ${TUNNEL_ID}"
    start cloudflared --no-autoupdate tunnel run --cred-file "${TUNNEL_CRED_FILE}" "${TUNNEL_ID}"
else
    echo "[cloudflared] TUNNEL_TOKEN not set, skip"
fi

echo "[init] all services launched, waiting"
trap 'echo "[init] stopping"; kill ${PIDS} 2>/dev/null' TERM INT
wait -n
code=$?
echo "[init] a service exited (code ${code}), stopping container"
kill ${PIDS} 2>/dev/null
exit ${code}
