# Grants: named access profiles for a task

**Status:** implemented, 2026-11-10 (`lib/grants.py`, `tests/test_grants.sh`). It replaces the special case `--orb` / `--orb-flash` with one
general permission structure. `--orb` keeps working, as a built-in grant.

## Why

A task's access today is a set of unrelated flags (`--egress`, `--read`, `--service`, `--github`,
`--orb`, `--orb-flash`). Only `--orb` grants a device, and it grants too much: the host network,
the whole of `/dev`, and every serial port (character majors 166 and 188), not just that orb's.
Other uses need the same shape with different contents: a second orb, a logic analyser, a LAN
printer, a Home Assistant API.

## The model

A **grant** is a named file the owner writes. A task gets it with `--grant NAME` (repeatable), or
with `"grants": [...]` in a chain plan, at the plan level or per step. A grant can only **add**
access to the default sandbox, never remove its guarantees: own worktree, read-only shared
`.git`, no docker socket, no home folder, no root.

### Where grants come from (the trust rule)

- Grants are read **only** from `$DELEGATE_GRANTS_DIR` (default `~/.config/delegate/grants/`),
  as `<name>.toml`. They're **never** read from a repo, a worktree, a spec or a chain plan's
  folder: a worker can write those, and a worker must not be able to grant itself anything.
- The file must be owned by the user running `delegate`, and must be neither group- nor
  world-writable. The same goes for its folder. Anything else is refused.
- Names match `[a-z0-9][a-z0-9._-]{0,47}`.
- A grant is parsed with `tomllib`, never sourced. Unknown keys are an error, so a typo is not a
  silent default.

### The file

```toml
# ~/.config/delegate/grants/orb-desk.toml
brief = """You may use the orb on the desk over its HTTP API at $ORB_IP and its serial port
$ORB_SERIAL. Do not flash, erase or re-provision it."""   # told to the worker, verbatim
lock = "orb-desk"            # optional: one task at a time holds this key (default: none)

[network]
mode = "host"                # "filtered" (default) | "open" | "host" | "allow"
allow = []                   # mode = "allow" only: "host", "host:port", "ip", "ip:port", "cidr"

[devices]
paths = ["/dev/serial/by-id/usb-Espressif_USB_JTAG_serial_debug_unit_AA:BB:CC:DD:EE:FF-if00"]
reenumerate = true           # see "Devices" below (default false)

[mounts]
ro = []                      # extra read-only paths, mounted at the same path, secrets blanked like --read
rw = []                      # extra read-write paths (use sparingly; the report lists them)

[env]
ORB_IP = "192.168.1.50"      # plain values only; no secrets here (use mounts.ro for a token file)

[guards.flash]               # a named guard: these commands refuse on PATH unless --allow flash
commands = ["esptool", "esptool.py", "idf.py"]
note = "Flashing is BLOCKED for this task: talk to the device over its HTTP API."

[probe]                      # optional, checked at every round start and told to the worker
serial = "/dev/serial/by-id/..."   # attached, and free or held by which process
http = "http://192.168.1.50/api/status"   # reachable or not (host mode only)
```

### What each part does

- **`network.mode`**, combined over all of a task's grants, where the widest mode wins and the
  report says which grant asked for it:
  - `filtered`: today's default. The model endpoint and the public internet through the shared
    egress proxy; no LAN.
  - `allow`: `filtered` plus exactly the listed LAN destinations. It gets a **per-task proxy**
    (`delegate-egress-<task>`, the same squid image) whose ACL allows the model hosts and these
    destinations, and denies every other private range. HTTP and HTTPS only: mDNS, raw TCP and UDP
    don't pass a proxy, so those uses need `host`.
  - `open`: today's `--egress open`.
  - `host`: the host's network stack, unfiltered. Needed for mDNS, ARP (`ip neigh`) and raw
    sockets. This is what `--orb` uses today.
- **`devices.paths`:** each path is resolved, a by-id symlink to its `/dev/tty*` node, and gets
  its own cgroup rule.
  - `reenumerate = false` (the default): the rule is the exact `major:minor`, and only that node
    plus its by-id link are visible.
  - `reenumerate = true`: for a board whose node changes when it resets (a flash re-enumerates
    `ttyACM0` as `ttyACM1`). `/dev` is mounted live so the by-id link keeps resolving, and the rule
    covers that device's **major** only (166 or 188), still never other majors. The report says
    it's broader than one node.
  - The group that owns the node is added to the container.
  - A path that doesn't exist at round start isn't an error: the probe reports it, and the worker
    is told.
