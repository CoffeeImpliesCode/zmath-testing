# zmath-testing

Independent verification for [`zmath`](https://github.com/CoffeeImpliesCode/zmath):
numerical oracles, corpus replay, fuzzing and benchmarks.

The point of this repository is to be *separate* from the library. A test suite
that shares code with the thing it checks can only confirm the code agrees with
itself. Everything here reaches `zmath` through its published API and decides
right and wrong against sources that do not come from `zmath` — the C23
specification, an independent libm, or a generated oracle.

## What is here

| directory | contents |
|---|---|
| `test/` | oracle and campaign tests |
| `bench/` | benchmarks, including an API-surface round-trip harness and a comparative bridge to C/C++ libm |
| `docs/` | retained evidence from past campaigns |

## Build steps

```sh
zig build test              # the default suite
zig build oracle            # differential checks against the oracle
zig build oracle-fuzz       # fuzz the oracle comparison
zig build corpus-replay     # replay a recorded corpus
zig build replay-corpus     # alias of the above
zig build test-campaigns    # full C23 campaign
zig build test-generator    # regenerate the corpus
zig build oracle-generator  # regenerate the oracle tables
zig build bench             # all benchmarks
zig build run-bench         # scalar, vector and helper benchmarks
zig build run-power         # power/energy measurements
zig build run-api-round     # API-surface round-trip harness
zig build compare           # comparative run against the C/C++ bridge
zig build docs              # autodoc site
```

Requires Zig 0.16.0. Depends on `zmath`.

## Branches

`main` is the current line. `preserve-c23-campaigns` retains a broader C23
campaign and its evaluator; it is kept for reference and is not merged.

## License

See [LICENSE](LICENSE).