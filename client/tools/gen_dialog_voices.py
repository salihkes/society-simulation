#!/usr/bin/env python3
"""Generate NPC dialog voice clips from the dialog registry.

Reads src/entities/ambient/dialog/dialogs.json:
  - voice_designs: voice folder -> {instruct, ref_text}. If the folder has no
    _voice_ref.wav yet, the voice identity is DESIGNED once from instruct;
    the ref is saved and must never be deleted (it is the person's voice).
  - casts: voice folder -> line ids that voice needs. Only MISSING clips are
    generated (voice-cloned from that voice's ref), so re-running after
    adding lines to the registry is cheap and never changes existing audio.

Run with the OmniVoice-MLX venv:
  cd ~/Documents/sources/OmniVoice-MLX && ./.venv/bin/python \
      <repo>/client/tools/gen_dialog_voices.py
"""
import json
import os

import numpy as np
import soundfile as sf
import torch

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(ROOT, "src/entities/ambient/dialog/dialogs.json")
VOICES = os.path.join(ROOT, "src/art/sound/voices")
MODEL = os.path.expanduser("~/Documents/models/tts/OmniVoice")

with open(REGISTRY) as f:
    reg = json.load(f)

todo = []  # (voice, line_id, reading)
missing_refs = []
for voice, line_ids in reg.get("casts", {}).items():
    vdir = os.path.join(VOICES, voice)
    os.makedirs(vdir, exist_ok=True)
    if not os.path.exists(os.path.join(vdir, "_voice_ref.wav")):
        missing_refs.append(voice)
    for lid in line_ids:
        if not os.path.exists(os.path.join(vdir, lid + ".wav")):
            line = reg["lines"].get(lid)
            if line is None:
                print("!! cast references unknown line:", lid)
                continue
            todo.append((voice, lid, line["read"]))

if not todo and not missing_refs:
    print("nothing to do — every cast clip exists")
    raise SystemExit(0)
print(f"{len(todo)} clips to generate; {len(missing_refs)} voices to design")

from omnivoice.mlx import OmniVoiceMLX

print("loading model...", flush=True)
model = OmniVoiceMLX.from_pretrained(MODEL, dtype="float16")
sr = model.sampling_rate

prompts = {}


def prompt_for(voice):
    if voice in prompts:
        return prompts[voice]
    vdir = os.path.join(VOICES, voice)
    ref_path = os.path.join(vdir, "_voice_ref.wav")
    design = reg.get("voice_designs", {}).get(voice, {})
    ref_text = design.get("ref_text", "")
    if not os.path.exists(ref_path):
        instruct = design.get("instruct")
        if not instruct or not ref_text:
            raise SystemExit(f"voice '{voice}' has no ref and no voice_design entry")
        print(f"designing voice '{voice}' ({instruct})...", flush=True)
        ref = model.generate(text=ref_text, language="ja", instruct=instruct)[0]
        sf.write(ref_path, ref, sr)
    wav, ref_sr = sf.read(ref_path, dtype="float32")
    prompts[voice] = model.create_voice_clone_prompt(
        (torch.from_numpy(np.asarray(wav))[None, :], ref_sr),
        ref_text=ref_text or None,
    )
    return prompts[voice]


for voice, lid, reading in todo:
    print("gen", voice, lid, reading, flush=True)
    audio = model.generate(text=reading, language="ja", voice_clone_prompt=prompt_for(voice))[0]
    sf.write(os.path.join(VOICES, voice, lid + ".wav"), audio, sr)

print("done", flush=True)
