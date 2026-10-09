#!/usr/bin/env python3
"""What the city remembered — read straight off a run folder, no server needed.

    tools/run/oneday.sh report          (this, against the newest run)
    tools/run/oneday_report.py --world server/data/runs/latest
    tools/run/oneday_report.py --world <run> --who r_student_05 --full

Answers the question the memory system could never answer before: of
everything that happened today, what does anyone actually remember?
"""
import argparse
import json
import os
import sqlite3
import sys
import time


def clock_now(world):
    """The game hour this run is at, from its own clock config."""
    try:
        cfg = json.load(open(os.path.join(world, "clock.json")))
    except Exception:
        return None
    if cfg.get("mode") != "scaled":
        return f"mode={cfg.get('mode', 'real')}"
    try:
        st = os.stat(os.path.join(world, "clock.json")).st_mtime
    except OSError:
        return None
    elapsed = (time.time() - st) * float(cfg.get("rate", 60)) / 3600.0
    h = (float(cfg.get("hour", 6.0)) + elapsed) % 24.0
    day = int((float(cfg.get("hour", 6.0)) + elapsed) // 24.0)
    return f"{int(h):02d}:{int((h % 1) * 60):02d}" + (f" (+{day}d)" if day else "")


def facts_of(mem, who):
    d = os.path.join(mem, who, "facts")
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted(os.listdir(d)):
        if not f.endswith(".md") or f.startswith("._"):
            continue
        path = os.path.join(d, f)
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        out.append((f[:-3], os.path.getmtime(path), text))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--world", required=True, help="a run folder (data/runs/latest)")
    ap.add_argument("--who", help="one resident")
    ap.add_argument("--brief", action="store_true", help="one screen, for watching")
    ap.add_argument("--full", action="store_true", help="print the memories themselves")
    a = ap.parse_args()

    world = os.path.realpath(a.world)
    mem = os.path.join(world, "memory")
    if not os.path.isdir(mem):
        sys.exit(f"no memory folder in {world}")

    hour = clock_now(world)
    print(f"\n── {os.path.basename(world)} — the city clock reads {hour or '?'} "
          f"{'─' * max(0, 30 - len(str(hour)))}")

    residents = sorted(f[:-6] for f in os.listdir(mem)
                       if f.endswith(".jsonl") and f.startswith("r_"))
    if a.who:
        residents = [w for w in residents if w == a.who or w == "r_" + a.who]

    db = None
    try:
        db = sqlite3.connect(os.path.join(mem, "memory.db"))
        db.row_factory = sqlite3.Row
    except Exception:
        pass

    total_raw = total_facts = 0
    rows = []
    for who in residents:
        try:
            raw = sum(1 for _ in open(os.path.join(mem, who + ".jsonl"), encoding="utf-8"))
        except OSError:
            raw = 0
        fs = facts_of(mem, who)
        total_raw += raw
        total_facts += len(fs)
        newest = max((m for _, m, _ in fs), default=0)
        rows.append((who, raw, len(fs), newest))

    rows.sort(key=lambda r: (-r[2], -r[1]))
    print(f"{'resident':24s} {'raw':>8s} {'memories':>9s}   newest")
    for who, raw, n, newest in rows[: 12 if a.brief else 100]:
        when = time.strftime("%H:%M:%S", time.localtime(newest)) if newest else "—"
        mark = "  ←" if n else ""
        print(f"{who:24s} {raw:8d} {n:9d}   {when}{mark}")
    print(f"{'TOTAL':24s} {total_raw:8d} {total_facts:9d}")

    if db is not None:
        try:
            runs = db.execute("SELECT COUNT(*) n FROM journal WHERE action='run'").fetchone()["n"]
            harv = db.execute("SELECT COUNT(*) n FROM journal WHERE action='harvest'").fetchone()["n"]
            rel = db.execute("SELECT COUNT(*) n FROM journal WHERE action='relationship'").fetchone()["n"]
            refl = db.execute("SELECT COUNT(*) n FROM journal WHERE action='reflect'").fetchone()["n"]
            vecs = db.execute("SELECT COUNT(*) n FROM vectors").fetchone()["n"]
            print(f"\nconsolidation runs {runs} · facts harvested {harv} · "
                  f"relationship notes {rel} · insights {refl} · vectors {vecs}"
                  + ("" if vecs else "   (dense lane off: no embedding model served)"))
            passed = 0
            for r in db.execute("SELECT detail FROM journal WHERE action='run'"):
                try:
                    passed += json.loads(r["detail"]).get("passed_over", 0)
                except Exception:
                    pass
            if passed:
                print(f"records passed over as nothing-happened: {passed}")
        except Exception as e:
            print(f"(journal unreadable: {e})")

    if a.brief:
        return

    print("\n── what they remember " + "─" * 46)
    shown = 0
    for who, raw, n, newest in rows:
        fs = facts_of(mem, who)
        if not fs:
            continue
        print(f"\n{who}:")
        for name, mtime, text in sorted(fs, key=lambda f: -f[1])[: 20 if a.full else 3]:
            body = text.split("---", 2)[-1].strip() if text.startswith("---") else text.strip()
            desc = ""
            for line in text.splitlines():
                if line.startswith("description:"):
                    desc = line.split(":", 1)[1].strip().strip('"\'')
                    break
            print(f"  · {name} — {desc}")
            if a.full:
                for l in body.splitlines():
                    if l.strip():
                        print(f"      {l}")
        shown += 1
        if not a.full and shown >= 10:
            print(f"\n  … and {len([r for r in rows if r[2]]) - shown} more with memories "
                  f"(--full, or --who <id>)")
            break
    if not shown:
        print("  nothing yet. If the city has not reached 03:00 the sleep has not run;")
        print("  a harvest also runs by day once someone has had enough happen to them.")


if __name__ == "__main__":
    main()
