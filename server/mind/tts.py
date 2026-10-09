"""TTS for generated lines through a persistent OmniVoice worker; synth() returns "" when anything is missing."""
import asyncio
import json
import os

from core import identity
from .regions import GAME

# Written form -> spoken form for names TTS must read phonetically.
SPOKEN = identity.get("script_spoken_forms")

HERE = os.path.dirname(os.path.abspath(__file__))
OMNIVOICE_PY = os.path.expanduser(os.environ.get("OMNIVOICE_PY", "~/Documents/sources/OmniVoice-MLX/.venv/bin/python"))
OMNIVOICE_MODEL = os.path.expanduser(os.environ.get("OMNIVOICE_MODEL", "~/Documents/models/tts/OmniVoice"))
VOICES = os.path.join(GAME, "assets", "art", "sound", "voices")
REGISTRY = os.path.join(GAME, "assets", "entities", "ambient", "dialog", "dialogs.json")
WORKER = os.path.join(HERE, "tts_worker.py")


def spoken(text: str) -> str:
    for w, r in SPOKEN.items():
        text = text.replace(w, r)
    return text


class TTS:
    """Owns the worker process and serialises requests to it."""

    def __init__(self):
        self.available = all(os.path.exists(p) for p in (OMNIVOICE_PY, OMNIVOICE_MODEL, VOICES, REGISTRY))
        if not self.available:
            print(f"[TTS] Omnivoice not configured (py={OMNIVOICE_PY} model={OMNIVOICE_MODEL}); text-only bubbles")
        self._proc = None
        self._lock = asyncio.Lock()
        self._next = 1

    def _kill(self):
        if self._proc is not None and self._proc.returncode is None:
            self._proc.kill()
        self._proc = None

    async def _start(self) -> bool:
        """Start the worker if needed and wait for its ready line."""
        if self._proc is not None and self._proc.returncode is None:
            return True
        try:
            self._proc = await asyncio.create_subprocess_exec(
                OMNIVOICE_PY, WORKER, OMNIVOICE_MODEL, VOICES, REGISTRY,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, limit=64 * 1024 * 1024)   # a WAV line is big
            line = await asyncio.wait_for(self._proc.stdout.readline(), timeout=300)
            hello = json.loads(line.decode("utf-8", "replace") or "{}")
            if not hello.get("ready"):
                raise RuntimeError(f"worker did not report ready: {line[:100]!r}")
            print(f"[TTS] Omnivoice worker ready ({hello.get('sr')} Hz)")
            return True
        except asyncio.CancelledError:
            self._kill()
            raise
        except Exception as e:
            print(f"[TTS] worker failed to start: {e}")
            self._proc = None
            self.available = False
            return False

    async def synth(self, voice: str, text: str) -> str:
        """Base64 16-bit WAV of text in voice, or "" when voice is unavailable."""
        text = spoken(text)
        if not self.available or not text.strip():
            return ""
        async with self._lock:
            if not await self._start():
                return ""
            rid = self._next
            self._next += 1
            try:
                self._proc.stdin.write((json.dumps({"id": rid, "voice": voice, "text": text}) + "\n").encode("utf-8"))
                await self._proc.stdin.drain()
                line = await asyncio.wait_for(self._proc.stdout.readline(), timeout=120)
                rep = json.loads(line.decode("utf-8", "replace") or "{}")
            except asyncio.CancelledError:
                # An abandoned reply would be read by the next request.
                self._kill()
                raise
            except Exception as e:
                print(f"[TTS] synth failed: {e}")
                try:
                    self._proc.kill()
                except Exception:
                    pass
                self._proc = None
                return ""
            if rep.get("error"):
                print(f"[TTS] {voice}: {rep['error'][:160]}")
                return ""
            return str(rep.get("wav_b64", ""))
