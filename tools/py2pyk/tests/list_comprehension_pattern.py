pairs = [(1, "a"), (2, "b"), (3, "c")]
labels = [label for (_, label) in pairs]
print(labels)

points = [(0, 0), (1, 2), (3, 4)]
sums = [px + py for (px, py) in points]
print(sums)
