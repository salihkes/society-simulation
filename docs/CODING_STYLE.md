# Coding style

The rules of the Linux kernel coding style, applied to GDScript and Python.
The kernel's own text is in this folder, unmodified, as
[kernel-coding-style.rst](kernel-coding-style.rst) (v4.10, GPL-2.0; see
kernel-coding-style.COPYING). Read it rather than recalling it. Each language
keeps its own format: GDScript uses tabs and the Godot style guide, and Python
uses 4 spaces and PEP 8. What carries over from the kernel is everything else.

## Layout

```
client/          Godot project
  src/<module>/  code only: .gd, .gdshader and .gdshaderinc
  assets/        everything that is not code: scenes, models, textures,
                 sounds, JSON content (the user's world; gitignored)
  data/          personal values (identity.json, gitignored; identity.example.json
                 is the shipped template); code never spells them out
  addons/        engine plugins
  tools/         editor and pack scripts; tools/world/ holds tools for one
                 particular world (gitignored)
  tests/         the client tests (test_*.gd), their stubs and wrappers
  tests/world/   tests of one particular world (gitignored, kept locally)
server/          Python server
  config/        personal values (gitignored; *.example.* are the templates)
  data/          runtime state (gitignored)
  assets/        the world's server content (gitignored)
  mind/          the residents' minds
  tests/
web/             the website pages (ui/) and the game's web build (play/)
protocol/        the message contract between client and server
tools/           scripts, grouped by purpose
  run/           launchers (up.sh, city.sh, studio.sh, mindctl.py ...)
  bake/          region and data bakes (regionforge)
  art/           model and art pipelines (blender, roblox)
  deploy/        server bundle, iPad build
  media/         channel, video and voice tools
  dev/           check.sh, lint.sh and other checks
  tests/         tests of the launchers and the web build
docs/            these rules and the kernel coding style they apply
```

Code and data never mix. A name, domain, key, place or path that belongs to
one deployment lives in a data file and is read through `Identity` (client)
or `identity` (server). Code names stay generic. The owner's name, the
conlang's name and place names never appear as identifiers, keys or file
names, only as values in data.

## Functions

- A function does one thing. If you need "and" to describe it, split it.
- At most 3 levels of indentation inside a function. Deeper nesting means
  the function needs splitting, or an early `return` / `continue`.
- About 50 lines at most. A longer function is acceptable only when it is a
  flat sequence of simple cases (a `match` over message types, for example).
- At most 5 to 10 local variables. Past that, the function is doing too much.
- Exit early on errors instead of wrapping the normal path in conditions.

## Naming

- Descriptive names for anything shared (classes, autoloads, public
  functions, module constants). Short names for locals (`i`, `n`, `tmp`).
- snake_case for files, functions and variables; PascalCase for classes and
  autoloads; UPPER_CASE for constants.
- No encoding of type in the name.

## Comments

Minimal comments. The default is no comment: clear names and short functions
explain the code. A comment is the exception, written only when the code
cannot say it. When there is one, it says **what** or **why**, never **how**.

- Every file starts with a one-line header saying what it is for.
- A function gets a comment only when its name and parameters cannot tell a
  caller something they must know (a side effect, a unit, a precondition).
  One line. If a function needs a paragraph, rename or split it instead.
- Inside a function, comment only something surprising, and then only why.
- Never comment the obvious: no comment that repeats the name or the code.
- No history: no "used to", "was changed", "the old system", "we tried",
  dates, incident stories, or who asked for what. Git holds history.
- No commented-out code. Delete it.
- A comment that disagrees with the code is a bug. The code is
  authoritative: fix or delete the comment. Never "fix" the code to match a
  comment without evidence (a test, the owner).
- Do not cross-reference long documents for basic behaviour. If the reader
  needs it to understand the function, say it in one line.

## General

- Line length about 100 columns.
- No dead code: functions, constants and files nothing calls are deleted.
- No duplicated code: two copies become one function.
- No magic numbers repeated in several places: name them once.
- Print and log messages stay short and factual.
