#!/usr/bin/env python3
"""Run isolated Godot regional weather checks without game/network autoloads.

python3 tools/dev/check_regional_weather.py
python3 tools/dev/check_regional_weather.py --render --renderer mobile
Set GODOT to override the executable. Import the main Godot project first so
its existing texture/audio import cache is available to the isolated project.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--render", action="store_true", help="also run the GPU test (opens a window)")
    parser.add_argument("--renderer", default="gl_compatibility", choices=("gl_compatibility", "mobile", "forward_plus"))
    args = parser.parse_args()
    godot = os.environ.get("GODOT") or shutil.which("godot") or "/Applications/Godot.app/Contents/MacOS/Godot"
    source = ROOT / "client"
    with tempfile.TemporaryDirectory(prefix="regional-weather-") as temporary:
        project = Path(temporary).resolve()
        # Godot resolves custom_user_dir_name relative to the OS application
        # data directory. Keep test writes in the temporary project on macOS.
        custom = ""
        if sys.platform == "darwin":
            relative = os.path.relpath(project / "user", Path.home() / "Library/Application Support")
            custom = 'config/use_custom_user_dir=true\nconfig/custom_user_dir_name=' + json.dumps(relative) + '\n'
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="RegionalWeatherChecks"\n' + custom +
            '[rendering]\nrenderer/rendering_method=' + json.dumps(args.renderer) + '\n')
        for name in ("src", "assets", "tools", "tests"):
            (project / name).symlink_to(source / name, target_is_directory=True)
        (project / ".godot").mkdir()
        (project / ".godot/imported").symlink_to(source / ".godot/imported", target_is_directory=True)
        tests = [(name, True) for name in ("test_regional_weather", "test_weather_sync", "test_snow")]
        if args.render:
            tests.append(("test_regional_water_render", False))
        for name, headless in tests:
            command = [godot, "--xr-mode", "off", "--path", str(project), "--log-file", str(project / (name + ".log")),
                       "--rendering-method", args.renderer, "--script", "res://tests/" + name + ".gd"]
            if headless:
                command.append("--headless")
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            if result.returncode or any(error in output for error in
                                        ("SCRIPT ERROR", "Parse Error", "Compile Error", "Shader compilation failed", "FAIL:")):
                raise SystemExit(output)
            print(name + ": PASS")
        if args.render:
            print("Render images: /tmp/regional-water-clear.png and /tmp/regional-water-frozen.png")


if __name__ == "__main__":
    main()
