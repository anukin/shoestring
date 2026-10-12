import unittest

from pantry import greeting


class GreetingTest(unittest.TestCase):
    def test_trim_names_and_substitute_blanks(self):
        self.assertEqual(greeting("  Sam  "), "Hello, Sam!")
        self.assertEqual(greeting("   "), "Hello, friend!")
        self.assertEqual(greeting("Jo"), "Hello, Jo!")


if __name__ == "__main__":
    unittest.main()
