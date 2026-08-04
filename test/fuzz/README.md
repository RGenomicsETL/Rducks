# Quack C fuzzer

`quack_fuzz.c` drives the dependency-free Quack logical-type and chunk decoders,
then requires every accepted value to survive encode/decode again. The seed
corpus contains scalar, varlen, list, nested-list, and struct chunks.

```sh
make fuzz-asan
make fuzz-ubsan
make fuzz FUZZ_RUNS=1000000
```

The make targets copy the seeds to a temporary corpus, so local campaigns do not
modify tracked files. Set `FUZZ_CC`, `FUZZ_RUNS`, or `FUZZ_MAX_LEN` to override
the defaults.
