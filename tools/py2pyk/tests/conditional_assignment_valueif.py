def classify(x):
    if x >= 10:
        label = "big"
    elif x >= 0:
        label = "small"
    else:
        label = "negative"
    return label


print(classify(12), classify(3), classify(-1))
