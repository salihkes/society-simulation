# Instructions for coding assistants

This repository is a kit for building a persistent multiplayer world in Godot
with a Python server. It ships **code only**. The user's world (scenes, models,
textures, sounds, residents, regions, settings) lives in gitignored folders on
their machine and never enters git.

## If the user has no world yet

Lead them through creating one, step by step, asking what they want rather than
inventing it:
1. Copy the `*.example.*` configs to their real names and fill them in together
   (`client/data/identity.json`, `server/config/identity.json`, `roles.yaml`).
2. Create a main scene under `client/assets/` and set it as `run/main_scene` in
   `client/project.godot`.
3. Add the world's content and data step by step: regions, residents, places.
Everything they create is world content: it goes in the gitignored folders,
never in `src/`.

## Rules

- Follow [docs/CODING_STYLE.md](docs/CODING_STYLE.md). The kernel rules it
  applies are in `docs/kernel-coding-style.rst`: read them, do not recall them.
- Minimal comments. No comment by default; one line when the code cannot say it.
- Code and data never mix. Personal values (names, domains, keys, places) live in
  `identity.json` and are read through `Identity` (client) or `identity` (server).
  Identifiers, keys and file names stay generic.
- One concept per file. Use other modules' public members only; never another
  file's `_private` ones.
- Message types live in `protocol/messages.json`. Change it together with both
  sides' handlers.
- The code is authoritative. Comments and documents can be wrong; check claims
  against the code before relying on them.
- Never bring in facts from outside this repository. If something is not in the
  code or the user's words, ask.
- Measure before diagnosing: reproduce, print numbers, then name a cause.

## Before finishing any change

```sh
godot --headless --path client --import   # after adding a class_name
tools/dev/lint.sh                         # if gdtoolkit and ruff are installed
```

Never run `tools/dev/check.sh` unless the user explicitly asks for it. It takes
many minutes. To verify an edit, run only the test it touches:

```sh
godot --headless --path client --script res://tests/test_x.gd
cd server && python -m unittest tests.test_x
```

Do not commit, push, delete files or change the user's settings unless the user
asks.
