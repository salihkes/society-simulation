"""parse_outfit accepts bounded garment ids and nothing else."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from world.outfits import parse_outfit  # noqa: E402


class OutfitStateTests(unittest.TestCase):
    def test_normalizes_and_allows_removal(self):
        self.assertEqual(parse_outfit(['shoes', 'polo', 'pants', 'polo']),
                         ['pants', 'polo', 'shoes'])
        self.assertEqual(parse_outfit([]), [])

    def test_rejects_paths_and_unbounded_input(self):
        for value in [None, {}, 'polo', [True], ['res://body.glb'], ['../polo'], ['a' * 49],
                      ['polo'] * 13]:
            self.assertIsNone(parse_outfit(value))

    def test_future_catalog_ids(self):
        self.assertEqual(parse_outfit(['coat-blue_2']), ['coat-blue_2'])


if __name__ == "__main__":
    unittest.main()
