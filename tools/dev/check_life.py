#!/usr/bin/env python3
"""Exercise life contracts without starting the city or contacting a model.

python3 tools/dev/check_life.py
GODOT=/path/to/godot python3 tools/dev/check_life.py
"""
import ast
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
GODOT = os.environ.get("GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")


def godot_check(args, log):
    proc = subprocess.run([GODOT, "--headless", "--xr-mode", "off", "--log-file", str(log), *args],
                          capture_output=True, text=True, timeout=120)
    out = proc.stdout + proc.stderr
    errors = [line for line in out.splitlines() if "SCRIPT ERROR" in line or "Parse Error" in line or "Compile Error" in line]
    if proc.returncode or errors:
        raise RuntimeError(out[-12000:])
    return out


def main():
    for name in ("life", "clock", "brain", "lesson", "tts", "__init__"):
        path = ROOT / "server/mind" / (name + ".py")
        ast.parse(path.read_text(), filename=str(path))
    subprocess.run([os.environ.get("PYTHON", "python3"), "-m", "unittest", "discover", "-s",
                    str(ROOT / "server/tests"), "-v"], check=True)
    with tempfile.TemporaryDirectory(prefix="life-check-") as tmp:
        root = Path(tmp)
        (root / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Life controller test"\n')
        for name in ("src/life/resident_life.gd", "tests/test_resident_life.gd",
                     "src/life/citizen_weather.gd",
                     "src/life/resident_schedule.gd", "tests/test_resident_schedule.gd"):
            dest = root / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "client" / name, dest)
        out = godot_check(["--path", str(root), "--script", "res://tests/test_resident_life.gd"], root / "world.log")
        if "Resident life world tests: PASS" not in out:
            raise RuntimeError(out)
        print("Physical action tests passed (isolated Godot project).")
        out = godot_check(["--path", str(root), "--script", "res://tests/test_resident_schedule.gd"], root / "schedule.log")
        if "Resident schedule tests: PASS" not in out:
            raise RuntimeError(out)
        print("Schedule tests passed (extras on the map only for their outings).")
        out = godot_check(["--path", str(ROOT / "client"), "--script", "res://tests/test_life_recovery.gd"], root / "recovery.log")
        if "Life travel recovery tests: PASS" not in out:
            raise RuntimeError(out)
        print("Life travel teleport recovery passed.")
        out = godot_check(["--path", str(ROOT / "client"), "--script", "res://tests/test_household.gd"], root / "household.log")
        if "Household tests: PASS" not in out:
            raise RuntimeError(out)
        print("Household tests passed (the furnished flat, stand-in bodies).")
        out = godot_check(["--path", str(ROOT / "client"), "--script", "res://tests/test_interior_nav.gd"], root / "interior_nav.log")
        if "Interior nav tests: PASS" not in out:
            raise RuntimeError(out)
        print("Interior nav tests passed (a built floor, a doorway, a closed room).")
        out = godot_check(["--path", str(ROOT / "client"), "--script", "res://tests/test_simple_lift.gd"], root / "lift.log")
        if "lift tests: pass" not in out.lower():
            raise RuntimeError(out)
        print("Lift tests passed (a resident's ride, a standing rider).")
        for name in ("ambient_manager", "ambient_school", "ambient_restaurant", "resident_npc", "resident_life",
                     "ambient_household", "ambient_pedestrian", "interior_nav"):
            godot_check(["--path", str(ROOT / "client"), "--script",
                f"res://assets/entities/ambient/{name}.gd", "--check-only"], root / f"{name}.log")
        godot_check(["--path", str(ROOT / "client"), "--script",
            "res://src/net/network_controller.gd", "--check-only"], root / "network.log")
        print("All changed Godot scripts passed engine parsing.")


if __name__ == "__main__":
    main()
