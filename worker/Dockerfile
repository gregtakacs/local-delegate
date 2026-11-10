# delegate-worker — the box the implementing model works in.
#
# It is a toolchain, not a sandbox you configure per repo: node + npm/pnpm/yarn (corepack),
# python3, git, and a headless chromium for the pixel-verification loop in
# opencode/rules/verify-ui.md. The worker gets the task's worktree and nothing else from
# the host: no docker socket, no home directory, no SSH keys, no root.
#
# The fonts are load-bearing, not cosmetic: without them chromium rasterises text blank and
# the model "fixes" correct CSS chasing a font bug that only exists in here.
FROM node:24-bookworm-slim

ARG OPENCODE_VERSION=1.18.30

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip zip xz-utils jq less procps \
      python3 python3-venv python3-pip \
      openssl postgresql-client \
      iproute2 iputils-ping netcat-openbsd python3-serial \
      chromium fonts-liberation fonts-dejavu-core fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable

# Pinned through npm rather than the curl installer so a rebuild is reproducible.
RUN npm install -g "opencode-ai@${OPENCODE_VERSION}" && npm cache clean --force \
 && opencode --version

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
