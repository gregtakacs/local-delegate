#!/bin/bash
# tests/test_permission_policy.sh — the shared-verdict guard (O1b step 3, design §7.3, §10).
# Renders the shipped policy into a temp dir, runs every case in policy/permission-cases.json
# through BOTH engines (opencode last-match, Claude deny>ask>allow), and asserts
# opencode == claude == expect. Plus translator refusals, deny-survival (§10), byte-stability,
# rule coverage, and a golden test that the opencode rendering parses under the merge script's
# own covered() (so the merge step's doctor --check will agree with the renderer).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; check(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
TR=$here/lib/translate-permissions.py
EV=$here/lib/permission-eval.py
POL=$here/policy/harness-permissions.json
CASES=$here/policy/permission-cases.json
HOME_T=/home/t
tr_(){ python3 "$TR" --policy "$1" --render "$2" --home "$HOME_T" "${@:3}"; }

# ---- render the shipped policy --------------------------------------------------------------
check "opencode render"  "tr_ '$POL' opencode > '$T/oc.json'"
check "claude render"    "tr_ '$POL' claude   > '$T/cl.json'"
check "guard render"     "tr_ '$POL' guard    > '$T/gd.json'"

# ---- acceptance criterion 2: bash first rule is "*" ask ---------------------------------------
check "opencode bash first key is *, value ask" \
  "python3 -c \"import json;d=json.load(open('\$T/oc.json'));assert list(d['bash'])[0]=='*' and d['bash']['*']=='ask'\""

# ---- parity: engine == engine == expect, for every case ---------------------------------------
python3 lib/permission-eval.py --engine opencode --config "$T/oc.json" --cases "$CASES" > "$T/oe.out" 2>"$T/oe.err"
python3 lib/permission-eval.py --engine claude   --config "$T/cl.json" --cases "$CASES" > "$T/ce.out" 2>"$T/ce.err"
check "parity: opencode==claude==expect on all cases" \
  "python3 - '$CASES' '$T/oe.out' '$T/ce.out' <<'PY'
import json,sys
cases=json.load(open(sys.argv[1]))['cases']
oe=[l.split()[1] for l in open(sys.argv[2]).read().splitlines()]
ce=[l.split()[1] for l in open(sys.argv[3]).read().splitlines()]
assert len(oe)==len(ce)==len(cases), 'line-count mismatch'
bad=[(c['tool'],c['input'],c['expect'],o,e) for c,o,e in zip(cases,oe,ce) if not (o==e==c['expect'])]
for b in bad: print('   DIVERGE',b)
sys.exit(1 if bad else 0)
PY"

# ---- the case list is data: >=30 cases, >=1 case per policy rule id (note convention) --------
check "case list has >=30 cases and every policy rule id is exercised" \
  "python3 - '$POL' '$CASES' <<'PY'
import json,sys
pol=json.load(open(sys.argv[1])); doc=json.load(open(sys.argv[2]))
cases=doc['cases']; assert len(cases)>=30, 'need >=30 cases, got %d'%len(cases)
ids={r['note'] for sec in ('bash','read','edit','external_directory','webfetch','skill','doom_loop') for r in pol.get(sec,[])}
seen={c.get('rule') for c in cases}
missing=ids-seen
assert not missing, 'rules with no case: %s'%sorted(missing)
PY"

# ---- byte-stability (no timestamps / set-order leakage) -----------------------------------------
check "re-running the translator is byte-stable (opencode)" \
  "tr_ '$POL' opencode > '$T/oc2.json' && cmp -s '$T/oc.json' '$T/oc2.json'"
check "re-running the translator is byte-stable (claude)" \
  "tr_ '$POL' claude > '$T/cl2.json' && cmp -s '$T/cl.json' '$T/cl2.json'"

# ---- .env asymmetry: same path string, different verdict per tool -----------------------------
check ".env asymmetry read==ask (both engines)" \
  "python3 '$EV' --engine opencode --config '$T/oc.json' --case '{\"tool\":\"read\",\"input\":\".env\"}' | grep -qx 'verdict ask' && python3 '$EV' --engine claude --config '$T/cl.json' --case '{\"tool\":\"read\",\"input\":\".env\"}' | grep -qx 'verdict ask'"
