

# Example Exercise - Factorial

This example shows different aspects of creating an exercise for examination or within the proggame. This is the source data for such an exercise, and should be self-contained.


Typically, there is an introduction to the exercise, as this text. After that comes one or more subtasks.

## Task 1 - factorial

Create the factorial function. The input should be a 

```
import int io

l = int(io.read_line())
if l is None:
    print("Not an integer")
    sys.exit(1)
    
def fact(n):
    if n <= 1 then 1 else fact(n - 1) * n

print(fact(l))

```
