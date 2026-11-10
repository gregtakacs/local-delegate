#!/bin/bash
# Renders squid.conf from DELEGATE_ALLOW_HOSTS (space-separated host names that may be reached
# even though they resolve to private addresses — the model endpoint) and runs squid in the
# foreground, logging to stdout (`docker logs delegate-egress` shows every request).
set -euo pipefail

allow=${DELEGATE_ALLOW_HOSTS:-}
# A task's own proxy (a grant with network.mode = "allow", docs/grants.md) also gets the
# LAN destinations that grant names, space-separated, each as kind|value|port (kind net or host).
# grants.py validated them; this only turns them into ACLs.
lan=${DELEGATE_LAN_ALLOW:-}
conf=/tmp/squid.conf

{
  echo "http_port 3128"
  echo "pid_filename none"
  echo "cache deny all"
  echo "cache_mem 8 MB"
  echo "access_log stdio:/dev/stdout"
  echo "cache_log /dev/null"
  echo "via off"
  echo "forwarded_for delete"
  echo "connect_timeout 20 seconds"
  # Model streams can idle while the model thinks; never cut a live tunnel for idleness.
  echo "read_timeout 60 minutes"
  echo "client_lifetime 8 hours"
  echo "acl SSL_ports port 443"
  echo "acl Safe_ports port 80 443"
  echo "acl CONNECT method CONNECT"
  echo "acl blocked dst 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 ::1 fc00::/7 fe80::/10"
  if [ -n "$allow" ]; then
    # -n: no reverse DNS. Without it a raw LAN IP that reverse-resolves to the model host
    # (it does, via the --add-host entry) would match and be let through.
    echo "acl model dstdomain -n $allow"
  fi
  i=0
  for e in $lan; do                       # kind|value|port, kind: net (ip or cidr) or host
    i=$((i + 1))
    IFS='|' read -r kind h port <<< "$e"
    case "$kind" in
      net) echo "acl lan$i dst $h" ;;
      host) echo "acl lan$i dstdomain -n $h" ;;
      *) echo "delegate-egress: bad LAN entry '$e'" >&2; exit 2 ;;
    esac
    if [ -n "$port" ]; then
      echo "acl lan${i}p port $port"
      echo "http_access allow lan$i lan${i}p"
    else
      echo "http_access allow lan$i"
    fi
  done
  echo "http_access deny !Safe_ports"
  echo "http_access deny CONNECT !SSL_ports"
  [ -n "$allow" ] && echo "http_access allow model"
  echo "http_access deny blocked"
  echo "http_access allow all"
} > "$conf"

echo "delegate-egress: allowing model host(s): ${allow:-none}; LAN by grant: ${lan:-none}; denying other private ranges" >&2
exec squid -N -f "$conf"
