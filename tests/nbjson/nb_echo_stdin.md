# Reading standard input

A program reads its standard input with the `io` library.
`io.read_line()` answers the next line without its new line, and `""`
at the end of the input; `io.is_eof()` tells the end of the input from
an empty line. `io.read()` answers everything that is left at once.

```pyking readonly stdin = "first\nsecond\n"
import io
print(io.read_line())
print(io.is_eof())
print(io.read())
```

## Greeting everyone

Write a program that reads names, one per line, until the end of its
input. For each name it prints `Hello, NAME!`, and at the end it prints
how many people it greeted:

    Hello, Ada!
    Hello, Grace!
    Greeted 2 people

An empty line is a name too (an empty one), so stop only at the end of
the input.

```pyking practice name = "greet" stdin = "Ada\nGrace\n"
import io
print("Add your code here")
```

```pyking solution available = true
use mutation

import io
var count = 0
while io.is_eof() == false:
    name = io.read_line()
    print("Hello, " + name + "!")
    count := count + 1
print("Greeted", count, "people")
```

```stdin visible = true
Ada
Grace
```

```stdout visible = true
Hello, Ada!
Hello, Grace!
Greeted 2 people
```

```stdin
Alan
```

```stdout
Hello, Alan!
Greeted 1 people
```

```stdin visible = true
Barbara

Edsger
```

```stdin
```

```stdout
Greeted 0 people
```

```stdin
Donald
Ken
Dennis
Bjarne
```
