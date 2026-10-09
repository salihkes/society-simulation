#!/usr/bin/env python3
"""Checks tools/run/city.sh actually brings the city up and takes it down.

A launcher is the one script nobody tests and everybody trusts, and its
failures are the quiet kind: Ctrl-C that leaves Godot running and holds the
port, or a crash that stops the city without stopping the server. Each case
here is one of those.

Both halves are stubs, so nothing needs the venv, the shared drive or a
40-second city boot. What is under test is the launcher, not what it starts.

    python3 tools/tests/test_city.py
"""
import os
import pty
import select
import signal
import subprocess
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CITY = os.path.join(ROOT, "tools", "run", "city.sh")
PORT = "24771"

SERVER_STUB = """#!/bin/bash
echo "stub server starting"
python3 -c "
import socket, time, os
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', int(os.environ['GAME_PORT']))); s.listen(5)
print('stub server listening', flush=True)
while True: time.sleep(0.2)
" &
PY=$!
trap 'kill $PY 2>/dev/null; exit 0' TERM INT
wait $PY
"""

WORLD_STUB = """#!/bin/bash
echo "stub world booting"
trap 'exit 0' TERM INT
touch "$WORLD_ALIVE"
while true; do sleep 0.2; done
"""


def stubs(tmp):
    paths = {}
    for name, body in (("server_stub.sh", SERVER_STUB), ("world_stub.sh", WORLD_STUB)):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)
        paths[name] = p
    return paths


def running(pattern):
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True).stdout
    return len(out.split())


class CityLauncher:
    """tools/run/city.sh on a real terminal, so Ctrl-C means what it means."""

    def __init__(self, tmp, args=()):
        s = stubs(tmp)
        self.env = dict(
            os.environ,
            GAME_PORT=PORT,
            GAME_RESTART_DELAY="1",
            SERVER_CMD=s["server_stub.sh"],
            WORLD_CMD=s["world_stub.sh"],
            WORLD_ALIVE=os.path.join(tmp, "world.alive"),
        )
        self.args = list(args)
        self.out = b""
        self.pid = None
        self.fd = None

    def start(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(ROOT)
            os.execvpe("bash", ["bash", CITY] + self.args, self.env)
        return self

    def pump(self, seconds=0.3):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 4096)
            except OSError:
                return
            if not chunk:
                return
            self.out += chunk

    def wait_for(self, text, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            if text.encode() in self.out:
                return True
            self.pump(0.2)
        return text.encode() in self.out

    def ctrl_c(self):
        os.write(self.fd, b"\x03")

    def text(self):
        return self.out.decode(errors="replace").replace("\r\n", "\n")

    def wait_exit(self, timeout=25):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.2)
            try:
                wpid, _ = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return True
            if wpid == self.pid:
                return True
        return False

    def kill(self):
        for pat in (CITY, "_stub.sh", "GAME_PORT"):
            subprocess.run(["pkill", "-f", pat], capture_output=True)
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except Exception:
            pass


class CityTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp(prefix="citytest")
        subprocess.run(["pkill", "-f", "_stub.sh"], capture_output=True)
        time.sleep(0.3)
        self.city = None

    def tearDown(self):
        if self.city:
            self.city.kill()
        subprocess.run(["pkill", "-f", "_stub.sh"], capture_output=True)
        time.sleep(0.3)

    def bring_up(self, args=()):
        self.city = CityLauncher(self.tmp, args).start()
        self.assertTrue(self.city.wait_for("the city is up"),
                        "the city never came up:\n" + self.city.text())
        return self.city

    def assertNothingLeft(self, city):
        city.pump(0.5)
        self.assertEqual(running("_stub.sh"), 0, "a half was left running:\n" + city.text())
        self.assertEqual(running("GAME_PORT"), 0, "the port is still held:\n" + city.text())

    # ── the order it comes up in ────────────────────────────────────────
    def test_waits_for_server_before_starting_the_world(self):
        city = self.bring_up()
        text = city.text()
        self.assertLess(text.index("the server is listening"), text.index("starting the world"),
                        "the world was started before the server was listening")
        self.assertEqual(running("_stub.sh"), 2, "both halves should be running")

    # ── Ctrl-C, the thing people actually do ────────────────────────────
    def test_ctrl_c_stops_both(self):
        city = self.bring_up()
        city.ctrl_c()
        self.assertTrue(city.wait_exit(), "city.sh did not exit after Ctrl-C:\n" + city.text())
        self.assertIn("stopping", city.text())
        self.assertNothingLeft(city)

    # ── SIGTERM, the thing systemd/launchd does ─────────────────────────
    def test_sigterm_stops_both(self):
        city = self.bring_up()
        os.kill(city.pid, signal.SIGTERM)
        self.assertTrue(city.wait_exit(), "city.sh did not exit on SIGTERM:\n" + city.text())
        self.assertNothingLeft(city)

    # ── a half falling over ─────────────────────────────────────────────
    def test_a_crashed_world_comes_back(self):
        city = self.bring_up()
        subprocess.run(["pkill", "-f", "world_stub.sh"], capture_output=True)
        self.assertTrue(city.wait_for("world exited", timeout=15),
                        "the launcher never noticed the world die:\n" + city.text())
        self.assertTrue(city.wait_for("stub world booting", timeout=20),
                        "the world was not restarted:\n" + city.text())
        # ...and the server was left alone through all of it.
        self.assertEqual(running("server_stub.sh"), 1, "the server should not have been touched")

    def test_once_stops_the_city_when_a_half_goes(self):
        city = self.bring_up(["--once"])
        subprocess.run(["pkill", "-f", "world_stub.sh"], capture_output=True)
        self.assertTrue(city.wait_exit(timeout=25),
                        "--once should have stopped the city:\n" + city.text())
        self.assertNotIn("restarting in", city.text())
        self.assertNothingLeft(city)

    # ── refusing to make a mess ─────────────────────────────────────────
    def test_refuses_when_the_port_is_already_taken(self):
        city = self.bring_up()
        second = CityLauncher(self.tmp).start()
        self.assertTrue(second.wait_exit(timeout=15), "the second launcher hung instead of refusing")
        self.assertIn("already listening", second.text())
        # The first city must be entirely unharmed by the refusal.
        city.pump(0.5)
        self.assertEqual(running("_stub.sh"), 2, "refusing hurt the running city:\n" + city.text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
