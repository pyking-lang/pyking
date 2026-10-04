# The Python implementation of the names declared in time_external.pyk.
# Decomposition is UTC: `gmtime`, never `localtime`.

import time as _time


def instant():
    return int(_time.time())


def _parts(t):
    return _time.gmtime(t)


def now():
    parts = _time.gmtime(int(_time.time()))
    return (
        parts.tm_year,
        parts.tm_mon,
        parts.tm_mday,
        parts.tm_hour,
        parts.tm_min,
        parts.tm_sec,
    )


def year_of(t):
    return _parts(t).tm_year


def month_of(t):
    return _parts(t).tm_mon


def day_of(t):
    return _parts(t).tm_mday


def hour_of(t):
    return _parts(t).tm_hour


def minute_of(t):
    return _parts(t).tm_min


def second_of(t):
    return _parts(t).tm_sec
