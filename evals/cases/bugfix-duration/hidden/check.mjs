let D; try { D = await import(process.cwd() + "/src/duration.js"); } catch (e) { console.log("FAIL import: " + e.message); process.exit(0); }
const t = (n, f) => { try { console.log((f() ? "PASS " : "FAIL ") + n); } catch (e) { console.log(`FAIL ${n}: ${e.message}`); } };
const f = D.formatDuration, p = D.parseDuration;
t("#41 singular", () => f(60000) === "1 minute" && f(3600000) === "1 hour" && f(1000) === "1 second");
t("#42 truncate", () => f(95000) === "1 minute, 35 seconds" && f(119999) === "1 minute, 59 seconds");
t("#43 largest=2", () => f(90061000) === "1 day, 1 hour" && f(90061000, { largest: 4 }) === "1 day, 1 hour, 1 minute, 1 second" && f(90061000, { largest: 1 }) === "1 day");
t("#44 negative", () => f(-5000) === "-5 seconds" && f(-65000) === "-1 minute, 5 seconds");
t("#44 sub-second", () => f(500) === "0 seconds" && f(0) === "0 seconds");
t("#45 whitespace/case", () => p(" 5s") === 5000 && p("5S") === 5000 && p("2H ") === 7200000);
t("#45 still rejects", () => p("1.5h") === null && p("abc") === null && p("") === null);
t("unchanged: format", () => f(125000) === "2 minutes, 5 seconds" && f(7200000) === "2 hours");
t("unchanged: parse", () => p("90s") === 90000 && p("250ms") === 250 && p("3d") === 259200000);
