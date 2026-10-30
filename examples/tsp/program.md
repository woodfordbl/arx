# Task: a faster, shorter TSP tour

`work/solve.py` reads 1,000 cities and prints a tour that visits every city
once. `python3 eval/score` runs it on three fixed instances, with 10 seconds
each, and prints `score: <mean tour length>`. **Lower is better.**

The baseline is nearest neighbour. Known ideas that work: 2-opt with neighbour
lists, Or-opt, a spatial grid for nearest-neighbour search, simulated annealing,
and Lin-Kernighan-style moves. Stay inside the time budget. A tour that misses
a city scores as a failure.

Rules:
- Change only `work/` and your harness (`harness/`).
- Do not change `eval/` or this file.
- Only the Python standard library is available.
