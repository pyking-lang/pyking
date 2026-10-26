# Exit status

A program ends with a status: a number its caller can read, `0` for
success and anything else for some kind of failure. `sys.exit(n)` ends
the program at once with status `n`; a program that runs to its end
ends with `0`.

```pyking readonly
import sys
print("done")
sys.exit(0)
print("never printed")
```

## Checking an age

Write a program that reads an age, a whole number, from its standard
input and

- prints `adult` and ends with status `0` for 18 or more,
- prints `minor` and ends with status `1` for 0 to 17,
- prints `invalid` and ends with status `2` for a negative number.

Both what it prints and its status are checked.

```pyking practice name = "age" stdin = "20"
import io
import sys
print("Add your code here")
```

```pyking solution available = true
import io
import sys
age = int(io.read_line())
if age < 0:
    print("invalid")
    sys.exit(2)
else:
    if age < 18:
        print("minor")
        sys.exit(1)
    else:
        print("adult")
        sys.exit(0)
```

```stdin visible = true
42
```

```stdout visible = true
adult
```

```stdin visible = true
7
```

```stdout
minor
```

```stdin
-1
```

```stdin
18
```

```stdin
17
```

```stdin
0
```

## Refusing an empty line

Write a program that reads one line. If it is empty, it ends with
status `4` and prints nothing; otherwise it prints `got: LINE` and ends
with `sys.exit(0)`.

```pyking practice name = "nonempty" stdin = "hello"
import io
import sys
print("Add your code here")
```

```pyking solution
import io
import sys
line = io.read_line()
if line == "":
    sys.exit(4)
print("got: " + line)
sys.exit(0)
```

```stdin
hello
```

```stdout
got: hello
```

```stdin
```

```stdin visible = true
two words
```
