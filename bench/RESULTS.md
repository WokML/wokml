# Layout Compaction Slice 2 — Benchmark Report

**Claim:** no interpreter wall-clock claim — these are deterministic allocation counts.

Nullary constructors (Leaf, Nil, None, True, False) are now inline immediates:
zero cells allocated, zero bytes consumed, zero RC overhead.

## Allocation counts

| Program | Before allocs | After allocs | Δ allocs | % reduction |
|---------|:-------------:|:------------:|:--------:|:-----------:|
| tree    |      511      |     255      |  −256    |    −50.1%   |
| list    |      101      |     100      |   −1     |     −1.0%   |
| bools   |     3000      |       0      | −3000    |   −100.0%   |
| maybes  |      193      |      72      |  −121    |    −62.7%   |

| Program | Before frees  | After frees  |
|---------|:-------------:|:------------:|
| tree    |      511      |     255      |
| list    |      101      |     100      |
| bools   |     3000      |       0      |
| maybes  |      193      |      72      |

| Program | Before peakLive | After peakLive |
|---------|:---------------:|:--------------:|
| tree    |       511       |      255       |
| list    |       101       |      100       |
| bools   |         2       |        0       |
| maybes  |       129       |       72       |

## Analytical peak bytes (8 + 8×arity per cell)

Cell size formula: `8 + 8 × arity` bytes (8B header + 8B per slot).

| Program | Before peak bytes | After peak bytes | Δ bytes  | % reduction |
|---------|:-----------------:|:----------------:|:--------:|:-----------:|
| tree    |     10,208 B      |     8,160 B      | −2,048 B |    −20.1%   |
| list    |      2,408 B      |     2,400 B      |     −8 B |     −0.3%   |
| bools   |         16 B      |         0 B      |    −16 B |   −100.0%   |
| maybes  |      2,120 B      |     1,664 B      |   −456 B |    −21.5%   |

### Derivation

**tree** (`build 8`): 255 `Node` (arity 3 = 32 B) + 256 `Leaf` (arity 0 = 8 B).
Before: 255×32 + 256×8 = 8,160 + 2,048 = **10,208 B**.
After (Leaf = inline): 255×32 = **8,160 B**.
- ~50% fewer cells (256 Leaf cells eliminated); ~20% fewer bytes (Leaf is small
  relative to Node).

**list** (`build 100`): 100 `Cons` (arity 2 = 24 B) + 1 `Nil` (arity 0 = 8 B).
Before: 100×24 + 1×8 = 2,400 + 8 = **2,408 B**.
After (Nil = inline): 100×24 = **2,400 B**.
- Nil is a single cell at the tail; the saving is a small constant (1 cell, 8 B).

**bools** (`loop 1000`): `True`/`False` are nullary booleans; at most 2 live simultaneously.
Before peak: 2×8 = **16 B** (3,000 total allocs/frees, peakLive = 2).
After: **0 B** — all boolean allocations collapse entirely; zero cells allocated over
the whole run.

**maybes** (`build 64`): 64 `Cons` (arity 2 = 24 B) + 1 `Nil` (8 B) + 8 `Some`
(arity 1 = 16 B) + 56 `None` (arity 0 = 8 B) = 129 cells.
Before: 64×24 + 1×8 + 8×16 + 56×8 = 1,536 + 8 + 128 + 448 = **2,120 B**.
After (Nil + None = inline): 64×24 + 8×16 = 1,536 + 128 = **1,664 B**.
- 121 nullary cells eliminated (Nil + all None); peakLive drops 129 → 72 (~44%).

## Note on `wok_stat_peak_bytes`

A `wok_stat_peak_bytes` counter (`Σ(8 + 8×arity)` high-water mark) was added to both
C runtime builds (`wok_rc.c`). Because `--dump-rc-stats` derives its numbers from the
abstract Haskell-level `Stats` struct (not from the C heap's own counters), the
analytical bytes above are derived from the cell-count stats. The oracle (differential
parity between the abstract and C backends) confirms the populations are identical, so
the analytical derivation is exact.
