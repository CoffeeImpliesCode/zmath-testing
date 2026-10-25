# zmath-testing

Experimental verification tools for [zmath](https://github.com/CoffeeImpliesCode/zmath):
public-API tests, independent numerical oracles, typed corpus replay, fuzzing,
and benchmarks. The runtime library does not link the oracle libraries.

## Requirements

- Zig 0.17.0.
- A sibling `../zmath` checkout. The package uses a local path dependency.
- Oracle tools: a C11 compiler, MPFR, GMP, and FLINT with Arb headers.
- Comparative benchmarks: GCC/G++ with C++17, Google Benchmark, libm, and
  the pinned CORE-MATH sources and reference library configured by `devenv.nix`.
- Python 3 for the benchmark runners.

`devenv shell` supplies the reference dependencies. Keep the Zig shim on `PATH`;
the manifest selects the compiler version. For a custom reference installation,
set the include and library search paths. `ZMATH_ORACLE_HOST_PREFIX` supplies an
optional runtime library prefix with libraries under `lib64`.
The optional coverage script requires `zig-cov` on `PATH`.

## Build and test

```sh
zig build
zig build test
zig build oracle
zig build test-campaigns
zig build test-generator
```

The corpus tools and benchmarks use this profile:

```sh
zig build published-tools -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=safe
```

`published-tools` builds the tools and runs their associated tests. It does not
regenerate the corpus or run measurements. CPU execution requires Haswell/FMA
features. Stored metadata retains the profile name `ReleaseSafe`.

| Build step | Action |
| --- | --- |
| `oracle-generator` | Build and install the typed corpus producer |
| `generate-corpus` | Generate and validate corpus records |
| `corpus-replay` | Build and install the replay executable |
| `replay-corpus`, `replay-vector` | Run scalar or four-lane replay |
| `bench`, `run-bench` | Build or run the selected public-API benchmark |
| `bench-scalar`, `run-bench-scalar` | Build or run the typed scalar matrix |
| `bench-vector`, `run-bench-vector` | Build or run registered vector benchmarks |
| `bench-helpers`, `run-bench-helpers` | Build or run public helper benchmarks |
| `bench-power`, `run-power` | Build or run power-family resource measurements |
| `bench-api-round`, `run-api-round` | Build or run API-surface benchmarks |
| `compare`, `run-compare` | Build or run the comparative C++ benchmark |
| `docs` | Generate comparative bridge API documentation |

Pass the qualified profile above to corpus and benchmark steps. Append program
arguments after `--`. `-Dbench-target=scalar-log-f` selects a legacy TSV benchmark.
See [the corpus guide](test/corpus/README.md) for generation, filtering, sharding,
range scans, and replay. Generated record trees and benchmark results are ignored.
A new checkout must generate records before replaying them.

The seeded exploratory fuzz campaign is separate from corpus publication:

```sh
zig build oracle-fuzz -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=safe --fuzz=100 --seed 0x7a6d6174
python3 -m unittest discover -s bench -p 'test_*runner.py'
```

## Layout

- `test/integration/`: public API and infrastructure tests.
- `test/oracle/`: independent C evaluators, campaign selection, producer, and replay.
- `test/corpus/`: schema-5 manifest, publication metadata, and legacy TSV fixtures.
- `test/support/`: corpus codecs and publication loaders.
- `bench/`: Zig benchmark executables, comparative C++ bridge, and Python runners.

## License

MIT, see [LICENSE](LICENSE).
