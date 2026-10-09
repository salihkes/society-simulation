#!/usr/bin/env python3
"""What a wipe takes and what it must leave.

Three things clear a world: a --clean start (paths._strip_state), the owner's
tools/run/forget.sh, and tools/deploy/bundle_server.sh packing a world for another
machine. They each used to spell out their own list, and the lists drifted: a
bundle arrived on a new machine with no memories but with the sending
machine's school halfway through an equation lesson and its clock stopped in
the afternoon — which reads exactly like a server nobody updated.

So the list lives once, in paths.CLEAN_PATTERNS, and this pins both halves of
it: everything a run writes goes, and everything that says what the city IS
stays. A file added to data/world in future is kept unless it is named here,
which is the safe direction to be wrong in.
"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core import paths


# What a run leaves behind. Every one of these must be gone afterwards.
WRITTEN = [
    "memory/r_student_01.jsonl",
    "memory/r_student_01/MEMORY.md",
    "memory/r_student_01/facts/a-day-at-school.md",
    "memory/ambient/r_student_01.jsonl",
    "memory/memory.db",
    "memory/memory.db-wal",
    "memory/memory.db-shm",
    "resident_life.json",
    "school_state.json",
    "school_state_11C.json",
    "clock_progress.json",
    "parliament_state.json",
    "parked/memory/r_onur.jsonl",
    "parked/memory/r_onur/MEMORY.md",
    "parked/resident_life.json",
    "script_leftovers.log",
    "residents.json.bak",
    "residents.json.bak3",
    "computers/resident.img",
]

# What the city IS. None of these may be touched.
DEFINED = [
    "residents.json",
    "places.json",
    "households.json",
    "school.json",
    "clock.json",
    "llm.json",
    "flags.json",
    "parliament.json",
    "computers.json",
    "cards/student_01.md",
    "lore/city.md",
    "computer_tasks/news.json",
    "parked/residents.json",
    "parked/cards/onur.md",
]


def _make_world(root: str):
    for rel in WRITTEN + DEFINED:
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write("{}" if rel.endswith(".json") else "x")


class ForgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.world = os.path.join(self.tmp.name, "world")
        os.makedirs(self.world)
        _make_world(self.world)

    def tearDown(self):
        self.tmp.cleanup()

    def test_every_written_thing_is_listed(self):
        found = {os.path.relpath(p, self.world) for p in paths.clean_targets(self.world)}
        for rel in WRITTEN:
            with self.subTest(rel=rel):
                # Either the file itself is a target, or a folder above it is.
                covered = rel in found or any(
                    rel.startswith(f + os.sep) for f in found)
                self.assertTrue(covered, f"a run writes {rel} and nothing would clear it")

    def test_no_definition_is_listed(self):
        found = {os.path.relpath(p, self.world) for p in paths.clean_targets(self.world)}
        for rel in DEFINED:
            with self.subTest(rel=rel):
                covered = rel in found or any(
                    rel.startswith(f + os.sep) for f in found)
                self.assertFalse(covered, f"{rel} says what the city is and must survive a wipe")

    def test_strip_leaves_the_city_and_its_folders(self):
        paths._strip_state(self.world)
        for rel in WRITTEN:
            self.assertFalse(os.path.exists(os.path.join(self.world, rel)),
                             f"{rel} survived the wipe")
        for rel in DEFINED:
            self.assertTrue(os.path.exists(os.path.join(self.world, rel)),
                            f"{rel} was lost in the wipe")
        # The folders stay: everything that writes into them expects them.
        self.assertTrue(os.path.isdir(os.path.join(self.world, "memory")))
        self.assertTrue(os.path.isdir(os.path.join(self.world, "parked", "memory")))

    def test_a_second_wipe_is_harmless(self):
        paths._strip_state(self.world)
        paths._strip_state(self.world)
        self.assertEqual(paths.clean_targets(self.world), [])

    def test_no_parked_folder_is_not_invented(self):
        """A world without parked residents does not grow a parked/ folder."""
        import shutil
        shutil.rmtree(os.path.join(self.world, "parked"))
        paths._strip_state(self.world)
        self.assertFalse(os.path.exists(os.path.join(self.world, "parked")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
