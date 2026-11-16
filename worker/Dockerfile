# delegate-worker — the box the implementing model works in.
#
# It is a toolchain, not a sandbox you configure per repo: node + npm/pnpm/yarn (corepack),
# python3, git, a C/C++ toolchain (host tests that compile C, native npm modules), and a
# headless chromium for the pixel-verification loop in
# opencode/rules/verify-ui.md. The worker gets the task's worktree and nothing else from
# the host: no docker socket, no home directory, no SSH keys, no root.
#
# The fonts are load-bearing, not cosmetic: without them chromium rasterises text blank and
# the model "fixes" correct CSS chasing a font bug that only exists in here.
#
# Trixie, not bookworm: bookworm's git is 2.39.5, which has no ``--attr-source`` (git 2.42+), so a
# repo that hardens read-only git runs with that flag fails *every* git call in here — the gate
# rejects the argv before git reads anything — while passing on any host with a current git. Trixie
# ships 2.47.3. Check ``git --version`` before downgrading the base.
FROM node:24-trixie-slim

# OpenCode 2 (the plugins and the worker config are 2.x-only). The release asset is pinned by sha256,
# the same pin codehub's OpenCode image uses.
ARG OPENCODE_VERSION=2.3.0
ARG OPENCODE_SHA256=fc0f81522aceeabac47693d88389efa2bc517ce74c2c38fd6967819fcc6e4d3b

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip zip xz-utils jq less procps \
      python3 python3-venv python3-pip \
      build-essential \
      openssl postgresql-client \
      iproute2 iputils-ping netcat-openbsd python3-serial \
      chromium fonts-liberation fonts-dejavu-core fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable

# Verify-then-extract, then ask the binary its version ("opencode v<version>"; anything else fails
# the build). Nothing may be left at /tmp/opencode: OpenCode makes that directory at start and dies
# with EEXIST if a file is in the way (found by codehub's first real build, 2026-11-15).
RUN set -eu; \
    curl -fsSL -o /tmp/opencode.tgz \
        "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz"; \
    echo "${OPENCODE_SHA256}  /tmp/opencode.tgz" | sha256sum --check; \
    mkdir /tmp/opencode-dl; \
    tar -xzf /tmp/opencode.tgz -C /tmp/opencode-dl opencode; \
    install -m 0755 /tmp/opencode-dl/opencode /usr/local/bin/opencode; \
    rm -rf /tmp/opencode-dl /tmp/opencode.tgz
RUN opencode --version | grep -qx "opencode v${OPENCODE_VERSION}"
# Never self-update inside a worker: this flag plus the rendered config's "autoupdate": false.
ENV OPENCODE_DISABLE_AUTOUPDATE=1

# HOME is bind-mounted per task (so opencode's session store survives between review
# rounds). The cache dirs are named volumes shared across tasks; 1777 so the volume's first
# copy-up is writable whatever uid the host runs us as.
RUN mkdir -p /home/worker/.cache /home/worker/.npm /home/worker/.local/share \
 && chmod -R 1777 /home/worker

COPY --chmod=755 worker/delegate-shot /usr/local/bin/delegate-shot
COPY --chmod=755 worker/entrypoint.sh /usr/local/bin/delegate-entrypoint
COPY opencode/ /opt/delegate/opencode/
COPY lib/render-opencode-config.py /opt/delegate/lib/render-opencode-config.py

# Fail the build, not the first task, if chromium cannot launch unprivileged in here.
RUN delegate-shot --probe

ENV HOME=/home/worker \
    DELEGATE_IN_CONTAINER=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    OPENCODE_DISABLE_SHARE=1
WORKDIR /home/worker
ENTRYPOINT ["/usr/local/bin/delegate-entrypoint"]
CMD ["bash"]
