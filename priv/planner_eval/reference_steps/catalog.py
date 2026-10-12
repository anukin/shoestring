def greeting(name):
    return "Hello, " + name + "!"


def total_cents(items):
    return len(items)


def receipt(items):
    return f"Items: {len(items)}"


def catalog(names):
    return sorted({name.strip() for name in names if name.strip()})
