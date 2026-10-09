#!/usr/bin/env python
"""A desktop dashboard for the server (run it instead of main.py): stats, players, the log and a command box."""

import asyncio
import json
import os
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk
from tkinter.scrolledtext import ScrolledText

try:
    import psutil
    _PROC = psutil.Process(os.getpid())
except Exception:  # pragma: no cover - psutil is optional
    psutil = None
    _PROC = None

from core import identity
import main as server
from core import log
from net import state


class ServerThread(threading.Thread):
    """Runs server.main() on its own asyncio loop in a background thread."""

    def __init__(self):
        super().__init__(name="server-loop", daemon=True)
        self.loop = None
        self._ready = threading.Event()

    def run(self):
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        self._ready.set()
        try:
            self.loop.run_until_complete(server.main())
        except Exception as exc:
            print(f"[GUI] Server stopped: {exc!r}")

    def wait_until_ready(self, timeout=10.0):
        return self._ready.wait(timeout)

    def submit(self, coro):
        """Schedule a coroutine on the server loop from the UI thread."""
        if self.loop is None:
            return None
        return asyncio.run_coroutine_threadsafe(coro, self.loop)


class Dashboard:
    LOG_BG = "#FFFFFF"
    LOG_FG = "#3A4A9F"
    LOG_MAX_LINES = 5000

    def __init__(self, root, server_thread, log_queue):
        self.root = root
        self.server = server_thread
        self.log_queue = log_queue
        self.started_at = time.monotonic()

        self._lag_ms = 0.0
        self._lag_inflight = False

        root.title(f"{identity.get('product_name')} server")
        root.geometry("900x520")
        root.minsize(760, 440)

        self._build_layout()
        self._pump_log()
        self._refresh_stats()
        root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_layout(self):
        root = self.root
        root.columnconfigure(0, weight=0, minsize=300)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(0, weight=1)

        left = ttk.Frame(root, padding=6)
        left.grid(row=0, column=0, sticky="nsew")
        left.rowconfigure(0, weight=1)
        left.rowconfigure(1, weight=1)
        left.columnconfigure(0, weight=1)
        self._build_stats(left)
        self._build_players(left)
        self._build_log(root)

    def _build_stats(self, left):
        stats = ttk.LabelFrame(left, text="Stats", padding=8)
        stats.grid(row=0, column=0, sticky="nsew", pady=(0, 6))
        self.stats_var = tk.StringVar(value="Starting…")
        ttk.Label(
            stats, textvariable=self.stats_var, justify="left",
            font=("Consolas", 9),
        ).pack(anchor="nw")

    def _build_players(self, left):
        players = ttk.LabelFrame(left, text="Players", padding=4)
        players.grid(row=1, column=0, sticky="nsew")
        players.rowconfigure(0, weight=1)
        players.columnconfigure(0, weight=1)
        self.players_list = tk.Listbox(
            players, activestyle="none", font=("Consolas", 9),
            borderwidth=1, relief="solid",
        )
        self.players_list.grid(row=0, column=0, sticky="nsew")
        psb = ttk.Scrollbar(players, command=self.players_list.yview)
        psb.grid(row=0, column=1, sticky="ns")
        self.players_list.config(yscrollcommand=psb.set)

    def _build_log(self, root):
        right = ttk.LabelFrame(root, text="Log and chat", padding=6)
        right.grid(row=0, column=1, sticky="nsew", padx=(0, 6), pady=6)
        right.rowconfigure(0, weight=1)
        right.columnconfigure(0, weight=1)

        self.log = ScrolledText(
            right, wrap="word", font=("Consolas", 9),
            background=self.LOG_BG, foreground=self.LOG_FG,
            borderwidth=1, relief="solid", state="disabled",
        )
        self.log.grid(row=0, column=0, sticky="nsew")
        self.log.tag_config("warn", foreground="#B8860B")
        self.log.tag_config("error", foreground="#C0392B")

        cmd_row = ttk.Frame(right)
        cmd_row.grid(row=1, column=0, sticky="ew", pady=(6, 0))
        cmd_row.columnconfigure(0, weight=1)
        self.cmd_var = tk.StringVar()
        entry = ttk.Entry(cmd_row, textvariable=self.cmd_var)
        entry.grid(row=0, column=0, sticky="ew")
        entry.bind("<Return>", lambda _e: self._run_command())
        ttk.Button(cmd_row, text="Send", command=self._run_command).grid(
            row=0, column=1, padx=(6, 0)
        )
        entry.focus_set()

    def _append_log(self, text):
        """Append text, coloured by severity, keeping the view at the bottom if it was there."""
        self.log.config(state="normal")
        tag = None
        upper = text.upper()
        if "ERROR" in upper or "TRACEBACK" in upper or "EXCEPTION" in upper:
            tag = "error"
        elif "WARN" in upper:
            tag = "warn"
        at_bottom = self.log.yview()[1] >= 0.999
        self.log.insert("end", text, tag)
        if int(self.log.index("end-1c").split(".")[0]) > self.LOG_MAX_LINES:
            self.log.delete("1.0", "1000.end")
        if at_bottom:
            self.log.see("end")
        self.log.config(state="disabled")

    def _pump_log(self):
        """Move queued output into the log panel, every 50 ms."""
        try:
            while True:
                self._append_log(self.log_queue.get_nowait())
        except queue.Empty:
            pass
        self.root.after(50, self._pump_log)

    def _probe_lag(self):
        """Round-trip a no-op through the server loop to gauge responsiveness."""
        if self._lag_inflight or self.server.loop is None:
            return
        self._lag_inflight = True
        t0 = time.perf_counter()

        def _done(_fut):
            self._lag_ms = (time.perf_counter() - t0) * 1000.0
            self._lag_inflight = False

        try:
            fut = self.server.submit(asyncio.sleep(0))
            if fut is not None:
                fut.add_done_callback(_done)
            else:
                self._lag_inflight = False
        except Exception:
            self._lag_inflight = False

    @staticmethod
    def _memory_text():
        if _PROC is None:
            return "n/a (pip install psutil)"
        rss = _PROC.memory_info().rss / (1024 * 1024)
        try:
            free_pct = 100.0 - psutil.virtual_memory().percent
            return f"{rss:.0f} mb ({free_pct:.0f}% free)"
        except Exception:
            return f"{rss:.0f} mb"

    def _task_count(self):
        try:
            return len(asyncio.all_tasks(self.server.loop)) if self.server.loop else 0
        except Exception:
            return 0

    def _show_players(self, snapshot):
        self.players_list.delete(0, "end")
        for cid, info in snapshot:
            name = info.get("username", f"#{cid}")
            mark = "" if info.get("authenticated") else "  (guest)"
            self.players_list.insert("end", f"{name}{mark}")

    def _refresh_stats(self):
        """Update the Stats and Players panels, every second."""
        self._probe_lag()
        mem = self._memory_text()
        # The server thread mutates the client table; take a copy.
        try:
            snapshot = list(state.clients.items())
        except Exception:
            snapshot = []
        n_tasks = self._task_count()
        uptime = int(time.monotonic() - self.started_at)
        h, rem = divmod(uptime, 3600)
        m, s = divmod(rem, 60)
        self.stats_var.set(
            f"Memory use: {mem}\n"
            f"Threads: {threading.active_count()}\n"
            f"Async tasks: {n_tasks}\n"
            f"Players online: {len(snapshot)}\n"
            f"Loop lag: {self._lag_ms:.3f} ms\n"
            f"Uptime: {h:d}:{m:02d}:{s:02d}"
        )
        self._show_players(snapshot)
        self.root.after(1000, self._refresh_stats)

    def _run_command(self):
        """Run the command typed in the box: say, players, clear or help."""
        raw = self.cmd_var.get().strip()
        self.cmd_var.set("")
        if not raw:
            return
        print(f"> {raw}")

        cmd, _, arg = raw.partition(" ")
        cmd = cmd.lstrip("/").lower()
        arg = arg.strip()

        if cmd in ("say", "broadcast"):
            if arg:
                self._say(arg)
            else:
                print("[GUI] Usage: say <message>")
        elif cmd == "players":
            try:
                names = [i.get("username", f"#{c}") for c, i in state.clients.items()]
            except Exception:
                names = []
            print(f"[GUI] {len(names)} online: {', '.join(names) if names else '(none)'}")
        elif cmd == "clear":
            self.log.config(state="normal")
            self.log.delete("1.0", "end")
            self.log.config(state="disabled")
        elif cmd == "help":
            print("[GUI] Commands: say <msg>, players, clear, help")
        else:
            print(f"[GUI] Unknown command '{cmd}'. Type 'help'.")

    def _say(self, message):
        """Send a chat_message from "Server" to every connected client."""
        async def _broadcast():
            payload = json.dumps({
                "type": "chat_message",
                "player_id": 0,
                "username": "Server",
                "message": message,
            })
            sent = 0
            for _cid, client in list(state.clients.items()):
                ws = client.get("websocket")
                if ws is None:
                    continue
                try:
                    await ws.send(payload)
                    sent += 1
                except Exception:
                    pass
            print(f"[Server] {message}   (delivered to {sent})")

        self.server.submit(_broadcast())

    def _on_close(self):
        """Close the window; stopping the server's daemon thread is best effort."""
        try:
            if self.server.loop is not None:
                self.server.loop.call_soon_threadsafe(self.server.loop.stop)
        except Exception:
            pass
        self.root.destroy()


def main():
    log_queue = queue.Queue()
    log.install(gui_queue=log_queue)

    server_thread = ServerThread()
    server_thread.start()
    server_thread.wait_until_ready()

    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista")  # exists on Windows only
    except Exception:
        pass
    Dashboard(root, server_thread, log_queue)
    try:
        root.mainloop()
    finally:
        sys.stdout = sys.__stdout__
        sys.stderr = sys.__stderr__


if __name__ == "__main__":
    main()
