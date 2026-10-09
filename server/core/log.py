#!/usr/bin/env python
"""Tees everything the server prints to data/logs/latest.log, archiving the previous one as <date>-N.log."""

import datetime
import os
import sys
import threading

from core import paths

LOG_DIR = paths.logs()
LATEST = paths.logs("latest.log")

_installed = False
_lock = threading.Lock()


class _Tee:
    """A stdout replacement writing to the console, the log file and optionally a GUI queue."""

    def __init__(self, mirror, fh, gui_queue=None):
        self._mirror = mirror      # original stdout, or None (e.g. pythonw)
        self._fh = fh              # open log file handle, or None
        self._queue = gui_queue    # queue.Queue for the GUI, or None
        self._at_line_start = True

    def write(self, text):
        """Write to every target; a failing console never stops the rest."""
        if not text:
            return 0
        if self._mirror is not None:
            try:
                self._mirror.write(text)
            except Exception:
                pass
        if self._queue is not None:
            self._queue.put(text)
        self._write_file(text)
        return len(text)

    def _write_file(self, text):
        """Append to the log file, stamping each line that starts here."""
        if self._fh is None:
            return
        try:
            with _lock:
                self._write_lines(text)
        except Exception:
            pass

    def _write_lines(self, text):
        stamp = datetime.datetime.now().strftime("[%H:%M:%S] ")
        for line in text.splitlines(keepends=True):
            if self._at_line_start:
                self._fh.write(stamp)
            self._fh.write(line)
            self._at_line_start = line.endswith("\n")
        self._fh.flush()

    def flush(self):
        if self._mirror is not None:
            try:
                self._mirror.flush()
            except Exception:
                pass


def _archive_previous():
    """Rename a non-empty latest.log to <date>-N.log before reopening."""
    try:
        if not os.path.exists(LATEST) or os.path.getsize(LATEST) == 0:
            return
        mtime = datetime.datetime.fromtimestamp(os.path.getmtime(LATEST))
        base = mtime.strftime("%Y-%m-%d")
        n = 1
        while os.path.exists(paths.logs(f"{base}-{n}.log")):
            n += 1
        os.rename(LATEST, paths.logs(f"{base}-{n}.log"))
    except Exception:
        pass  # logging setup must never stop the server from starting


def install(gui_queue=None, mirror=True):
    """Send stdout and stderr through the tee; a second call only sets the GUI queue."""
    global _installed
    os.makedirs(LOG_DIR, exist_ok=True)

    if _installed and isinstance(sys.stdout, _Tee):
        if gui_queue is not None:
            sys.stdout._queue = gui_queue
        return sys.stdout

    _archive_previous()
    try:
        fh = open(LATEST, "a", encoding="utf-8")
    except Exception:
        fh = None

    mirror_stream = sys.__stdout__ if mirror else None
    tee = _Tee(mirror_stream, fh, gui_queue)
    sys.stdout = tee
    sys.stderr = tee
    _installed = True
    print(f"[LOG] Writing server log to {LATEST}")
    return tee
