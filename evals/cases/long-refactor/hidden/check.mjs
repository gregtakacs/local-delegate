const orig = process.argv[2];
const t = async (n, f) => { try { console.log(((await f()) ? "PASS " : "FAIL ") + n); } catch (e) { console.log(`FAIL ${n}: ${e.message}`); } };
const NEW = await import(process.cwd() + "/src/log.js").catch((e) => ({ err: e }));
if (NEW.err) { console.log("FAIL import log.js: " + NEW.err.message); process.exit(0); }
await t("log api", async () => ["debug", "info", "warn", "error"].every((k) => typeof NEW.log?.[k] === "function") && typeof NEW.setSink === "function" && !("oldLog" in NEW));
await t("unknown level throws", async () => { try { NEW.log["loud"]("x"); return false; } catch (e) { return /unknown log level: loud/.test(e.message); } });
const OLD = await import(orig + "/src/log.js");
const inputs = [[], [{ id: "a", value: 10 }], [{ id: "a", value: 10 }, { id: "b", value: 140 }, { id: "c", value: 400 }], Array.from({ length: 12 }, (_, i) => ({ id: "x" + i, value: i * 37 }))];
let same = 0, diff = [];
for (let i = 1; i <= 60; i++) {
  const name = `job_${String(i).padStart(2, "0")}`;
  let o, n;
  try { o = await import(`${orig}/src/jobs/${name}.js`); n = await import(`${process.cwd()}/src/jobs/${name}.js`); }
  catch (e) { diff.push(name + " (import: " + e.message + ")"); continue; }
  let ok = true;
  for (const lvl of ["debug", "warn"]) {
    process.env.LOG_LEVEL = lvl;
    for (const inp of inputs) {
      const a = [], b = [];
      OLD.setSink((l, m) => a.push(l + "|" + m)); NEW.setSink((l, m) => b.push(l + "|" + m));
      const ra = o.run(inp), rb = n.run(inp);
      if (ra !== rb || JSON.stringify(a) !== JSON.stringify(b)) ok = false;
    }
  }
  delete process.env.LOG_LEVEL;
  ok ? same++ : diff.push(name);
}
console.log((same === 60 ? "PASS " : "FAIL ") + `behaviour identical for ${same}/60 jobs` + (diff.length ? ": " + diff.slice(0, 8).join(", ") : ""));
