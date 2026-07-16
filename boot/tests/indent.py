def foo(x):
    if x < 1:
        # nested comment, should not affect indentation
        return x

    return x + 1

def bar(x):
    return x
