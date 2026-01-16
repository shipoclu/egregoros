# Performance baselines

This directory is a lightweight, append-only log of performance snapshots over time.

The goal is to make it easy to answer: “did this commit make the hot read paths faster or slower?”

## How to record a new baseline

Recommended (isolated) DB workflow:

```sh
MIX_ENV=bench mix ecto.create
MIX_ENV=bench mix ecto.migrate
MIX_ENV=bench mix egregoros.bench.seed --force --seed 123
```

Then run the benchmarks and EXPLAIN baselines you care about:

```sh
MIX_ENV=bench mix egregoros.bench.run --warmup 1 --iterations 10 --filter timeline.home

MIX_ENV=bench mix egregoros.bench.explain --no-print \
  --filter timeline.home.edge_nofollows \
  --out perf/baselines/$(date +%F)_$(git rev-parse --short HEAD)
```

Notes:

- Prefer a fixed `--seed` so data is stable across runs.
- PostgreSQL plans can vary with dataset size and stats; record the seed parameters + dataset size alongside results.
- Use `mix egregoros.bench.explain --format json` if you want easier machine diffs.

