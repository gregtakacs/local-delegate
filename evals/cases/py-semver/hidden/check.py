import sys, dataclasses
sys.path.insert(0, ".")
def t(name, f):
    try:
        ok = f()
        print(("PASS " if ok else "FAIL ") + name)
    except Exception as e:
        print(f"FAIL {name}: {type(e).__name__}: {e}")
try:
    import semver as S
except Exception as e:
    print(f"FAIL import: {e}"); sys.exit(0)
chain = "1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0".split()
t("chain", lambda: all(S.compare(a, b) == -1 and S.compare(b, a) == 1 for a, b in zip(chain, chain[1:])))
t("equal", lambda: S.compare("1.2.3", "1.2.3") == 0)
t("build ignored", lambda: S.compare("1.0.0+abc", "1.0.0+xyz") == 0 and S.parse("1.0.0+a") == S.parse("1.0.0+b"))
t("numeric vs alpha", lambda: S.compare("1.0.0-1", "1.0.0-a") == -1)
t("numeric compare", lambda: S.compare("1.0.0-2", "1.0.0-10") == -1 and S.compare("2.0.0", "10.0.0") == -1)
bad = ["", "1", "1.0", "01.0.0", "1.01.0", "1.0.0-", "1.0.0-01", "1.0.0+", "1.0.0-a..b", "v1.0.0", " 1.0.0", "1.0.0-α", "-1.0.0"]
def all_bad():
    for b in bad:
        try:
            S.parse(b); print(f"  accepted invalid {b!r}"); return False
        except ValueError:
            pass
    return True
t("invalid rejected", all_bad)
good = ["0.0.0", "1.0.0-0A.is.legal", "1.0.0-x-y-z.--", "1.0.0+21AF26D3----117B344092BD", "1.0.0-alpha+001", "99999999999999999999.0.0"]
t("valid accepted", lambda: all(str(S.parse(g)) == g for g in good))
v = S.parse("1.2.3-rc.1+b.5")
t("fields", lambda: (v.major, v.minor, v.patch, v.prerelease, v.build) == (1, 2, 3, ("rc", 1), ("b", "5")))
t("frozen dataclass", lambda: dataclasses.is_dataclass(v) and v.__dataclass_params__.frozen)
t("ordering ops", lambda: S.parse("1.0.0-rc.1") < S.parse("1.0.0") and sorted(map(S.parse, reversed(chain))) == list(map(S.parse, chain)))
