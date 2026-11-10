#!/usr/bin/env python3
"""Generate the long-refactor fixture deterministically: gen.py OUT_DIR

60 job modules that log through the legacy `oldLog(level, msg)` API, written in several
import styles (named, aliased, namespace) and with some dynamic levels, plus filler so that
reading the whole tree costs real context. The hidden check regenerates this to get the
original behaviour to compare against.
"""
import os
import random
import sys

out = sys.argv[1]
rng = random.Random(4242)
N = 60
VERBS = ["reconcile", "import", "audit", "rebuild", "prune", "sync", "score", "index", "bill", "notify"]
NOUNS = ["invoices", "ledgers", "orbs", "themes", "designs", "users", "bakes", "releases", "tokens", "files"]

os.makedirs(f"{out}/src/jobs", exist_ok=True)
os.makedirs(f"{out}/test", exist_ok=True)

open(f"{out}/package.json", "w").write(
    '{ "name": "jobs", "version": "3.1.0", "type": "module", "private": true,\n'
    '  "scripts": { "test": "node --test" } }\n')
open(f"{out}/src/log.js", "w").write('''// Logging for the job runner.
//
// LEGACY: oldLog(level, msg) is deprecated (see MIGRATION.md). Messages go to the sink,
// filtered by LOG_LEVEL (debug < info < warn < error; default debug).

const ORDER = ["debug", "info", "warn", "error"];
let sink = (level, msg) => console.log(`[${level}] ${msg}`);

export function setSink(fn) {
  sink = fn;
}

function threshold() {
  const t = (process.env.LOG_LEVEL || "debug").toLowerCase();
  return ORDER.includes(t) ? ORDER.indexOf(t) : 0;
}

export function oldLog(level, msg) {
  if (!ORDER.includes(level)) throw new Error("unknown log level: " + level);
  if (ORDER.indexOf(level) < threshold()) return;
  sink(level, String(msg));
}
''')
open(f"{out}/MIGRATION.md", "w").write('''# Logging migration

`oldLog(level, msg)` is replaced by a level-keyed object:

```js
import { log } from "../log.js";
log.info("message");   // also log.debug / log.warn / log.error
log[level]("message"); // when the level is computed
```

Behaviour must not change: same messages, same levels, same LOG_LEVEL filtering, and an
unknown level still throws `Error("unknown log level: <level>")`. `setSink` stays.
''')

styles = ["named", "alias", "namespace"]
index_lines = []
for i in range(1, N + 1):
    name = f"job_{i:02d}"
    verb, noun = rng.choice(VERBS), rng.choice(NOUNS)
    style = styles[i % 3]
    k = rng.randint(2, 9)
    lim = rng.randint(20, 150)
    big = rng.randint(200, 1500)
    if style == "named":
        imp, call = 'import { oldLog } from "../log.js";', "oldLog"
    elif style == "alias":
        imp, call = 'import { oldLog as say } from "../log.js";', "say"
    else:
        imp, call = 'import * as L from "../log.js";', "L.oldLog"
    filler = "\n".join(
        f"// - step {j}: {rng.choice(VERBS)} the {rng.choice(NOUNS)} cache before {rng.choice(VERBS)}ing; "
        f"kept for the {rng.randint(2019, 2026)} audit trail" for j in range(rng.randint(8, 16)))
    dyn = rng.random() < 0.4
    body = f'''{imp}

// {name}: {verb} {noun}.
//
// Operational notes:
{filler}

function weight(item) {{
  const w = item.value * {k};
  if (w > {lim * k}) {{
    {call}("debug", `{name}: heavy item ${{item.id}} (${{w}})`);
  }}
  return w;
}}

export function run(items) {{
  {call}("info", "{name}: {verb} " + items.length + " {noun}");
  if (items.length === 0) {{
    {call}("warn", "{name}: nothing to {verb}");
    return 0;
  }}
  let total = 0;
  for (const item of items) {{
    if (item.value > {lim}) {{
      {call}("warn", `{name}: large value ${{item.value}} for ${{item.id}}`);
    }}
    total += weight(item);
  }}
'''
    if dyn:
        body += f'''  const level = total > {big} ? "error" : "info";
  {call}(level, "{name}: total " + total);
'''
    else:
        body += f'''  {call}("info", "{name}: total " + total);
'''
    body += "  return total;\n}\n"
    open(f"{out}/src/jobs/{name}.js", "w").write(body)
    index_lines.append(f'export {{ run as {name} }} from "./{name}.js";')

open(f"{out}/src/jobs/index.js", "w").write("\n".join(index_lines) + "\n")
open(f"{out}/test/jobs.test.js", "w").write('''import { test } from "node:test";
import assert from "node:assert/strict";
import { setSink, oldLog } from "../src/log.js";
import * as jobs from "../src/jobs/index.js";

test("every job returns a number and logs a start line", () => {
  const seen = [];
  setSink((level, msg) => seen.push([level, msg]));
  for (const [name, run] of Object.entries(jobs)) {
    seen.length = 0;
    assert.equal(typeof run([{ id: "a", value: 10 }]), "number");
    assert.ok(seen.some(([l, m]) => l === "info" && m.startsWith(name + ":")), name);
  }
});

test("oldLog rejects unknown levels", () => {
  assert.throws(() => oldLog("loud", "x"), /unknown log level: loud/);
});
''')
