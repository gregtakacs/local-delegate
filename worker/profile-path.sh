# /etc/profile.d/zz-delegate-path.sh (root-owned, installed by worker/Dockerfile).
#
# Every verify, exec and chain step runs through `bash -lc`, and a login shell reads
# /etc/profile, which overwrites PATH with Debian's default. That dropped what the image
# put on PATH (a project layer's Go and clang: "go: command not found" in a worker whose
# image had Go) and, worse, the guard shims the runner puts FIRST on PATH, so a guarded
# command ran unguarded in every verify. The entrypoint records the PATH the container
# was started with as DELEGATE_PATH; this file, sourced after /etc/profile's reset,
# puts it back. Root-owned, so a worker cannot edit it away.
if [ -n "${DELEGATE_PATH:-}" ]; then
  PATH=$DELEGATE_PATH
  export PATH
fi
