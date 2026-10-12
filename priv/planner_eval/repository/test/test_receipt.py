import unittest

from pantry import receipt


class ReceiptTest(unittest.TestCase):
    def test_render_using_basket_total(self):
        self.assertEqual(receipt([]), "Total: 0 cents")
        self.assertEqual(
            receipt([
                {"price_cents": 125, "quantity": 2},
                {"price_cents": 75, "quantity": 3},
            ]),
            "Total: 475 cents",
        )


if __name__ == "__main__":
    unittest.main()
