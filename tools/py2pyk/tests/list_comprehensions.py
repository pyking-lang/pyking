values = [1, 2, 3, 4, 5]
doubled = [x * 2 for x in values if x > 2]
print(doubled)

rows = [1, 2, 3]
cols = [10, 20]
products = [r * c for r in rows for c in cols]
print(products)

table = [[r * c for c in cols] for r in rows]
print(table)

matrix = [[1, 2], [3, 4], [5, 6]]
flat = [x for row in matrix for x in row]
print(flat)
