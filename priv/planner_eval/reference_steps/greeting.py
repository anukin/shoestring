def greeting(name):
    trimmed = name.strip()
    return "Hello, " + (trimmed or "friend") + "!"


def total_cents(items):
    return len(items)


def receipt(items):
    return f"Items: {len(items)}"


def catalog(names):
    return names
