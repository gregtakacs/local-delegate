let T; try { T = await import(process.cwd() + "/tip.js"); } catch (e) { console.log("FAIL import: " + e.message); process.exit(0); }
const t = (n, f) => { try { console.log((f() ? "PASS " : "FAIL ") + n); } catch (e) { console.log(`FAIL ${n}: ${e.message}`); } };
const throws = (f) => { try { f(); return false; } catch (e) { return e instanceof RangeError; } };
t("basic", () => { const r = T.split({ bill: "100.00", tipPercent: 15, people: 2, roundUp: false }); return r.tip === 1500 && r.total === 11500 && r.perPerson === 5750; });
t("no float drift", () => T.split({ bill: "0.10", tipPercent: 10, people: 1, roundUp: false }).tip === 1);
t("roundUp", () => { const r = T.split({ bill: "84.50", tipPercent: 18, people: 3, roundUp: true }); return r.perPerson === 3400 && r.total === 10200; });
t("zero tip", () => T.split({ bill: "10", tipPercent: 0, people: 1, roundUp: false }).total === 1000);
t("bad bill", () => throws(() => T.split({ bill: "abc", tipPercent: 10, people: 1 })) && throws(() => T.split({ bill: "-5", tipPercent: 10, people: 1 })));
t("bad people", () => throws(() => T.split({ bill: "10", tipPercent: 10, people: 0 })) && throws(() => T.split({ bill: "10", tipPercent: 10, people: 1.5 })));
t("bad tip", () => throws(() => T.split({ bill: "10", tipPercent: 101, people: 1 })) && throws(() => T.split({ bill: "10", tipPercent: -1, people: 1 })));
