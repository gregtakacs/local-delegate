import pg from "pg";
let S;
try { S = await import(process.cwd() + "/src/store.js"); } catch (e) { console.log("FAIL import: " + e.message); process.exit(0); }
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const t = async (name, f) => { try { console.log(((await f()) ? "PASS " : "FAIL ") + name); } catch (e) { console.log(`FAIL ${name}: ${e.message}`); } };
await pool.query("drop table if exists handle, _migrations cascade");
await t("migrate fresh", async () => { await S.migrate(pool); return true; });
await t("migrate idempotent", async () => { await S.migrate(pool); const r = await pool.query("select count(*)::int n from _migrations"); return r.rows[0].n === 1; });
await t("partial unique index", async () => (await pool.query("select indexdef from pg_indexes where tablename='handle'")).rows.some(r => /UNIQUE/.test(r.indexdef) && /retired_at IS NULL/i.test(r.indexdef)));
const u = "u" + Date.now(), v = "v" + Date.now(), h1 = "h1" + Date.now(), h2 = "h2" + Date.now();
await t("claim ok", async () => JSON.stringify(await S.claimHandle(pool, u, h1)) === '{"ok":true}');
await t("taken", async () => (await S.claimHandle(pool, v, h1)).error === "taken");
await t("user_has_handle", async () => (await S.claimHandle(pool, u, h2)).error === "user_has_handle");
await t("currentHandle", async () => (await S.currentHandle(pool, u)) === h1 && (await S.currentHandle(pool, "nobody")) === null);
await t("retire true then false", async () => (await S.retireHandle(pool, h1)) === true && (await S.retireHandle(pool, h1)) === false);
await t("after retire: new claim ok, old stays taken", async () => (await S.claimHandle(pool, u, h2)).ok === true && (await S.claimHandle(pool, v, h1)).error === "taken");
await t("currentHandle after retire", async () => (await S.currentHandle(pool, u)) === h2);
await t("concurrent claims: exactly one wins", async () => {
  const h = "race" + Date.now();
  const rs = await Promise.all(Array.from({ length: 8 }, (_, i) => S.claimHandle(pool, "r" + i + Date.now(), h)));
  return rs.filter(r => r.ok).length === 1 && rs.filter(r => r.error === "taken").length === 7;
});
await pool.end();
