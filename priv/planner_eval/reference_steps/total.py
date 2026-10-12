def greeting(name):
    return "Hello, " + name + "!"


def total_cents(items):
    return sum(item["price_cents"] * item["quantity"] for item in items)


def receipt(items):
    return f"Items: {len(items)}"


def catalog(names):
    return names
