"""Converts generated speech into the world's written script with the external SCRIPT_CONVERTER."""
import asyncio
import os
import re
import time

from core import identity

CONVERTER = os.environ.get("SCRIPT_CONVERTER", identity.get("script_converter"))
LEFTOVER_LOG = "script_leftovers.log"
LEFTOVER = re.compile(r"⟨([^⟩]*)⟩")
# Spoken form -> written form for names the converter spells phonetically.
WRITTEN = identity.get("script_written_forms")


def written(text: str) -> str:
    for w, r in WRITTEN.items():
        text = text.replace(w, r)
    return text


class Script:
    """Runs the converter, caching results per input line."""

    def __init__(self, log_dir: str):
        self.log_path = os.path.join(log_dir, LEFTOVER_LOG)
        self.available = os.path.exists(CONVERTER)
        self._cache: dict = {}
        if not self.available:
            print(f"[Script] converter not found at {CONVERTER}; bubbles show the spoken text")

    async def convert(self, spoken: str) -> tuple:
        """Return (written_text, leftovers); empty text on failure."""
        if not self.available or not spoken.strip():
            return "", []
        if spoken in self._cache:
            return self._cache[spoken]
        try:
            proc = await asyncio.create_subprocess_exec(
                CONVERTER, spoken,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(proc.communicate(), timeout=120)
        except Exception as e:
            print(f"[Script] convert failed: {e}")
            return "", []
        text = out.decode("utf-8", "replace").strip()
        if proc.returncode != 0 or not text:
            print(f"[Script] rc={proc.returncode}: {err.decode('utf-8', 'replace')[:200]}")
            return "", []
        text = written(text)
        leftovers = LEFTOVER.findall(text)
        result = (text, leftovers)
        self._cache[spoken] = result
        return result

    def strip_leftovers(self, text: str, leftovers: list, source: str) -> str:
        """Log any leftovers with their source and return text unwrapped."""
        if leftovers:
            try:
                with open(self.log_path, "a", encoding="utf-8") as f:
                    f.write(f"{time.strftime('%Y-%m-%d %H:%M')}\t{source}\t{'|'.join(leftovers)}\n")
            except OSError:
                pass
        return LEFTOVER.sub(r"\1", text)
