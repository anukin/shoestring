import unittest

from pantry import catalog


class CatalogTest(unittest.TestCase):
    def test_trim_remove_blanks_deduplicate_and_sort(self):
        self.assertEqual(
            catalog([" pear ", "Apple", "", "pear", "  ", "apple"]),
            ["Apple", "apple", "pear"],
        )
        self.assertEqual(catalog([]), [])


if __name__ == "__main__":
    unittest.main()
