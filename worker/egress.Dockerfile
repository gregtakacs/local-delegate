# delegate-egress — the only way out of a worker's network when DELEGATE_EGRESS=filtered.
#
# Workers sit on an --internal docker network (no route anywhere) with HTTP(S)_PROXY pointed
# here. Squid lets through: the model endpoint host(s), and the public internet (package
# registries, GitHub, docs). It refuses: every private / link-local / loopback / CGNAT
# destination — your LAN, the docker host, cloud metadata — judged by the *resolved* address,
# so a public name that resolves to a LAN address is refused too.
#
# It never decrypts anything: HTTPS goes through as CONNECT tunnels.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends squid ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --chmod=755 worker/egress-entrypoint.sh /usr/local/bin/egress-entrypoint
USER proxy
EXPOSE 3128
ENTRYPOINT ["/usr/local/bin/egress-entrypoint"]
