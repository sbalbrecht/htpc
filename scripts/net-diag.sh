#!/bin/bash
# Network diagnostics for LAN access to docker-published services.
# Writes everything to logs/net-diag.txt (world-readable).
OUT=/home/steve/server/logs/net-diag.txt
{
echo "=== date ==="; date
echo "=== ip addr (non-docker) ==="; ip -4 addr | grep -v -E "docker|br-|veth"
echo "=== default route ==="; ip route show default
echo "=== ip_forward ==="; sysctl net.ipv4.ip_forward
echo "=== ufw ==="; ufw status verbose 2>&1
echo "=== iptables filter (INPUT/FORWARD policies + rules) ==="; iptables -S 2>&1
echo "=== iptables nat ==="; iptables -t nat -S 2>&1
echo "=== nft ruleset summary ==="; nft list ruleset 2>&1 | head -120
echo "=== ss listeners on service ports ==="; ss -tlnp 2>&1 | grep -E ":(4545|7878|8989|9696|8090|8091|8118|32400|8080)\b"
echo "=== curl each port via LAN IP (source=this box) ==="
for p in 4545 7878 8989 9696 8090 8091 8118 32400; do
  curl -sS -o /dev/null -w "port $p: %{http_code}\n" --max-time 5 http://192.168.0.22:$p/ 2>&1
done
echo "=== docker-proxy processes ==="; pgrep -a docker-proxy | cut -c1-160
} > "$OUT" 2>&1
chmod 644 "$OUT"
