def greeting(name):
    return "Hello, " + name + "!"


def total_cents(items):
    return sum(item["price_cents"] * item["quantity"] for item in items)


def receipt(items):
    return f"Total: {total_cents(items)} cents"


def catalog(names):
    return names