- **`mounts`:** `ro` works like `--read`, including secret blanking. `rw` is a plain bind mount,
  listed in the report.
- **`env`:** plain variables. A value can't contain a newline. Secrets never go here; mount a
  file instead.
- **`guards`:** each named guard puts refusing shims for its commands first on PATH, and its
  `note` goes into the brief. `--allow NAME` (repeatable; chain plan `"allow": [...]`) lifts that
  guard for that task. A shim is a guard, not a sandbox: a full path still reaches the binary.
  The brief says so, and the report records every refused call.
- **`lock`:** an exclusive key under `$DELEGATE_STATE/locks/grant-<key>`, taken at run start and
  released at the end, with the same stale-lock handling as today's orb lock. A second task asking
  for the same key fails at once with the holder's id.
- **`brief`:** appended verbatim to the round prompt under "Access this task has". `$VAR`s from
  the grant's `env` are expanded.
- **`probe`:** the existing serial check (attached, free, or held by which process; never kill
  it), plus an optional HTTP check. Results go into the round prompt.

### Built-in: the orb

`--orb FILE` keeps working, and is resolved to an **in-memory grant** built from the
`.orb-target` file by `lib/orbtarget.py`:

| Field | Value |
|---|---|
| `network.mode` | `host` |
| `devices.paths` | `[ORB_SERIAL]` when set, with `reenumerate = true` |
| `env` | `ORB_LABEL`, `ORB_BASE_MAC`, `ORB_SERIAL`, `ORB_IP` |
| `guards.flash` | today's three commands and note |
| `lock` | `orb-<base mac or serial>`, as today |
| `brief` | today's sentences |

`--orb-flash` is `--allow flash`. A user grant file may also set `kind = "orb"` and
`target = "<path to .orb-target>"` to name that same built-in, so a chain plan can say
`"grants": ["orb-desk"]` instead of a path.

### Where it shows

- **`meta.env`** keeps `GRANTS` and `ALLOW`. `delegate continue` reuses them and can't add new
  ones.
- **The round report's header** lists the grants, the effective network mode and why, the
  devices, the rw mounts, the lifted guards, and any refused guarded calls.
- **The dashboard's mode labels:** `mode.grants` (a list of names) and `mode.allow`. The existing
  `orb` label stays for the built-in.
- **`delegate grant list`** shows the grants in the folder and whether each one is valid.
  **`delegate grant show NAME`** prints the docker arguments, prompt lines, lock and probes it
  would produce, without running anything. That's how it's tested and how the owner checks a
  new grant.

### Runners

- **docker:** everything above.
- **native, and `--here` (unsandboxed):** the task already has the user's full access, so
  network, devices and mounts are moot. `env`, `brief`, `guards` (PATH shims), `lock` and `probe`
  still apply. The report says the grant was applied as native.

### Not in scope

- Per-grant CPU or memory limits.
- GPU devices (a later grant field, `gpus`).
- Secrets inside grant files (always a mounted file).
- Grants from a repo, ever.

## Tests (`tests/test_grants.sh`, no docker needed except where marked)

1. **Parsing and refusals:** unknown keys are refused, and so are a group-writable file, a
   world-writable folder, and a bad name. A grant name pointing at a file inside the repo is
   never looked up.
2. **`grant show`:** filtered, allow, open and host each produce the expected args. An exact
   device gives one `major:minor` rule; `reenumerate` gives one major-only rule and never the
   other major. Mounts and env come out as expected.
3. **Combining:** host beats open beats allow beats filtered (the widest wins), with the deciding
   grant named; and allow-lists merge.
4. **Guards:** a guarded command refuses and is logged, and runs with `--allow`.
5. **Locks:** a second task with the same lock key is refused; a stale lock is cleared.
6. **The orb built-in:** `--orb FILE` and the equivalent `kind = "orb"` grant produce
   **byte-identical docker args** to today's `--orb` path (a golden file captured before the
   change), apart from the documented ones.
7. **Continue:** `continue` reuses `GRANTS` and refuses `--grant`.
8. **The allow proxy** (marked docker): a task with `mode = "allow"` reaches a listed LAN
   address through its own proxy, and is refused one that isn't listed.
