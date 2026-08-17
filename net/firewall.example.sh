#!/bin/bash
# ============================================================
# 容器内防火墙示例（iptables）
#
# 用法：
#   1. 复制为 net/firewall.sh
#   2. compose 中取消注释 volumes 里的
#      ./net/firewall.sh:/etc/firewall.sh:ro
#   3. 重启 net 容器，entrypoint 会在启动各服务前执行本脚本
#
# 为什么不用 ufw：
#   ufw 是给宿主机用的 iptables 前端，依赖 systemd/网络管理器，
#   在容器里基本不可用；容器已有 NET_ADMIN + iptables，直接写规则即可。
#   注意：本容器是共享网络命名空间（其他业务容器 network_mode: service:net），
#   规则会影响所有共享 netns 的服务，改规则前想清楚。
#
# 规则可重复执行（每次容器启动都会跑），脚本是幂等的。
# ============================================================

set -eu

FW_CHAIN=NET_GUARD

# 幂等初始化：自定义链只清自己的规则，不碰 mihomo / Docker 的链
iptables -F "${FW_CHAIN}" 2>/dev/null || iptables -N "${FW_CHAIN}"
iptables -C INPUT -j "${FW_CHAIN}" 2>/dev/null || iptables -I INPUT 1 -j "${FW_CHAIN}"

# 回环和已建立连接必须放行，否则会把自己搞断网
iptables -A "${FW_CHAIN}" -i lo -j ACCEPT
iptables -A "${FW_CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 示例 1：局域网（macvlan/ipvlan 网段）只开放 mihomo 代理/面板端口
LAN_SUBNET="${LAN_SUBNET:-192.168.5.0/24}"
iptables -A "${FW_CHAIN}" -s "${LAN_SUBNET}" -p tcp -m multiport --dports 7890,9090 -j ACCEPT
iptables -A "${FW_CHAIN}" -s "${LAN_SUBNET}" -j DROP

# 示例 2（默认注释）：限制 cloudflared 只能访问本机指定端口。
# 注意：本仓库 cloudflared 以 root 运行，无法用 --uid-owner 按进程区分，
# 这条 OUTPUT 规则会同时限制 mihomo/tailscale 等所有进程；
# 想要进程级限制，需要把 cloudflared 改成独立用户再配合 owner 规则。
# iptables -A OUTPUT -p tcp -m multiport --dports 8080,8443 -j ACCEPT
# iptables -A OUTPUT -m conntrack --ctstate NEW -p tcp -j REJECT --reject-with tcp-reset

# 转发链（FORWARD）默认不动：本容器的业务容器走 network_mode: service:net
# 共享 netns，不经 FORWARD；只有把本容器当网关的独立容器才涉及 FORWARD。

echo "[firewall] rules applied"
