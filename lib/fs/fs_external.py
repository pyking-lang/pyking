# The Python implementation of the Pyking module declared in
# fs_external.pyk. Text is read and written as UTF-8 on every target,
# so one program moves the same bytes whichever one compiled it.


def read_text(filename):
    with open(filename, "r", encoding="utf-8") as handle:
        return handle.read()


def write_text(filename, text):
    with open(filename, "w", encoding="utf-8") as handle:
        handle.write(text)


def exists(filename):
    import os.path

    return os.path.isfile(filename)
