import unittest

from pantry import total_cents


class TotalTest(unittest.TestCase):
    def test_sum_integer_prices_with_quantities(self):
        self.assertEqual(total_cents([]), 0)
        self.assertEqual(
            total_cents([
                {"price_cents": 125, "quantity": 2},
                {"price_cents": 75, "quantity": 3},
            ]),
            475,
        )


if __name__ == "__main__":
    unittest.main()
