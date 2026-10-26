# Command-line arguments

`sys.args()` answers the words written after the program's name when it
was started, as a list of strings. A word in quotes is one argument,
spaces and all:

```pyking readonly args = "one 'two words' three"
import sys
print(sys.args())
print(len(sys.args()))
```

## Numbered arguments

Write a program that prints each of its arguments on a line of its own,
numbered from 1, then the line `separator: S` where `S` is the first
line of its standard input, and last how many arguments there were.
Started as `prog red 'light blue'` with the input `--`, it prints

    1: red
    2: light blue
    separator: --
    2 arguments

```pyking practice name = "numbered" stdin = "--" args = "red 'light blue'"
import io
import sys
print("Add your code here")
```

```pyking solution available = true
use mutation

import io
import sys
args = sys.args()
var i = 0
for word in args:
    i := i + 1
    print(string(i) + ": " + word)
print("separator: " + io.read_line())
print(len(args), "arguments")
```

```stdout visible = true
1: red
2: light blue
separator: --
2 arguments
```

```stdin args = "alpha beta gamma" visible = true
==
```

```stdout visible = true
1: alpha
2: beta
3: gamma
separator: ==
3 arguments
```

```stdin args = "\"a b c\" d"
***
```

```stdin args = ""
nothing
```

```stdout
separator: nothing
0 arguments
```
