# Native C properties

The `theft` runner generates and shrinks INTEGER, VARCHAR, and LIST chunks. It
checks semantic encode/decode round trips, rejection of every truncated valid
payload, and clean rejection or canonicalization of random bytes.

```sh
make prop
make prop-sanitize
make prop-coverage PROP_TRIALS=10000
make prop PROP_TRIALS=100000 PROP_SEED=0x1234
```

This suite links only `src/quack_core.c` and the test-only `theft` copy; it does
not load R or DuckDB.
