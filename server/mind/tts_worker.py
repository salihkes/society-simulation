#!/usr/bin/env python3
"""OmniVoice TTS worker for mind/tts.py: {"id","voice","text"} JSON per stdin line, {"id","wav_b64"|"error"} per stdout line."""
import base64
import io
import json
import os
import sys
import wave

import numpy as np
import soundfile as sf
import torch

from omnivoice.mlx import OmniVoiceMLX

MODEL_DIR, VOICES, REGISTRY = sys.argv[1], sys.argv[2], sys.argv[3]
with open(REGISTRY, encoding="utf-8") as f:
    designs = json.load(f).get("voice_designs", {})

model = OmniVoiceMLX.from_pretrained(MODEL_DIR, dtype="float16")
SR = model.sampling_rate
prompts = {}


def prompt_for(voice: str):
    """The cached voice-clone prompt for a voice, falling back to "generic"."""
    if voice in prompts:
        return prompts[voice]
    ref_path = os.path.join(VOICES, voice, "_voice_ref.wav")
    if not os.path.exists(ref_path):
        if voice != "generic":
            return prompt_for("generic")
        raise FileNotFoundError(ref_path)
    wav, ref_sr = sf.read(ref_path, dtype="float32")
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    ref_text = designs.get(voice, {}).get("ref_text", "") or None
    if not ref_text:
        txt = os.path.join(VOICES, voice, "_voice_ref.txt")
        if os.path.exists(txt):
            with open(txt, encoding="utf-8") as f:
                ref_text = f.read().strip() or None
    prompts[voice] = model.create_voice_clone_prompt(
        (torch.from_numpy(np.asarray(wav))[None, :], ref_sr), ref_text=ref_text)
    return prompts[voice]


def to_wav_b64(audio: np.ndarray) -> str:
    """Mono 16-bit WAV of audio, base64-encoded."""
    pcm = np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(SR))
        w.writeframes(pcm.tobytes())
    return base64.b64encode(buf.getvalue()).decode("ascii")


sys.stdout.write(json.dumps({"ready": True, "sr": int(SR)}) + "\n")
sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
        audio = model.generate(text=str(req.get("text", "")), language=str(req.get("language", "ja")),
                               voice_clone_prompt=prompt_for(str(req.get("voice") or "generic")))[0]
        out = {"id": req.get("id"), "wav_b64": to_wav_b64(audio)}
    except Exception as e:  # keep serving
        out = {"id": (req.get("id") if isinstance(req, dict) else None), "error": repr(e)}
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
