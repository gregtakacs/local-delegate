# The delegate worker for this repo: the generic worker (local-delegate's delegate-worker:local)
# plus what gorb-os's own gates need, matching CI (.github/workflows/ci.yml):
#   - clang 21 and lld 21 from apt.llvm.org: the apps build to wasm with them, and the shelf
#     check is byte-for-byte, so a different clang would fail it (BUILDING.md);
#   - zlib, Pillow, NumPy and tzdata for the host suites;
#   - Go (tools/orb-manager/go.mod's version) for the hub's gate, `make check-hub`;
#   - ESP-IDF v5.5.6 (CI's espressif/idf:v5.5.6), esp32s3 only, so a worker can `idf.py build` the
#     firmware: a step that adds a .c file and forgets main/CMakeLists.txt fails in the sandbox,
#     not on the orchestrator's bench; and the suites that read build/config/sdkconfig.h or the
#     IDF's NVS generator run. It builds only: the sandbox has no serial and no device;
#   - tzdata 2026.5 for Python (CI's pin), for the zone-rule suites.
# `make check-sandbox` is the gate a worker runs (BUILDING.md).
# Build:  docker build -t delegate-worker-gorb:local -f tools/delegate/worker.Dockerfile tools/delegate
# Use:    DELEGATE_IMAGE=delegate-worker-gorb:local delegate run|chain ...
FROM delegate-worker:local

RUN apt-get update && apt-get install -y --no-install-recommends gnupg zlib1g-dev python3-pil python3-numpy tzdata \
 && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-21 main" \
      > /etc/apt/sources.list.d/llvm-21.list \
 && apt-get update && apt-get install -y --no-install-recommends clang-21 lld-21 \
 && rm -rf /var/lib/apt/lists/* \
 && /usr/lib/llvm-21/bin/clang --version | head -1

ENV ORB_CLANG=/usr/lib/llvm-21/bin/clang \
    PATH=/usr/lib/llvm-21/bin:$PATH

# Go for the hub's gate (make check-hub); the version is tools/orb-manager/go.mod's.
ARG GO_VERSION=1.27.2
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz \
 && /usr/local/go/bin/go version
ENV PATH=/usr/local/go/bin:$PATH GOFLAGS="-buildvcs=false -modcacherw"

# ESP-IDF v5.5.6, esp32s3 only (CI's espressif/idf:v5.5.6): build-only, no device in the sandbox.
RUN apt-get update && apt-get install -y --no-install-recommends \
      flex bison gperf cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0 wget \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch v5.5.6 --recursive --shallow-submodules \
      https://github.com/espressif/esp-idf.git /opt/esp/esp-idf \
 && IDF_TOOLS_PATH=/opt/esp/tools /opt/esp/esp-idf/install.sh esp32s3 \
 && chmod -R a+rX /opt/esp
ENV IDF_PATH=/opt/esp/esp-idf IDF_TOOLS_PATH=/opt/esp/tools

# For the system Python the host suites run on: tzdata at CI's pin (the zone-rule suites), and
# the IDF's NVS generator at the version IDF v5.5.6 installs, 0.1.9 as v5.4 did (host_layout_carry_test.py emits the real
# NVS format with it; CI reaches it through export.sh, the suites here run outside it).
RUN python3 -m pip install --break-system-packages --no-cache-dir tzdata==2026.5 esp-idf-nvs-partition-gen==0.1.9

