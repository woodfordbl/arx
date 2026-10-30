#!/usr/bin/env python3
"""Reads cities on stdin ("N", then N lines "x y") and prints a tour: the
city indexes in visiting order, one per line. argv[1] is the time budget in
seconds. Baseline: nearest neighbour from city 0."""
import sys


def main():
    data = sys.stdin.read().split()
    n = int(data[0])
    points = [(float(data[1 + 2 * i]), float(data[2 + 2 * i])) for i in range(n)]
    left = set(range(1, n))
    tour = [0]
    while left:
        x, y = points[tour[-1]]
        nearest = min(left, key=lambda j: (points[j][0] - x) ** 2 +
                      (points[j][1] - y) ** 2)
        tour.append(nearest)
        left.remove(nearest)
    print("\n".join(map(str, tour)))


main()