check ".env asymmetry edit==deny" \
  "python3 '$EV' --engine opencode --config '$T/oc.json' --case '{\"tool\":\"edit\",\"input\":\".env\"}' | grep -qx 'verdict deny' && python3 '$EV' --engine claude --config '$T/cl.json' --case '{\"tool\":\"edit\",\"input\":\".env\"}' | grep -qx 'verdict deny'"

# ---- deny survival (§10): every policy deny row present in both renderings --------------------
check "deny-survival: policy denies present in opencode+claude renderings" \
  "python3 - '$POL' '$T/oc.json' '$T/cl.json' <<'PY'
import json,sys
pol=json.load(open(sys.argv[1])); oc=json.load(open(sys.argv[2])); cl=json.load(open(sys.argv[3]))
CL={'bash':['Bash'],'read':['Read'],'edit':['Edit'],'external_directory':['Read','Edit'],'webfetch':['WebFetch']}
deny_cl=set(cl['permissions']['deny'])
for sec in ('bash','read','edit','external_directory','webfetch','skill','doom_loop'):
    for r in pol.get(sec,[]):
        if r['effect']!='deny': continue
        p=r['pattern']; abspath=('/home/t/'+p[3:]) if p.startswith('**/') else None
        assert (p in oc.get(sec,{})) or (abspath and abspath in oc.get(sec,{})), 'opencode missing deny %s/%s'%(sec,p)
        want=['%s(%s)'%(n,p) for n in CL.get(sec,[])]
        if abspath: want+=['%s(%s)'%(n,abspath) for n in CL.get(sec,[])]
        assert (sec=='webfetch' and 'WebFetch' in deny_cl) or any(w in deny_cl for w in want), 'claude missing deny %s/%s'%(sec,p)
PY"

# ---- golden: opencode rendering parses under the merge script's own covered() -----------------
check "golden: merge covered() sees a rendered deny over a broad allow" \
  "python3 - '$T/oc.json' '$here/lib' <<'PY'
import importlib.util,json,sys,os
spec=importlib.util.spec_from_file_location('m',os.path.join(sys.argv[2],'merge-opencode-permissions.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ext=json.load(open(sys.argv[1]))['external_directory']
assert m.covered(ext,'/home/t/docker/secrets/**','deny'), 'covered() disagrees with renderer on the secrets deny'
assert not m.covered(ext,'/home/t/docker/secrets/**','allow')
PY"

# ---- translator refusals (exit 1, nothing written) ---------------------------------------------
refuse(){ # NAME JSON RENDER
  local name=$1 body=$2 render=$3
  printf '%s' "$body" > "$T/bad.json"
  local out="$T/bad.out"
  tr_ "$T/bad.json" "$render" > "$out" 2>"$T/bad.err"; local rc=$?
  check "refuse: $name" "[ \$rc -eq 1 ] && [ ! -s '$out' ]"
}
refuse "allow beats earlier deny without via" \
  '{"version":1,"bash":[{"pattern":"*","effect":"ask"},{"pattern":"sudo *","effect":"deny","over":["*"]},{"pattern":"x *","effect":"allow","over":["sudo *"]}]}' opencode
refuse "unknown effect string" \
  '{"version":1,"bash":[{"pattern":"*","effect":"perhaps"}]}' opencode
refuse "empty section in a non-empty policy" \
  '{"version":1,"bash":[{"pattern":"*","effect":"ask"}],"read":[]}' opencode
refuse "deny carrying via would drop from claude arrays" \
  '{"version":1,"bash":[{"pattern":"*","effect":"ask"},{"pattern":"rm -rf /*","effect":"deny","via":"hook"}]}' claude
refuse "bash default posture must be ask" \
  '{"version":1,"bash":[{"pattern":"*","effect":"allow"}]}' opencode
refuse "over target must be an earlier rule" \
  '{"version":1,"bash":[{"pattern":"*","effect":"ask"},{"pattern":"git status *","effect":"allow","over":["nope *"]}]}' opencode

# ---- deny-first compound (a deny anywhere denies the whole line) ------------------------------
check "compound: 'git push --force && echo done' denies on both engines" \
  "python3 '$EV' --engine opencode --config '$T/oc.json' --case '{\"tool\":\"bash\",\"input\":\"git push --force && echo done\"}' | grep -qx 'verdict deny' && python3 '$EV' --engine claude --config '$T/cl.json' --case '{\"tool\":\"bash\",\"input\":\"git push --force && echo done\"}' | grep -qx 'verdict deny'"

exit $fail
