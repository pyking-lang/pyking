i = 0
total = 0
while i < 3:
    j = 0
    while j < 3:
        if j <= i:
            total = total + 1
        j = j + 1
    i = i + 1

print(total)
