#!/bin/bash
# Unified Container Network entrypoint
# 同时拉起 mihomo / tailscale / cloudflare mesh / cloudflare tunnel，
# 任一进程退出时整个容器退出，由 docker restart 策略整体重启。
#
# 服务选择：SERVICES 环境变量，逗号分隔，可选：
#   mihomo / tailscale / mesh / cloudflared
# 默认全部启动。例：SERVICES=mihomo,tailscale 只启动代理和 tailscale。

PIDS=""

start() {
    "$@" &
    PIDS="$PIDS $!"
}

# ---------- 服务选择 ----------
SERVICES="${SERVICES:-mihomo,tailscale,mesh,cloudflared}"
SERVICES="$(printf '%s' "${SERVICES}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"

svc_enabled() {
    case ",${SERVICES}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "[init] services: ${SERVICES}"

# ---------- dbus（仅 mesh 需要） ----------
if svc_enabled mesh; then
    mkdir -p /run/dbus
    start dbus-daemon --system --nofork --nopidfile
fi

# ---------- Cloudflare One Client（Mesh 节点） ----------
if svc_enabled mesh; then
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
else
    echo "[mesh] disabled"
fi

# ---------- Tailscale ----------
if svc_enabled tailscale; then
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
else
    echo "[tailscale] disabled"
fi

# ---------- mihomo（TUN 模式，接管默认路由） ----------
if svc_enabled mihomo; then
    start mihomo -d /etc/mihomo
else
    echo "[mihomo] disabled"
fi

# ---------- cloudflared（Cloudflare Tunnel） ----------
if svc_enabled cloudflared; then
    if [ -n "${TUNNEL_TOKEN:-}" ]; then
        echo "[cloudflared] starting tunnel with TUNNEL_TOKEN"
        start cloudflared --no-autoupdate tunnel run --token "${TUNNEL_TOKEN}"
        CLOUDFLARED_PID=$!
    elif [ -n "${TUNNEL_ID:-}" ] && [ -n "${TUNNEL_CRED_FILE:-}" ]; then
        echo "[cloudflared] starting tunnel ${TUNNEL_ID}"
        start cloudflared --no-autoupdate tunnel run --cred-file "${TUNNEL_CRED_FILE}" "${TUNNEL_ID}"
        CLOUDFLARED_PID=$!
    else
        echo "[cloudflared] TUNNEL_TOKEN not set, skip"
    fi
else
    echo "[cloudflared] disabled"
fi

echo "[init] all services launched, waiting"
trap 'echo "[init] stopping"; kill ${PIDS} 2>/dev/null' TERM INT
wait -n
code=$?
echo "[init] a service exited (code ${code}), stopping container"
kill ${PIDS} 2>/dev/null
exit ${code}
