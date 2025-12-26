# Benchmarks

This project includes a small, dependency-free benchmark harness to help catch performance regressions on common read paths (timelines, rendering, search).

## Recommended workflow (isolated DB)

Use the `bench` environment so the synthetic dataset does not pollute your dev DB:

```sh
MIX_ENV=bench mix ecto.create
MIX_ENV=bench mix ecto.migrate

# Destructive by default (wipes users/objects/relationships)
MIX_ENV=bench mix egregoros.bench.seed --force

MIX_ENV=bench mix egregoros.bench.run
```

## Seeding options

```sh
MIX_ENV=bench mix egregoros.bench.seed --force \
  --local-users 10 \
  --remote-users 200 \
  --days 365 \
  --posts-per-day 200 \
  --follows-per-user 50 \
  --seed 123
```

Notes:

- The default local user password is `bench-password-1234` (for all generated local users).
- If you run into `:emfile` / "too many open files" under load, see `README.md`.

## Running specific cases

Filter the suite by substring:

```sh
MIX_ENV=bench mix egregoros.bench.run --filter timeline.home
```

