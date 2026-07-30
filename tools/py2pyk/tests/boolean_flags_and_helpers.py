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


def count_vowels(s):
    count = 0
    for c in s:
        if is_vowel(c):
            count = count + 1
    return count


found = False
for c in "hello":
    if c == "z":
        found = True
print(found)
print(count_vowels("hello world"))
