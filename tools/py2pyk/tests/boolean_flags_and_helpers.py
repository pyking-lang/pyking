def is_vowel(c):
    if c == "a":
        result = True
    elif c == "e":
        result = True
    elif c == "i":
        result = True
    elif c == "o":
        result = True
    elif c == "u":
        result = True
    else:
        result = False
    return result


def count_vowels(letters):
    count = 0
    for c in letters:
        if is_vowel(c):
            count = count + 1
    return count


found = False
for c in ["h", "e", "l", "l", "o"]:
    if c == "z":
        found = True
print(found)
print(count_vowels(["h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d"]))
