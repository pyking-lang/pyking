# Numbers that may differ

Test mode passes this notebook: each stdout block holds numbers that
differ from what the solution prints, by no more than the task's
diff-allowed block allows. Written for tests/test_notebook.py.

```pyking task
# Print the area of a circle of radius 2, and a third.
```

```pyking solution
print("area =", 3.14159 * 2.0 * 2.0)
print("third =", 1.0 / 3.0)
```

```stdout
area = 12.57
third = 0.33
```

```diff-allowed
area = [+/-0.23]
third = [+/-.01]
```

Whole numbers, as before, and decimals written with digits on both
sides of the point:

```pyking task
# Print 7, 2.5 and 10.0.
```

```pyking solution
print(7, 2.5, 10.0)
```

```stdout
8 3.7 9.7
```

```diff-allowed
[+/-1] [+/-1.3] [+/-0.3]
```

With no solution, an answer is compared with the stdout block, and the
same rules loosen that comparison:

```pyking task
# Print an approximation of pi.
```

```stdout
3.14
```

```diff-allowed
[+/-0.01]
```
