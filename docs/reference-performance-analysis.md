# CORE-MATH and glibc performance analysis

Date: 2026-09-09. Runtime snapshot: `e6673837a3c7a7ea249f586c7b9da2d9b684e4e6`.

All campaign measurements below are dated historical receipts, not current corpus totals.
Keep their original descriptor counts, timings, and digests.
The current publication has 347 descriptors and 72,035,642 records.
See [the corpus README](../test/corpus/README.md#status-and-evidence) for current acceptance evidence.

## 2026-09-26 optimization campaign

This section records a second campaign against the runtime source tree. Unlike
the analysis below, it changed `../zmath` and verified every change before
keeping it.

Coverage: 41 operations, 3 formats, and 3 distributions in the comparative
matrix (1,173 available provider cells), 315 typed corpus descriptors, and 15
public helper or rounding-mode cases that the comparative matrix does not
exercise. The frozen baseline source, binaries, and raw records are under
`bench/results/superopt-20260926-*`. These are sampled timing and accuracy
audits, not whole-domain proofs.

The same-input Zig intrinsic reference covers 18 descriptors (`abs`, `ceil`,
`floor`, `trunc`, `round`, and `fma` in three formats). Its binary16 and binary32
`fma` samples differ from the qualified zmath outputs, so the typed runner
explicitly excludes those two rows. The other 16 references are timed.

### Measurement limits found on this host

The process-level typed benchmark has a floor near 4.8 ns per call. Cheap
descriptors varied by as much as 3x across repetitions, including unchanged
code. Two protocols separated useful measurements from that noise:

1. For expensive descriptors, alternate baseline and candidate processes and
   compare the minimum time per call. The paired run in
   `bench/results/superopt-20260926-ab-clean/report.json` has 15 observations
   per descriptor and revision.
2. For shorter calls, link the frozen baseline and candidate into one
   interleaved comparator (`bench/results/superopt-20260926-abtime.zig`).
   The rows below come from one run,
   `bench/results/superopt-20260926-abtime-2.txt`, and use its minimum
   time per call. Repeated runs show 3–8% code-placement bias for unchanged
   functions; smaller differences do not establish a win.

### Retained changes

The following times are nanoseconds per call. Each table uses one named
measurement run and its minimum statistic; speedup is before divided by after.
The interleaved run compares the wave-2 implementation with the frozen baseline.

| Interleaved case | Before | After | Speedup |
|---|---:|---:|---:|
| `fmod` f16/f32/f64 | 653/1660/12472 | 156/159/1058 | 4.18/10.44/11.79x |
| `remainder` f16/f32/f64 | 672/1649/12597 | 161/163/1077 | 4.17/10.12/11.70x |
| `trunc` f16/f32/f64 | 40.6/33.4/32.1 | 24.0/20.4/19.9 | 1.69/1.64/1.61x |
| `ceil` f16/f32/f64 | 55.0/45.4/30.7 | 32.9/26.3/19.9 | 1.67/1.72/1.54x |
| `floor` f16/f32/f64 | 39.5/31.6/30.3 | 23.8/20.4/19.9 | 1.66/1.55/1.52x |
| `asin` f16 | 23.05 | 13.03 | 1.77x |
| `tanh` f16 | 26.72 | 22.88 | 1.17x |
| `sqrt` f64 | 14.95 | 12.60 | 1.19x |

The paired typed-corpus minima compare the wave-2 implementation with the
same frozen baseline. This workload includes corpus dispatch; its absolute
times are not interchangeable with the interleaved times.

| Typed corpus case | Before | After | Speedup |
|---|---:|---:|---:|
| `f16sqrtf64` | 175.439 | 24.266 | 7.23x |
| `fsqrt` (f64 input, f32 result) | 178.309 | 22.368 | 7.97x |
| `f32sqrtf64` | 178.095 | 22.136 | 8.05x |
| `f16sqrtf32` | 85.936 | 21.653 | 3.97x |
| `pown` f64 | 162515 | 130482 | 1.25x |
| `compoundn` f64 | 144215 | 68349 | 2.11x |

For the later certified `rootn` f64 seed, five alternating runs with five
repetitions each in `bench/results/superopt-20260926-rootn-*-{baseline,wave3}.txt`
give 1,133,460 → 328,491 ns per call by the same minimum statistic (3.45x).
The medians of the 25 observations agree (1,143,401 → 330,926 ns, 3.46x).

The changes preserve exact integer state or the original result rounding:

- `scalar_remainder.zig` replaces one exponent bit per division with
  `clz(divisor)`-wide quotient chunks, keeping the low three quotient bits
  exact for `remquo` and the nearest-even tie rule unchanged.
- `scalar_narrow_common.zig` replaces 32 integer divisions per narrowing
  square root with a strict f64 seed and exact u128 square corrections. The
  midpoint comparison and the single final rounding are unchanged.
- `scalar_power_exact.zig` initializes and copies only active limbs, restricts
  the root search to the exact exponent bracket, and short-circuits degree one,
  powers of one, squares, and the proven tiny-`compoundn` region. For f64 roots
  of degree at least two, an approximate seed is used only after exact
  comparisons certify adjacent candidates; otherwise the exact binary search
  runs unchanged. The 2,048-limb array is capacity, not a product size for
  every call. A follow-on change writes f16 shift limbs directly. The f32 and
  f64 paths keep the original shift loop.
- `scalar_rounding.zig` and `scalar_integer_rounding.zig` use directed
  rounding intrinsics after explicit NaN, zero, and range guards.
- `scalar_asin.zig` and `scalar_tanh.zig` answer the binary16 ranges from
  exact result tables generated from the exhaustive qualified corpus
  (`bench/generate_half_tables.py`, 24,306 bytes total).
- `scalar_sqrt.zig` takes one unsigned-bit guard before `@sqrt`; `coremath_lgammah.c`,
  `coremath_lgammaf.c`, and `coremath_lgammad.c` own the pole signs so the Zig
  wrappers no longer repeat the classification; `scalar_erff.zig`, `scalar_erfh.zig`,
  and `scalar_erfd.zig` derive the range-reduction index once; `scalar_cbrt.zig`
  scales the reciprocal with an exponent decrement; `scalar_scaling.zig` and
  `ieee.zig` normalize subnormals with a bounded `@clz` shift.

### Final full comparison and verification

`bench/results/superopt-20260926-baseline/report.txt` and
`bench/results/superopt-20260926-final-resumed/report.txt` use five repetitions
on CPU 7, `ReleaseSafe`, and the Haswell target. Both runs used identical
input digests, the same CORE-MATH revision, and nearest-even rounding.
Each provider uses an opaque C function pointer and a 1,024-call batch.
Times below are median ns per call.
The runner audited all 1,173 available provider rows: 41 operations × 3
formats × 3 distributions for zmath, plus available references. All 369 zmath
rows and all 363 supported independent CORE-MATH rows matched the MPFR audit
contract. Zig differed on 101 of its 195 available sampled rows; glibc differed
on 82 of 246. These audits do not establish whole-domain correctness.

| Final comparative case | Baseline zmath | Final zmath | Final CORE-MATH |
|---|---:|---:|---:|
| `asin` f16 normal/wide | 21.30/22.13 | 9.82/8.85 | 18.52/18.21 |
| `tanh` f16 normal/wide | 15.46/11.50 | 9.66/8.61 | 12.30/9.42 |
| `lgamma` f64 normal/wide | 97.43/100.35 | 71.76/73.69 | 57.89/59.94 |
| `tgamma` f32 normal/wide | 37.55/53.24 | 27.99/40.36 | 29.69/41.79 |
| `atan2pi` f64 normal | 62.44 | 54.63 | 36.98 |

By the final matrix's median statistic, zmath is faster than CORE-MATH on
255 of 363 comparable rows, versus 250 in the baseline; it is slower on 108.
Against the fastest *sample-matching* available reference, zmath leads on
222 of 369 rows, versus 220 in the baseline. Near-ties vary with placement
and CPU conditions; these counts describe this run, not 5 proven new wins.
The baseline and final typed executables each measured 315 descriptors.
The companion helper executables each measured 15 public helper/mode cases.
Input digests match. Checksums agree when the adaptive call counts match.
The qualified corpus replay, oracle, campaign, generator, and fuzz gates passed.
The runtime house gate passed format, build, 561 unit tests, AST check, and
three linters. The harness Zig format check also passed.

### Reverted change

Rewriting `asinhf` to widen the sign-cleared input and inject the sign after
rounding measured 0.955 to 0.973 against unchanged code across four runs,
with both minimum and median statistics agreeing. The change was restored
to the baseline form. Selecting operands instead of using the weighted quotient
in the C `atan2pif` kernel gave no repeatable gain: one five-repetition run
changed normal/wide/special medians from 27.10/251.19/29.86 to
28.40/245.30/32.29 ns per call. That change was also restored.

### Remaining losses

`rootn` f64 still costs about 0.33 ms per call on its typed probe despite
the certified seed. Exact candidate powers may involve up to about 53
active limbs; the 2,048-limb buffer is a capacity bound. More progress needs
a different certified algorithm or a better seed.

The archived final binary regressed on the `compoundn` f16 typed probe. Five
alternating processes with five repetitions each measured baseline versus
final minima of 788 → 1,079 ns per call and medians of 889 → 1,126 ns
(0.73x and 0.79x). The records are
`bench/results/superopt-20260926-compoundn-*-{baseline,final}.txt`.
Fixed-size clearing and a specialized u64 representation for `1+x` did not
recover a repeatable win and were reverted. The later f16 shift change below
reduces this loss without changing the f32 or f64 shift loop.

The final report lists all 108 zmath rows slower than the independent
CORE-MATH reference: 52 gaps exceed 10% and 19 exceed 25% by median.
The largest measured ratios are `cospi` f32 normal (1.48x), `atan2pi` f64
normal (1.48x), `log2p1` f32 wide (1.44x), `lgamma` f32 special (1.40x),
and `erf` f64 normal (1.37x). `atan2pi` f32 normal/wide also trails
(1.23/1.08x), while f64 wide/special is faster than CORE-MATH. For f64,
`lgamma` normal/wide trails by 1.24/1.23x and `tgamma` by 1.13/1.36x.
The sampled audit found MPFR mismatches in 101 of 195 available Zig rows
and 82 of 246 glibc rows; a faster mismatching row is not a
correctness-preserving target.

The full matrix also has eight baseline-to-final slowdowns above 20% by
median, mostly short paths near the measurement floor. Three concerning
cases were rerun in three alternating baseline/final processes with five
repetitions each (`bench/results/superopt-20260926-focused-*.json`):
`tanpi` f64 wide, `tgamma` f64 wide, and `cospi` f32 normal then measured
baseline/final ratios of 1.06, 0.98, and 1.04. Their CORE-MATH controls
varied too. Thus the isolated full-run differences do not establish a
repeatable source regression; the archived-final `compoundn` f16 loss above does.

### Follow-on f16 shift measurement

The 32-limb `Big.shifted` path now writes each active result limb once. It
clears only whole-limb gaps and stores the final carry if it is nonzero.
The f32 and f64 paths keep the prior clear-and-OR loop. This preserves exact
integer powers and one final rounding.

Five rotating runs of the frozen baseline, archived final, and new f16-only
binary used CPU 6, Haswell, `ReleaseSafe`, and five repetitions per process.
Each cell below contains 25 `compoundn` f16 measurements of the same 64
qualified samples. Each binary checked all samples against the corpus before
timing. All corpus digests matched.

| `compoundn` f16 binary | Minimum ns/call | Median ns/call |
|---|---:|---:|
| Frozen baseline | 802.4 | 827.8 |
| Archived final | 1,071.4 | 1,208.5 |
| F16-only shift | 800.3 | 855.6 |

The f16-only shift is 1.41x faster than the archived final by median and
1.34x faster by minimum. It is 3% slower than the frozen baseline by median.
The two baseline minima differ by less than 1%. These are sampled timings,
not a whole-domain speed or accuracy claim.

For `pown` f16, three alternating process pairs with five repetitions each
measured archived-final and f16-only minima of 1,026.3 and 813.8 ns/call.
The corresponding medians were 1,154.1 and 866.6 ns/call (1.33x).
The `rootn` process timings varied substantially for all three formats,
including the unchanged f32 and f64 paths. No `rootn` speed claim follows
from these runs. Disassembly of the f32 and f64 `Big.shifted` functions
showed the same instructions apart from relocated call targets.

The typed executable is
`bench/results/superopt-20260926-shifted-f16-only-bin/bin/zmath-scalar-matrix`.
The archived-final and baseline executables are in the adjacent
`superopt-20260926-{final,baseline}-bin` directories. Reproduce a probe with
`taskset -c 6 <executable> test/corpus --operation=compoundn --repetitions=5`.
The runtime house gate and qualified replay passed after the precision-scoped
change. The replay checked 315 descriptors and 63,160,084 records. The oracle,
campaign, generator, and fuzz gates also passed on the retained tree.

### buildhost 9 full comparator (2026-09-27)

The existing `ReleaseSafe` Haswell comparators require an ELF loader and
reference libraries at absolute `/nix/store` paths. buildhost 9 has no
`/nix/store`. The fix kept both binaries
and their pinned references unchanged. The private, rootless `bwrap` namespace
binds six bundled Nix store paths and the complete pinned CORE-MATH source
under `/nix/store`. No host packages or system paths were changed.

The binaries are
`bench/results/superopt-20260926-baseline-bin/bin/zmath-compare` and
`bench/results/superopt-20260926-f16only-comparative-bin/bin/zmath-compare`.
Their SHA256 digests are
`1546bad0bf03ff5aceda7d1c9f94406f56f6839be08cf2845afc091ae735de45`
and `2a2d2665b39da0c212f67c8e663ca118a7f98e8d35fcfe54c972931dda24af13`.
The bundle is in `bench/results/superopt-20260927-compare-runtime.tgz`
(SHA256 `18250b991ba9a81f5661f2c5e3e1c138c794a6091a7f15574b82d2274c8d8896`)
and `bench/results/superopt-20260927-compare-core-source.tgz`
(SHA256 `60e30d10792f275e7ac3105b0dd4017e07acf05fda13a15fd447fb3836b3e996`).
The first archive contains glibc 2.42, GCC 15.3 runtime libraries, MPFR
4.2.2, GMP 6.3.0, and the pinned CORE-MATH shared library. The second
contains the full pinned source tree required by the binary's provenance
check. Extract each archive once into a new `nix-store` directory. The
server-side copy is under
`~/zmath-bench-20260927-f16only/compare/`.

That directory is **required provenance, not leftover scratch, and must not be deleted.**
It is the only copy of this campaign's material. Nothing from the 2026-09-26 and 2026-09-27 campaigns was
ever committed under `bench/results/`: the three paths tracked there belong to the later 2026-10-03
round and cover none of it. The two archives cited above, the unpacked `nix-store`, and the run outputs
behind the matrix in this document therefore exist nowhere else. The working command further down binds
`$bundle/nix-store`, `$bundle/bin` and `bundle/results` directly, so the analysis cannot be reproduced
without it. It occupies about 887 MB, of which roughly 871 MB is the unpacked `nix-store`; that is the
price of being able to re-run the comparison rather than only read about it.

The working smoke command below uses the unpacked remote directory. Replace
`/binaries/retained` with `/binaries/baseline` for the frozen run. The full
matrix omits the filter and list flag, and supplies `--accuracy_out`,
`--benchmark_out`, `--benchmark_out_format=json`,
`--benchmark_min_warmup_time=0.1`, `--benchmark_min_time=0.2s`,
`--benchmark_repetitions=5`, `--benchmark_report_aggregates_only=false`,
`--benchmark_display_aggregates_only=false`, and
`--benchmark_enable_random_interleaving=true`.

```sh
bundle="$HOME/zmath-bench-20260927-f16only/compare"
taskset -c 7 nice -n 10 bwrap --tmpfs / \
  --ro-bind /usr /usr --symlink usr/bin /bin \
  --symlink usr/lib64 /lib64 --symlink usr/lib /lib \
  --dir /nix --ro-bind "$bundle/nix-store" /nix/store \
  --ro-bind /etc /etc --ro-bind /sys /sys --proc /proc --dev-bind /dev /dev \
  --ro-bind "$bundle/bin" /binaries --bind "$bundle/results" /work \
  --tmpfs /tmp \
  --setenv LD_LIBRARY_PATH /nix/store/r48746qznwqxxl9qzd8f08ny8mg1dg2y-gcc-15.3.0-lib/lib \
  -- /binaries/retained --benchmark_list_tests=true \
  --benchmark_filter='^(zmath|coremath)/atan2pi/f64/normal$'
```

Both binaries ran on the same Xeon Gold 6134 host, pinned to CPU 7 at nice
10, without GPU use. Each full run used 0.1 s warmup, 0.2 s minimum
measurement, five randomly interleaved repetitions per row, and a 1,024-call
batch. Both runs used GCC 15.3.0 and CORE-MATH revision
`3bafed75e3c22399531857d63a3fa0e24bfb42fa`. The pinned GNU libc
version was 2.42.
The production evidence loader accepted both receipts: each audited 1,476
provider/dataset rows and timed all 1,173 available rows five times. The two
audit JSON files are byte-identical (SHA256
`09e3db1c42efc690d3e40a9b804657fa0d2f0be436004234e01bb415b018940d`).
All 369 zmath and 363 CORE-MATH rows had zero recorded MPFR-512 RNE
discrepancies. Input hashes, reference origins, and timing keys match.
This sampled audit is not a whole-domain rounding proof.

| Case | Frozen zmath ns/call | Retained zmath ns/call | Matching reference, frozen → retained ns/call |
|---|---:|---:|---:|
| `asin` f16 normal | 17.38 | 12.22 | CORE-MATH 23.11 → 21.56 |
| `asin` f16 wide | 17.60 | 12.18 | CORE-MATH 22.02 → 21.04 |
| `atan2pi` f64 normal | 44.58 | 40.31 | CORE-MATH 32.64 → 32.39 |
| `atan2pi` f32 normal | 30.41 | 29.25 | CORE-MATH 25.24 → 25.45 |
| `tgamma` f64 normal | 78.06 | 78.19 | CORE-MATH 68.92 → 69.16 |
| `hypot` f16 normal | 24.80 | 24.64 | Zig 13.00 → 12.80 |
| `hypot` f16 wide | 22.07 | 21.81 | Zig 10.29 → 13.01 |
| `asin` f32 special | 16.83 | 16.52 | Zig 11.03 → 10.51 |

The `asin` f16 normal and wide rows improved 1.42x and 1.44x against
their frozen zmath baseline. Both five-sample timing ranges are disjoint;
the matching CORE-MATH controls improved only 1.07x and 1.05x.
The retained `atan2pi` f64 normal row remains 1.24x slower than independent
CORE-MATH; the frozen baseline was 1.37x slower. This is the largest
retained CORE-MATH gap, and both five-repetition runs show it. The retained
`atan2pi` f32 normal and `tgamma` f64 normal gaps are 1.15x and 1.13x.

Against the fastest sample-matching reference, three retained rows exceed
1.5x: `hypot` f16 normal/wide (1.92x/1.68x versus Zig) and `asin` f32
special (1.57x versus Zig). Only 384 of the 1,024 `asin` special samples
were finite. These Zig results are sampled matches, not certified
replacements for the current correctly rounded kernels.
CPU scaling and ASLR were enabled, and CPU 7 was not isolated from its
SMT sibling. The median per-row timing CV was 7.1% for the frozen run
and 3.0% for the retained run. Do not count near-ties or small changes
between runs as source wins. Next target: investigate a certified
`atan2pi` f64 normal-path improvement in
`../zmath/src/coremath_pi_inversed.c`, while preserving the unresolved-result
contract.

The validated raw records and generated full reports are in
`bench/results/superopt-20260927-buildhost-full-comparator/`. The separate
one-repetition deployment probe is in
`bench/results/superopt-20260927-buildhost-full-comparator-probe/`.

### Proof-gated six-kernel pass on buildhost 9 (2026-09-27)

This pass compared the retained binary above with a new `ReleaseSafe` Haswell
binary. Their SHA256 digests are
`2a2d2665b39da0c212f67c8e663ca118a7f98e8d35fcfe54c972931dda24af13`
and `5e7b398a71c9de87f54c8661cd339a7c81b1f5a5ac01280bcefaf581e6736e83`.
The new binary uses the same loader, libraries, pinned CORE-MATH revision,
inputs, and rootless namespace as the comparator above. It is 7,154,320 bytes.
Both full runs used CPU 7 at nice 10, a 1,024-call batch, 0.1 s warmup,
0.2 s minimum time, and five randomized repetitions per row. The runs were
separate processes. Randomization did not interleave the two binaries.

The full receipts each have 1,476 MPFR-512 RNE audit rows and 1,173 timing
rows with five repetitions. Their audit files are byte-identical, with SHA256
`09e3db1c42efc690d3e40a9b804657fa0d2f0be436004234e01bb415b018940d`.
All 369 zmath rows and 363 available CORE-MATH rows recorded zero audit
discrepancies. The production loader checked timing coverage, build details,
input hashes, and reference provenance. Remote and local receipt hashes match.
The sampled audit does not prove whole-domain correct rounding.

The only retained runtime changes are:

- `../zmath/src/scalar_hypot.zig`: For finite f16 magnitudes `n <= m/64`,
  return `m`. The exact increase is below the next f16 midpoint. Otherwise,
  narrow the f32 square root only when endpoints eight f32 steps on each side
  agree as f16. Keep the original f64 path when they disagree. An exact-integer
  midpoint oracle checked all 503,856,640 unordered finite f16 magnitude
  pairs without a mismatch. Special values keep their existing path.
- `../zmath/src/coremath_pi_inversef.c`: Return the signed quadrant constant
  when the existing quotient has `z² <= 2^-54` and its correction is below
  the f32 midpoint near 0.5 or 1. Do not take this path for a positive-x
  small angle, which can round to a nonzero f32 value.
- `../zmath/src/scalar_asin.zig`: Classify out-of-domain f32 inputs once.
  Preserve NaN payload quieting, canonical domain NaNs, and the finite kernel.

The table uses the median CPU time per call from each **full** matrix.
References in the last column processed the same inputs in the corresponding
run. A faster sampled Zig row is not a correctly rounded replacement.

| Case | Retained zmath ns/call | New zmath ns/call | Matching reference, retained → new ns/call |
|---|---:|---:|---:|
| `atan2pi` f32 normal | 30.18 | 29.39 | CORE-MATH 25.63 → 26.83 |
| `atan2pi` f32 wide | 185.15 | 29.39 | CORE-MATH 179.28 → 176.71 |
| `atan2pi` f32 special | 28.88 | 15.42 | CORE-MATH 56.52 → 56.46 |
| `hypot` f16 normal | 25.43 | 17.19 | Zig 12.75 → 13.90 |
| `hypot` f16 wide | 22.51 | 20.04 | Zig 12.97 → 13.89 |
| `asin` f32 normal | 17.72 | 15.58 | CORE-MATH 22.20 → 22.49 |
| `asin` f32 wide | 17.42 | 15.63 | CORE-MATH 22.36 → 22.65 |
| `asin` f32 special | 17.69 | 18.29 | Zig 11.51 → 13.16 |

The full `atan2pi` f32 wide and special rows improved 6.30x and 1.87x.
A close focused pair measured 6.28x for wide, and a second focused pair
measured 1.93x for special. The close pair measured normal at 30.82 → 30.45
ns/call, so the earlier normal-path regression did not survive the revision.
The full `hypot` f16 normal and wide rows improved 1.48x and 1.12x.
Their close focused pair improved 1.39x and 1.10x. The full `asin` f32
normal and wide rows improved 1.14x and 1.11x. Their close pair improved
1.13x and 1.14x. Do not count the `asin` special full-run difference as a
source slowdown: its focused pair measured 17.08 → 16.81 ns/call.

The long full runs show host drift. Across all rows, the median zmath
candidate/retained ratio was 1.048, while the independent CORE-MATH ratio
was 1.066. For example, the full `asin` f16 normal row was
11.11 → 14.36 ns/call, although its kernel did not change. A second close
pair measured 14.34 → 14.36. The unchanged `sinh` f32 special and `sqrt`
f64 wide rows also changed by less than 0.4% in that pair. Thus the large
full-run changes on these short paths do not reproduce as source regressions.
CPU scaling, ASLR, and the active SMT sibling limit smaller claims.
The `hypot` f16 wide and `asin` f32 special gaps versus sampled Zig results
still exceed 1.5x in the close focused pair. The 1.5x target is not
established across runs.

Three experiments were discarded. A f32 quotient-gap test before division made
`atan2pi` normal 15.8% slower in the first focused pair, despite a wide gain.
Moving the certified return into the existing cold polynomial guard kept the
wide gain without that normal loss. A proposed `atan2pi` f64 sign change had
no repeatable win and was reverted. An `lgamma` f64 floor-reuse change slowed
normal calls 5.3% with a stable CORE-MATH control and was reverted. The
compiled `tgamma` f64 baseline already folds the duplicate source `floor`
calls, so that experiment made no source change. No f64 `lgamma`, `tgamma`,
or `atan2pi` speedup is attributed to a retained source change.

The runtime house gate, qualified `ReleaseSafe` unit tests, qualified oracle,
and testing-project unit tests passed. The qualified corpus replay checked
315 descriptors and 63,160,084 records. `zig build docs` and `zig build run`
also passed. The retained edge tests cover f16 midpoint rounding, f32
quadrant neighbors, and `lgamma` signs near negative poles.

The raw receipts are in `bench/results/optpass-20260927-buildhost/`.
The full timing files `full-retained.json` and `full-refined.json` have SHA256
`3e9d5fa219d80fb472f6715ffab81730b8a988cbe3dbfcf9decf6a9af15acadc`
and `09f7688da7ea68c900d8cd5d792039a02dafce8b9ccb25de745ca8276104cce8`.
The close focused pair is `focused-refined-{retained,candidate}.json`, with
SHA256 `b89e3f567c4ce2301b3b865a6cc28c05adea73692636e418871bdccbbb89f15b`
and `ef5f3c86d8b7c2bce698d3294f0685e932a42902cff0163f2ae1d5e9a4d11a17`.
The drift pair is `focused-refined-drift-{retained,candidate}.json`, with
SHA256 `fb166b93d5533f26bf5b67b5929f0b5b5ec8bcb8667d55573bfb4562f0995344`
and `317d04249c3119f75f0ded8aaaa0d69091bfe94b04adfd8d2f21d170a98c9f85`.
Each timing file has a matching `-accuracy.json` receipt.

### Focused `rootn` and `tgamma` follow-on (2026-09-27)

The retained changes affect the exact-power multiplier and the f64 gamma
entry. In `../zmath/src/scalar_power_exact.zig`, the 32-limb (f16) multiplication
initializes its first product row directly and writes each later row's new
high carry. It no longer clears the active destination prefix. This
multiplier is shared by `rootn`, `pown`, and `compoundn`; only `rootn`
was timed in this focused trial. The 256- and 2048-limb (f32/f64)
paths retain the old clearing and carry propagation: a trial that
applied the change to larger formats slowed both in alternating
measurements and was reverted. A late f64 `rootn` CPU profile
attributed 93.3% of samples to `compiler_rt.memset`; this f16-only
change is not a claim to have removed the remaining f64 clearing cost.

In `../zmath/src/scalar_tgamma.zig` and `../zmath/src/coremath_tgammad.c`,
the private f64 C entry is now `cr_tgamma_finite`. The Zig wrapper already
handles NaNs, infinities, signed zero, and negative-integer poles, so the
finite entry no longer repeats those classifications. The finite numerical
algorithm is otherwise unchanged; `build.zig` retains the renamed C symbol
in its ABI guard. The public `tgammad` contract and exceptional results
did not change.

For `rootn`, six local alternating ReleaseSafe Haswell processes ran
old/new/new/old/old/new on CPU 4 at nice 10. Each processed 64 published
samples per format with 11 repetitions. The median of the three
per-process f16 medians was 3,904.79 ns/call before and 3,064.81 ns/call
after (1.27x). Individual f16 process medians were
3,706.85/3,895.94, 3,904.79/2,246.83, and
5,529.34/3,064.81 ns/call (old/new), so the first pair did **not**
improve. The host drift and variable f16 call counts prevent a tighter
speed claim. The f32/f64 paths were not changed by this experiment;
their timing differences are not source wins. The matching input digests
and raw samples are in
`bench/results/optpass-round2-local/rootn-final-rotations.json`
(SHA256 `9bf5974a34d3370bfc6466ac8e1ad5b380e486f6a886d7f59d4b6160e7a86e54`).
The frozen/new typed executable SHA256 digests are
`5505fcfb4159c52e3d55ef1c3c3fe007a3061e46531b1e55af6a6e9dfac05d1e`
and `eefca978c5aafaba346d37ab9f5b044872ca9fcafb9718c495721c30bef8c8f3`.

For `tgamma` f64, the frozen/new comparative executable SHA256 digests
are `5e7b398a71c9de87f54c8661cd339a7c81b1f5a5ac01280bcefaf581e6736e83`
and `202d8b803e30fa44ca6a2d6fda9a457db9c89dc74f404d61498fd15078c0f9cb`.
On buildhost 9 the four separate processes ran old/new/new/old on CPU 7
at nice 10 in the same rootless namespace and pinned reference environment
as above. Each timed the six selected zmath/CORE-MATH `tgamma` f64
normal/wide/special rows: 1,024 calls per iteration, 0.1 s warmup,
0.3 s minimum time, and nine randomized repetitions. The table takes
the median of each process's nine-sample CPU-time median, then the
median of the two process medians per binary. The control column reports
the corresponding independent CORE-MATH medians. Speedup is
`(old zmath / old CORE-MATH) / (new zmath / new CORE-MATH)`.

| Input | Old → new zmath ns/call | Old → new CORE-MATH ns/call | Control-adjusted speedup |
|---|---:|---:|---:|
| normal | 75.447 → 74.051 | 66.473 → 66.589 | 1.021x |
| wide | 72.524 → 70.645 | 63.937 → 63.915 | 1.026x |
| special | 19.141 → 18.980 | 26.520 → 26.520 | 1.009x |

Both new processes improved the normal and wide ratios relative to both
old processes. The improvement is small and workload-specific; the new
normal row is still about 1.11x slower than the matching CORE-MATH row.
CPU scaling, ASLR, and an active SMT sibling remain sources of noise.
Each of the four MPFR-512 audits has 1,476 accepted rows; all available
zmath and CORE-MATH rows recorded zero ULP, nonfinite, and signed-zero
discrepancies. All four audit files are byte-identical (SHA256
`09e3db1c42efc690d3e40a9b804657fa0d2f0be436004234e01bb415b018940d`).
Each timing receipt has all six selected rows and nine repetitions; remote
and downloaded local receipt hashes match. The eight JSON files are in
`bench/results/optpass-round2-20260927-buildhost/`. This sampled audit
does not prove whole-domain correctly rounded behavior.

The final qualified unit tests and the sibling testing-project build pass.
The final corpus replay covered 315 descriptors and 63,160,084 records.

The sections below describe the 2026-09-09 snapshot, not new recommendations
for the current runtime tree.

## Decisions

The 1.5x target is not met across the matrix. Correctness comes first.

1. Repair the `atan f64` high-limb assignment. It produces large finite errors.
2. Restore three `hypot f64` threshold constants. A temporary copy demonstrated a 2.88x normal-case improvement.
3. Add the missing certified `tan f64` fast stage. Ordinary calls currently execute the exact fallback.
4. Develop certified wide-ratio shortcuts for `atan2 f64` and `atan2pi f64`. Their multiword arithmetic dominates the profiles.
5. Evaluate direct CORE half kernels for hyperbolic `tanh` and `atanh`.
6. Then investigate `log10` exact-power lookup, `sinh` branch-local work, and measured wrapper or code-placement costs.

This work changes only the testing repository. Runtime source remains unchanged.
The `hypot` experiment compiled a temporary source copy, not the runtime tree.
No proposed optimization may weaken correct rounding or require a new ISA.

## Sources and coverage

`devenv.nix` supplies complete local source trees and an independent CORE-MATH DSO.

| Resource | Identity | Environment variable |
|---|---|---|
| CORE-MATH | `3bafed75e3c22399531857d63a3fa0e24bfb42fa` | `ZMATH_CORE_MATH_SOURCE_DIR` |
| glibc | Nix `glibc-2.42-67`, upstream 2.42, 14 patches | `ZMATH_GLIBC_SOURCE_DIR` |
| CORE-MATH reference | 121 independently compiled kernels | `ZMATH_COMPARE_COREMATH_PATH` |

Current source paths:

```text
/nix/store/798bv2dbin775vxdimh11p0qhfgz5jcl-core-math-3bafed75e3c22399531857d63a3fa0e24bfb42fa-source
/nix/store/i242829wlk2xaa7jnl9zkz4j6in57126-glibc-2.42-67-source
```

Each source tree contains `.zmath-source-provenance`.
The glibc marker records the package identity, patch names, and post-patch status.
The CORE archive uses the fixed hash `sha256-6BaQd5HqWk6mHbqciryRYy3kSqS7aJEgGDUy1f3lVaQ=`.

CORE compilation uses GCC 15.3.0 and these flags:

```text
-O3 -g -std=gnu11 -march=haswell -mtune=haswell -mfma -fPIC -frounding-math -ffp-contract=off
```

Each kernel compiles separately. The DSO uses a restricted export map, `-Bsymbolic`, and `-z defs`.
The loader uses `RTLD_LOCAL` and `RTLD_DEEPBIND` to prevent accidental binding to zmath's embedded CORE symbols.
The runner validates symbol origins, revision, flags, compiler, source paths, and the DSO hash.

| Provider | f16 kernels | f32 kernels | f64 kernels | Timing rows |
|---|---:|---:|---:|---:|
| zmath | 41 | 41 | 41 | 369 |
| Zig | 13 | 26 | 26 | 195 |
| glibc | 0 | 41 | 41 | 246 |
| CORE-MATH | 41 | 40 | 40 | 363 |
| Total | | | | 1173 |

There are 41 operations, three formats, three distributions, and four providers.
The complete audit contains 1,476 records and 303 explicit unsupported records.
CORE has no standalone binary32 or binary64 `sqrt` source. glibc supplies no binary16 symbols.
Unsupported cells receive no composed fallback or fabricated timing.
Zig availability must match its exact supported matrix in both the executable and runner.
API aliases such as `logp1` share a kernel and do not add distinct comparisons.

## Measurement method and limits

The target is `median(zmath) / median(reference) <= 1.5` for each operation, format, and distribution.
Apply it separately to each available reference. An overall average does not satisfy this target.

The profile is x86_64 Linux GNU 2.38, Haswell, ReleaseSafe, and Zig 0.16.0.
The host is an Intel i7-9750H. The recorded governor is `performance`, with turbo disabled.
Both runs pin CPU 7. Pinning does not isolate its SMT sibling or shared caches.

Each timed batch makes 1,024 calls through an opaque typed C function pointer.
Input generation, conversion, auditing, and provider lookup occur outside timing.
All providers receive the same input digest for a case.
Google Benchmark reports CPU nanoseconds per batch. The runner divides by 1,024.
These are scalar-throughput measurements, not dependency-chain latency or SIMD measurements.

| Run | Warmup | Minimum measurement | Repetitions | Selected rows |
|---|---:|---:|---:|---:|
| Full matrix | 0.1 s | 0.2 s | 5 | 1173/1173 |
| Focused repeat | 0.2 s | 0.5 s | 7 | 32/32 |

The full run's median row CV is 15.01%. 1,023 of 1,173 rows exceed 5% CV.
The focused repeat's median row CV is 9.89%. Its maximum is 23.11%.
These results support triage. They do not certify cases close to 1.5x.
The largest gaps repeat despite the variance.

Raw full-matrix counts below 1.5x are 181/246 against glibc and 337/363 against CORE.
These counts are not acceptance claims. They include noisy timings and the known `atan` defect.

The full run precedes the stricter Zig-availability check. The focused run uses the final executable.
The bridge and workload objects remained unchanged and cached across that rebuild.
Each run retains its own source hashes and binary identity:

```text
full:    ff2c3337a7ebd82ecc4fd96c799843d3ca2fc3f430aead23fd3b19d216fdce5f
focused: 7729d4a22ac5b2c555aa1f62834131287c8dbae7633db31019a78db368d904ee
```

[The CSV matrix](reference-performance-matrix.csv) contains 369 full-run cases and 12 focused cases.
It preserves all provider medians, ranges, CVs, numerical audit counters, and paired ratios.
`FILTERED` differs from `UNSUPPORTED`. Ratios never combine measurements from different runs.

## Correctness blocker: atan f64

The finite audit found errors in both ordinary `atan f64` buckets.
A concrete witness is:

```text
input bits: 0x3f7d7065405b4000
input:      0x1.d7065405b4p-8
zmath:      0x1.d704203de29eep-8
CORE/glibc: 0x1.d704408192854p-8
ULP gap:    8660909670
```

`Z/src/scalar_atan.zig:211` assigns the returned high product to `coefficient_low`.
The helper also writes its low product through that variable's pointer.
The assignment overwrites the low product and leaves `high` unchanged.
CORE instead assigns the return to `ch` at `C/src/binary64/atan/atan.c:65`.

The normal bucket has 36 mismatches among 1,024 inputs. The wide bucket has 19.
Their maximum ULP distances are 8,660,909,670 and 6,081,795,140 respectively.
Repair this destination before interpreting `atan f64` performance as acceptable.
`atanRefine` is already out of line in the inspected executable.

Other sampled finite zmath outputs have zero observed ULP distance.
The audit also records 408 special class/sign differences: 144 for `hypot`, 72 for `pow`, and 192 for `rsqrt`.
MPFR conversion can lose signaling-NaN information. Special-value conventions also differ.
Interpret those rows against the documented contract, not as automatic correctness passes or failures.
All sampled signed-zero mismatch counters are zero.

MPFR-512 RNE is numerical evidence, not a formal correct-rounding proof.
`wide` stresses finite exponents. It is not an exhaustive rounding-hard corpus.
The `lgamma` comparison covers `log(abs(Gamma(x)))`, not its sign result.

A separate CORE comparison exercised 10,813,440 binary16 evaluations with zero recorded mismatches.
Unary coverage included every half bit pattern. Binary coverage used 16 partners in both argument orders, not every possible pair.
The probe ignored NaN payload differences.

## Repeated worst cases

These values come from the focused repeat, not the noisier full-matrix maxima.
Times are median nanoseconds per call.

| Function | Format | Distribution | zmath ns | glibc ns | CORE ns | zmath/glibc | zmath/CORE |
|---|---|---|---:|---:|---:|---:|---:|
| atan2 | f64 | normal | 37.299 | 52.465 | 39.659 | 0.711x | 0.940x |
| atan2 | f64 | wide | 1970.570 | 38.313 | 2534.254 | 51.433x | 0.778x |
| tan | f64 | normal | 1111.119 | 26.114 | 49.796 | 42.548x | 22.313x |
| tan | f64 | wide | 1126.887 | 26.798 | 57.987 | 42.050x | 19.433x |
| hypot | f64 | normal | 91.627 | 28.408 | 33.767 | 3.225x | 2.714x |
| hypot | f64 | wide | 17.208 | 14.664 | 22.477 | 1.174x | 0.766x |
| atan2pi | f64 | normal | 61.390 | 56.818 | 47.058 | 1.080x | 1.305x |
| atan2pi | f64 | wide | 642.511 | 38.992 | 426.862 | 16.478x | 1.505x |
| tanh | f16 | normal | 27.066 | N/A | 14.463 | N/A | 1.871x |
| tanh | f16 | wide | 23.724 | N/A | 12.490 | N/A | 1.900x |
| atanh | f16 | normal | 30.562 | N/A | 17.983 | N/A | 1.699x |
| atanh | f16 | wide | 30.776 | N/A | 18.595 | N/A | 1.655x |

CORE itself takes 1.91x to 2.16x glibc time for these `tan f64` cases.
Adding CORE's fast stage removes the largest port gap. It does not, alone, establish the 1.5x glibc target.
The `atan2 f64` wide gap also exists in CORE. Replacing zmath with CORE would not solve it.

## Confirmed hypot threshold opportunity

The source comparison found three constants with a missing hexadecimal digit.
They occur at `Z/src/scalar_hypot.zig:379-380`.
CORE's corresponding predicate is at `C/src/binary64/hypot/hypot.c:277-278`.

| Purpose | Current zmath | CORE-equivalent value |
|---|---|---|
| Midpoint center | `0x3c9_0000_0000_0000` | `0x3c90_0000_0000_0000` |
| Lower residual bound | `0x39b_0000_0000_0000` | `0x39b0_0000_0000_0000` |
| Upper residual bound | `0x3c9_ffff_ffff_ff80` | `0x3c9f_ffff_ffff_ff80` |

The incorrect predicate sends ordinary inputs through exact u128 work.
The temporary candidate changes only these three constants.
It matched the baseline and CORE on 2,100,224 pairs, ignoring NaN payloads.
That sample includes all three matrix distributions, random full-width bit patterns, and equally scaled normal operands.
Its MPFR audit has zero finite ULP errors in all three distributions.
It retains the same 48 special class differences in the special bucket.

The temporary timing probe used the same normal inputs and opaque C ABI on CPU 7.
It measured thread CPU time for 16,384 batches per sample, with nine repetitions and rotated provider order.
This probe is separate from the Google Benchmark matrix.

| Provider | Median ns/call | CV |
|---|---:|---:|
| zmath | 71.695 | 5.05% |
| candidate | 24.925 | 18.83% |
| coremath | 26.188 | 23.18% |
| glibc | 20.921 | 16.27% |

The candidate takes 0.348x baseline time, 1.191x glibc time, and 0.952x CORE time.
This establishes a strong optimization candidate, not final performance acceptance under the observed variance.
No runtime fix was applied here. A separate runtime change must verify the restored guard and boundary outputs.
Keep a targeted throughput measurement to detect this regression. A source-constant assertion would not defend the external performance contract.

## Sampled CPU profiles

The temporary probe used `perf record -F 997 -e cycles:u` with DWARF call stacks.
All eight profiles reported zero lost samples. Percentages below are self-cycle samples, not wall-time shares.

| Case | Dominant sampled work |
|---|---|
| zmath tan f64 normal | `divideDint` 55.65%, `addDint` 22.23% |
| CORE tan f64 normal | `cr_tan` 96.22% |
| zmath atan2 f64 wide | `add_tint` 42.91%, `mul_tint` 40.72% |
| CORE atan2 f64 wide | `atan2_accurate` 59.82%, plus visible floating-environment calls |
| zmath atan2pi f64 wide | tint add 38.38%, tint multiply 38.35% |
| zmath hypot f64 normal | comparison wrapper and inlined kernel 95.61% |
| candidate hypot f64 normal | candidate wrapper and inlined kernel 95.72% |
| CORE hypot f64 normal | `cr_hypot` 85.30%, `__fmax` 4.90% |

For tangent, avoid accurate arithmetic on certified ordinary inputs before optimizing individual Dint instructions.
For wide `atan2`, investigate a certified interval before the degree-29 rational fallback.
CORE already takes its accurate path when the exponent gap reaches about 53 bits.
Its exact-quotient shortcut does not cover every ordinary wide-ratio input.
A new shortcut must preserve quadrant constants, division residuals, subnormal handling, and unresolved results.

## Complete function scorecard

Each cell shows the largest full-run ratio for that function and reference, followed by its case.
These are workload maxima, not worst-input complexity bounds. Use the CSV for every format and distribution.
All speed opportunities outside the measured `hypot` experiment remain hypotheses.

| Function | Worst glibc comparison | Worst CORE comparison |
|---|---|---|
| [exp](#exp) | 1.633x, f32/wide | 1.402x, f64/wide |
| [log](#log) | 1.747x, f64/wide | 1.179x, f64/wide |
| [sin](#sin) | 4.373x, f64/wide | 1.398x, f32/wide |
| [cos](#cos) | 2.500x, f64/wide | 1.460x, f32/normal |
| [tan](#tan) | 34.061x, f64/wide | 15.286x, f64/normal |
| [sqrt](#sqrt) | 0.942x, f64/normal | 1.163x, f16/wide |
| [hypot](#hypot) | 4.332x, f64/normal | 4.234x, f64/normal |
| [atan2](#atan2) | 48.063x, f64/wide | 1.760x, f32/normal |
| [pow](#pow) | 3.854x, f64/special | 1.742x, f64/wide |
| [acos](#acos) | 1.397x, f64/normal | 1.275x, f64/wide |
| [acosh](#acosh) | 1.077x, f64/wide | 1.169x, f64/wide |
| [acospi](#acospi) | 1.278x, f64/wide | 1.240x, f16/wide |
| [asin](#asin) | 1.577x, f64/wide | 1.437x, f64/wide |
| [asinh](#asinh) | 1.535x, f64/special | 1.267x, f64/wide |
| [asinpi](#asinpi) | 1.890x, f64/special | 1.201x, f64/normal |
| [atan (correctness blocked)](#atan) | 1.374x, f64/special | 1.177x, f64/wide |
| [atan2pi](#atan2pi) | 9.805x, f64/wide | 1.939x, f64/normal |
| [atanh](#atanh) | 1.538x, f64/special | 1.829x, f16/normal |
| [atanpi](#atanpi) | 1.730x, f32/wide | 2.059x, f32/wide |
| [cbrt](#cbrt) | 1.244x, f32/wide | 1.401x, f16/normal |
| [cosh](#cosh) | 1.671x, f64/normal | 1.964x, f32/wide |
| [cospi](#cospi) | 1.272x, f64/normal | 1.426x, f32/normal |
| [erf](#erf) | 2.111x, f32/special | 2.197x, f32/special |
| [erfc](#erfc) | 3.060x, f64/wide | 1.108x, f32/normal |
| [exp10](#exp10) | 2.884x, f32/wide | 1.610x, f32/wide |
| [exp10m1](#exp10m1) | 2.348x, f64/normal | 1.100x, f64/wide |
| [exp2](#exp2) | 2.039x, f64/normal | 1.437x, f32/wide |
| [exp2m1](#exp2m1) | 2.087x, f32/wide | 2.104x, f32/wide |
| [expm1](#expm1) | 1.637x, f64/special | 1.758x, f32/wide |
| [lgamma](#lgamma) | 1.146x, f32/normal | 1.494x, f64/normal |
| [log10](#log10) | 1.194x, f64/wide | 1.191x, f16/wide |
| [log10p1](#log10p1) | 2.561x, f64/special | 1.721x, f32/normal |
| [log1p](#log1p) | 1.730x, f64/special | 1.190x, f32/normal |
| [log2](#log2) | 2.266x, f64/normal | 1.375x, f64/special |
| [log2p1](#log2p1) | 2.940x, f64/special | 1.789x, f64/normal |
| [rsqrt](#rsqrt) | 2.212x, f64/wide | 1.114x, f32/normal |
| [sinh](#sinh) | 1.399x, f64/special | 1.477x, f32/normal |
| [sinpi](#sinpi) | 1.801x, f64/special | 1.259x, f32/normal |
| [tanh](#tanh) | 1.613x, f64/special | 2.248x, f16/normal |
| [tanpi](#tanpi) | 1.772x, f64/special | 1.942x, f32/wide |
| [tgamma](#tgamma) | 1.015x, f32/normal | 1.425x, f32/normal |

## Function-by-function source analysis

Source prefixes:

- `Z/`: the sibling `zmath/` runtime repository at the snapshot named above.
- `C/`: `ZMATH_CORE_MATH_SOURCE_DIR` at the pinned revision.
- `G/`: `ZMATH_GLIBC_SOURCE_DIR`, including the Nix patches.

Every function retains its documented NaN, zero, infinity, subnormal, overflow, and domain behavior.
Preserve explicit FMA order, interval bounds, exact tables, and accurate fallback paths.
No proposal permits fast-math, an approximate reciprocal, or an ISA-only replacement.
An x86 measurement does not establish performance or correctness on other targets.

`[INFERENCE]` marks an unmeasured implementation proposal, not a promised speedup.
The glibc source tree contains both LGPL code and permissive imports. Inspect each file's license before any port.
Do not transplant LGPL implementation code without a separate license decision.

### exp

**zmath:** f16 uses its dedicated half kernel. f32 uses expfFinite. f64 uses fast reduction, an interval, and accurate fallback.

**CORE-MATH:** The CORE-derived arithmetic is already present. No missing algorithm stage was identified.

**glibc:** f32/f64 use shorter approximations without an all-input correct-rounding guarantee.

**Decision / experiment [INFERENCE]:** Inspect round-even lowering and hot-body size. Keep the interval and accurate fallback.

Source locations:

- `Z/src/scalar.zig:395-421,1363-1438,1602-1818`
- `C/src/binary16/exp/expf16.c:1035-1051`
- `C/src/binary32/exp/expf.c:42-115`
- `C/src/binary64/exp/exp.c:300-421`
- `G/sysdeps/ieee754/flt-32/e_expf.c:31-112`
- `G/sysdeps/ieee754/dbl-64/e_exp.c:41-158`

### log

**zmath:** f16 uses tables. f32 widens table and polynomial arithmetic. f64 uses fastLog, an interval, and Dint accurateLog.

**CORE-MATH:** The reduction and rounding stages follow CORE.

**glibc:** Smaller tables and lower-degree approximations trade away the CORE ambiguity certificate.

**Decision / experiment [INFERENCE]:** Inspect Dint copies only when fallback profiles justify it. Do not replace the algorithm.

Source locations:

- `Z/src/root.zig:138-143`
- `Z/src/scalar.zig:980-997,1133-1200`
- `Z/src/logd.zig:996-1049`
- `C/src/binary16/log/logf16.c:582-605`
- `C/src/binary32/log/logf.c:58-133`
- `C/src/binary64/log/log.c:517-533,638-702`
- `G/sysdeps/ieee754/dbl-64/e_log.c:48-142`
- `G/sysdeps/ieee754/flt-32/e_logf.c:22-94`

### sin

**zmath:** f16 uses four tables and FMA. f32 reduces in f64. f64 uses a fast interval and Dint fallback.

**CORE-MATH:** The main CORE stages are present.

**glibc:** f32 uses a shorter reduction. f64 uses the IBM kernel with architecture dispatch. Neither establishes strict correct rounding.

**Decision / experiment [INFERENCE]:** Measure f64 fallback frequency and normal/wide reduction cost. Preserve the full-range reduction bounds.

Source locations:

- `Z/src/root.zig:218-223`
- `Z/src/scalar.zig:1022-1057,1934-2020,2020-2080`
- `C/src/binary16/sin/sinf16.c:2012-2042`
- `C/src/binary32/sin/sinf.c:83-119,181-222`
- `Z/src/scalar_sind.zig:53-71,536-676`
- `C/src/binary64/sin/sin.c:1759-1873,2035-2090`
- `G/sysdeps/ieee754/flt-32/s_sinf.c:36-92`
- `G/sysdeps/ieee754/dbl-64/s_sin.c:198-253`

### cos

**zmath:** f16 uses tables. f32 has widened reduction and five hard cases. f64 has fast and accurate stages.

**CORE-MATH:** The CORE-derived stages and hard cases are present.

**glibc:** f32/f64 use shorter approximate kernels with architecture dispatch.

**Decision / experiment [INFERENCE]:** Measure table locality and fallback frequency. Keep all five f32 hard-case corrections.

Source locations:

- `Z/src/root.zig:240-245`
- `Z/src/scalar.zig:1086-1108,2230-2260`
- `C/src/binary16/cos/cosf16.c:2012-2034`
- `C/src/binary32/cos/cosf.c:128-205`
- `Z/src/scalar_sind.zig:682-805`
- `C/src/binary64/cos/cos.c:1749-1862,2023-2067`
- `G/sysdeps/ieee754/flt-32/s_cosf.c:36-87`
- `G/sysdeps/ieee754/dbl-64/s_sin.c:264-318`

### tan

**zmath:** f16 uses tables. f32 uses rational evaluation and eight hard cases. Ordinary f64 calls always use tanAccurate.

**CORE-MATH:** The complete tan_fast interval stage is missing from zmath f64.

**glibc:** f32 is CORE-derived. The IBM f64 source reports about 0.619 ULP from random sampling.

**Decision / experiment [INFERENCE]:** Port the complete certified fast stage. Keep Dint for ambiguity and poles. Do not divide separately rounded sin and cos.

Source locations:

- `Z/src/scalar_tanh.zig:8239-8275`
- `Z/src/scalar_tanf.zig:104-179`
- `Z/src/scalar_tand.zig:34-47`
- `Z/src/scalar_sind.zig:879-927`
- `C/src/binary16/tan/tanf16.c:2012`
- `C/src/binary32/tan/tanf.c:131`
- `C/src/binary64/tan/tan.c:1944-2080,2245-2297`
- `G/sysdeps/ieee754/flt-32/s_tanf.c:1-25`
- `G/sysdeps/ieee754/dbl-64/s_tan.c:1-46`

### sqrt

**zmath:** All formats use @sqrt after special-value checks. Haswell f16 already lowers to widen, sqrt, and narrow instructions.

**CORE-MATH:** Only binary16 has a standalone CORE source. Binary32 and binary64 remain unsupported reference cells.

**glibc:** The x86 implementation also selects hardware builtins.

**Decision / experiment:** Keep the current kernel. No measured algorithm change is justified.

Source locations:

- `Z/src/scalar_sqrt.zig:26-44,49-90`
- `C/src/binary16/sqrt/sqrtf16.c:41-53`
- `G/sysdeps/x86_64/fpu/math-use-builtins-sqrt.h:1-4`
- `G/sysdeps/ieee754/flt-32/e_sqrtf.c:21-67`
- `G/sysdeps/ieee754/dbl-64/e_sqrt.c:51-145`

### hypot

**zmath:** f16 widens to f64. f32 refines boundaries. f64 has compensated arithmetic and an exact u128 fallback.

**CORE-MATH:** Three f64 fallback thresholds lost a hexadecimal digit. The isolated corrected copy removes the ordinary-case slowdown.

**glibc:** f32 uses a widened square sum. The f64 FMA path documents about 0.948 ULP, not correct rounding.

**Decision / experiment:** Restore all three CORE constants. Verify guard equivalence and boundary outputs. Retain the exact fallback.

Source locations:

- `Z/src/scalar_hypot.zig:161-219,250-389`
- `C/src/binary16/hypot/hypotf16.c:56`
- `C/src/binary32/hypot/hypotf.c:43`
- `C/src/binary64/hypot/hypot.c:261-281`
- `G/sysdeps/ieee754/flt-32/e_hypotf.c:1-42`
- `G/sysdeps/ieee754/dbl-64/e_hypot.c:19-93`

### atan2

**zmath:** f16/f32 call CORE kernels. f64 preserves a checked result and enters accurate arithmetic for large exponent gaps.

**CORE-MATH:** CORE has the same expensive gap fallback. zmath already avoids some CORE floating-environment work.

**glibc:** f32 is CORE-derived. The IBM f64 kernel uses constant and quotient shortcuts for large exponent gaps.

**Decision / experiment [INFERENCE]:** Develop certified RNE gap shortcuts by quadrant and division residual. Preserve subnormal handling and unresolved results.

Source locations:

- `Z/src/scalar_atan2.zig:82-136,145-199,202-269`
- `Z/src/coremath_atan2d.c:735-814,1043-1120`
- `C/src/binary16/atan2/atan2f16.c:104`
- `C/src/binary32/atan2/atan2f.c:95`
- `C/src/binary64/atan2/atan2.c:520-583`
- `G/sysdeps/ieee754/flt-32/e_atan2f.c:1-26`
- `G/sysdeps/ieee754/dbl-64/e_atan2.c:1-28,178-205`

### pow

**zmath:** The Zig wrapper owns special, domain, and parity rules. Finite evaluation calls CORE-derived C kernels.

**CORE-MATH:** Keep the staged accurate and exact-power paths.

**glibc:** Its source reports about 0.82 ULP for f32 and 0.54 ULP for f64. These are not strict CR replacements.

**Decision / experiment [INFERENCE]:** Measure negative-base and special buckets before combining integer/parity checks. Test finite-wrapper overhead separately.

Source locations:

- `Z/src/scalar_pow.zig:8-10,28-99,101-160,162-222,224-285`
- `Z/src/coremath_powh.c:34-40,196-284`
- `Z/src/coremath_powf.c:144-150,303-304,422-493`
- `Z/src/coremath_powd.c:67-82,1468-1480,1677-1865`
- `C/src/binary16/pow/powf16.c:124-190,206-324`
- `C/src/binary32/pow/powf.c:328-493`
- `C/src/binary64/pow/pow.c:80-87,1495-1510,1704-1900`
- `G/sysdeps/ieee754/flt-32/e_powf.c:27-43,123-151,145-236`
- `G/sysdeps/ieee754/dbl-64/e_pow.c:24-46,252-285,320-380`

### acos

**zmath:** All formats use native ports. f64 uses table reduction, double-double arithmetic, an interval, and acosRefine.

**CORE-MATH:** The direct CORE algorithm and refinement are present.

**glibc:** f32 is CORE-derived. The IBM f64 path lacks the same interval certificate.

**Decision / experiment [INFERENCE]:** Measure refinement frequency and coefficient layout. Keep endpoint handling and the exact fallback.

Source locations:

- `Z/src/scalar_acos.zig:138-182,200-308;445-515`
- `C/src/binary16/acos/acosf16.c:61-117`
- `C/src/binary64/acos/acos.c:138-287`
- `G/sysdeps/ieee754/flt-32/e_acosf.c:69-130`
- `G/sysdeps/ieee754/dbl-64/e_asin.c:183-334`

### acosh

**zmath:** Each precision has a dedicated kernel. f64 uses polynomial, table, double-double, and refinement paths.

**CORE-MATH:** The CORE-derived branches and corrections are present.

**glibc:** f32 is CORE-derived. f64 composes log and sqrt without the same rounding certificate.

**Decision / experiment [INFERENCE]:** Inspect refinement frequency and spills. Do not replace the kernel with a log/sqrt composition.

Source locations:

- `Z/src/scalar_acosh.zig:104-147,156-255,512-643`
- `C/src/binary16/acosh/acoshf16.c:67-143`
- `C/src/binary64/acosh/acosh.c:203`
- `G/sysdeps/ieee754/flt-32/e_acoshf.c:47-107`
- `G/sysdeps/ieee754/dbl-64/e_acosh.c:35-67`

### acospi

**zmath:** The Zig wrapper handles special values and endpoints. Finite inputs call direct inverse-pi C kernels.

**CORE-MATH:** f64 retains CORE tables, double-double arithmetic, hard cases, and accurate fallback.

**glibc:** f32 is CORE-derived. f64 composes acos and division by pi.

**Decision / experiment [INFERENCE]:** Measure wrapper overhead separately. Keep direct inverse-pi evaluation and endpoint bits.

Source locations:

- `Z/src/scalar_pi_inverse.zig:131-179`
- `Z/src/coremath_pi_inverseh.c:188-254`
- `Z/src/coremath_pi_inversef.c:143-226`
- `Z/src/coremath_pi_inversed.c:1282-1545;1636-1782`
- `C/src/binary64/acospi/acospi.c:935-1088`
- `G/sysdeps/ieee754/flt-32/s_acospif.c:35-88`
- `G/math/s_acospi_template.c:1-36`

### asin

**zmath:** Native kernels handle domain and endpoints first. f64 uses a table, an interval, asinRefine, and asinDatabase.

**CORE-MATH:** The direct CORE paths and hard cases are present.

**glibc:** f32 is CORE-derived. The IBM f64 path lacks the same interval fallback.

**Decision / experiment [INFERENCE]:** Measure refinement and database frequency before changing code placement or coefficient layout.

Source locations:

- `Z/src/scalar_asin.zig:71-134,151-233,281-441;443-544`
- `C/src/binary16/asin/asinf16.c:56-135`
- `C/src/binary32/asin/asinf.c:66-118`
- `C/src/binary64/asin/asin.c:115-246`
- `G/sysdeps/ieee754/flt-32/e_asinf.c:61-118`
- `G/sysdeps/ieee754/dbl-64/e_asin.c:47-178`

### asinh

**zmath:** Each precision has a dedicated CORE-derived kernel. f64 keeps accurate intervals, refinement, and database corrections.

**CORE-MATH:** No missing algorithm stage was identified.

**glibc:** f32 is CORE-derived. f64 uses a sqrt/log composition.

**Decision / experiment [INFERENCE]:** Measure table handling and refinement frequency. Preserve all cancellation and tiny-input paths.

Source locations:

- `Z/src/scalar_asinhh.zig:33-88`
- `Z/src/scalar_asinhd.zig:223-332`
- `C/src/binary16/asinh/asinhf16.c:71-143`
- `C/src/binary64/asinh/asinh.c:178-487`
- `G/sysdeps/ieee754/flt-32/s_asinhf.c:34-95`
- `G/sysdeps/ieee754/dbl-64/s_asinh.c:36-69`

### asinpi

**zmath:** Special values and endpoints stay in Zig. Finite inputs call direct kernels. f64 uses integer and multiword arithmetic.

**CORE-MATH:** The direct inverse-pi corrections and scaling remain present.

**glibc:** f32 is CORE-derived. f64 composes asin and division by pi.

**Decision / experiment [INFERENCE]:** Measure wrapper cost on ordinary and endpoint buckets. Preserve multiword corrections and payload policy.

Source locations:

- `Z/src/scalar_pi_inverse.zig:86-125`
- `Z/src/coremath_pi_inverseh.c:59-110`
- `Z/src/coremath_pi_inversef.c:38-111`
- `Z/src/coremath_pi_inversed.c:47-68;167-250;368-593`
- `C/src/binary64/asinpi/asinpi.c:447-593`
- `G/sysdeps/ieee754/flt-32/s_asinpif.c:36-86`
- `G/math/s_asinpi_template.c:1-45`

### atan

**zmath:** f16/f32 use dedicated reductions and rational evaluation. f64 has a proven high-limb assignment defect.

**CORE-MATH:** CORE assigns the multiplication result to ch. zmath overwrites coefficient_low instead and leaves high unchanged.

**glibc:** f32 is CORE-derived. The IBM f64 kernel is not an all-input CR replacement.

**Decision / experiment:** Repair correctness first. atanRefine is already out of line. Repeat the witnesses and refinement corpus before performance work.

Source locations:

- `Z/src/scalar_atan.zig:60-110,112-171,221-322;324-386,187-218`
- `C/src/binary16/atan/atanf16.c:67-149`
- `C/src/binary32/atan/atanf.c:43-117`
- `C/src/binary64/atan/atan.c:231-284`
- `G/sysdeps/ieee754/flt-32/s_atanf.c:33-113`
- `G/sysdeps/ieee754/dbl-64/s_atan.c:52-128`

### atan2pi

**zmath:** f16/f32 use direct C kernels. f64 preserves checked status and a tint ambiguity path.

**CORE-MATH:** The direct inverse-pi kernel avoids composition. Wide ratios still incur substantial multiword arithmetic.

**glibc:** f32 is CORE-derived. f64 composes atan2 and division by pi without the checked-result contract.

**Decision / experiment [INFERENCE]:** Develop certified wide-ratio intervals. Preserve unresolved status. Treat the measured 1.505x CORE ratio as inconclusive under current variance.

Source locations:

- `Z/src/scalar_pi_inverse.zig:227-367`
- `Z/src/scalar_c23_types.zig:20-29`
- `Z/build.zig:108-120;151-163`
- `Z/src/coremath_pi_inverseh.c:470-522`
- `Z/src/coremath_pi_inversef.c:367-489`
- `Z/src/coremath_pi_inversed.c:2995-3175;3622-3663`
- `C/src/binary64/atan2pi/atan2pi.c:212-265`
- `G/sysdeps/ieee754/flt-32/s_atan2pif.c:64-238`
- `G/math/s_atan2pi_template.c:1-41`

### atanh

**zmath:** f16 delegates finite work to atanhf. f32/f64 retain tables, intervals, refinement, and database paths.

**CORE-MATH:** CORE binary16 has a direct table, tiny FMA, hard cases, and degree-11 polynomial.

**glibc:** f32 is CORE-derived. f64 uses log1p without the same strict-RNE proof path.

**Decision / experiment [INFERENCE]:** Prototype the direct half kernel. Exhaustively audit all half inputs before accepting the measured opportunity.

Source locations:

- `Z/src/scalar_atanh.zig:504-512,73-143,413-503`
- `C/src/binary16/atanh/atanhf16.c:252-321`
- `C/src/binary64/atanh/atanh.c:160`
- `G/sysdeps/ieee754/flt-32/e_atanhf.c:45-178`
- `G/sysdeps/ieee754/dbl-64/e_atanh.c:53-79`

### atanpi

**zmath:** The wrapper calls direct kernels after special checks. f64 has tiny, asymptotic, table, and refinement branches.

**CORE-MATH:** The direct inverse-pi bounds and hard cases are present.

**glibc:** f32 is CORE-derived. f64 composes atan and division by pi.

**Decision / experiment [INFERENCE]:** Measure tiny, table, and asymptotic buckets. Do not replace direct atanpi with a quotient.

Source locations:

- `Z/src/scalar_pi_inverse.zig:185-221`
- `Z/src/coremath_pi_inverseh.c:312-405`
- `Z/src/coremath_pi_inversef.c:258-365`
- `Z/src/coremath_pi_inversed.c:1993-2025;2178-2250`
- `C/src/binary64/atanpi/atanpi.c:167-217,396-479`
- `G/sysdeps/ieee754/flt-32/s_atanpif.c:35-109`
- `G/math/s_atanpi_template.c:1-39`

### cbrt

**zmath:** f16 has special and hard-case handling around the float path. f32/f64 retain compensation and boundary corrections.

**CORE-MATH:** The certified interval and correction paths remain present.

**glibc:** f32 is CORE-derived. The shorter legacy f64 polynomial path lacks the same boundary proof.

**Decision / experiment [INFERENCE]:** Measure the half float-path overhead before factoring a finite helper. Keep every boundary correction.

Source locations:

- `Z/src/scalar_cbrt.zig:44-111,113-183,186-301`
- `C/src/binary16/cbrt/cbrtf16.c:41-79`
- `C/src/binary32/cbrt/cbrtf.c:64-116`
- `C/src/binary64/cbrt/cbrt.c:134-252`
- `G/sysdeps/ieee754/flt-32/s_cbrtf.c:1-34,34-99`
- `G/sysdeps/ieee754/dbl-64/s_cbrt.c:37-69`

### cosh

**zmath:** Each precision has a dedicated CORE-derived kernel. f64 uses double-double arithmetic, intervals, and refinement.

**CORE-MATH:** The staged algorithm is present.

**glibc:** f32 is CORE-derived. f64 composes expm1 and exp.

**Decision / experiment [INFERENCE]:** Inspect coshdPolydd slices and aggregate spills only if profiles show a cost. Keep interval and database logic.

Source locations:

- `Z/src/scalar_cosh.zig:16-34,68-149,445-602`
- `C/src/binary16/cosh/coshf16.c:2125-2141`
- `C/src/binary64/cosh/cosh.c:158-378`
- `G/sysdeps/ieee754/flt-32/e_coshf.c:34-94`
- `G/sysdeps/ieee754/dbl-64/e_cosh.c:41-85`

### cospi

**zmath:** The Zig wrapper classifies bits, then calls a direct C kernel for every finite input.

**CORE-MATH:** Finite evaluation already uses the CORE-derived kernel.

**glibc:** f32 is CORE-derived. f64 reduces and calls ordinary sin/cos.

**Decision / experiment [INFERENCE]:** Measure wrapper versus direct entry through the same ABI. Port only if measured savings justify the proof burden.

Source locations:

- `Z/src/root.zig:251-256`
- `Z/src/scalar_cospi.zig:1-10,28-59`
- `C/src/binary16/cospi/cospif16.c:1758-1788`
- `C/src/binary32/cospi/cospif.c:43-113`
- `C/src/binary64/cospi/cospi.c:140-205`
- `G/sysdeps/ieee754/flt-32/s_cospif.c:1-34,35-79`
- `G/math/s_cospi_template.c:1-39`

### erf

**zmath:** f16/f32 use generated native ports. f64 retains fast and accurate stages.

**CORE-MATH:** Keep the CORE tables, double-double arithmetic, and accurate fallback.

**glibc:** f32 follows a CORE-derived table path. f64 uses legacy rational and exponential approximations.

**Decision / experiment [INFERENCE]:** Separate ordinary table bins from tiny, saturation, and fallback bins before changing layout.

Source locations:

- `Z/src/root.zig:195-200`
- `Z/src/scalar_erfh.zig:47,631-694`
- `Z/src/scalar_erfd.zig:2867-2961,2962-4007,4011-4070`
- `C/src/binary16/erf/erff16.c:51-156`
- `C/src/binary64/erf/erf.c:243-332,336-645,647-710`
- `G/sysdeps/ieee754/flt-32/s_erff.c:33-256`
- `G/sysdeps/ieee754/dbl-64/s_erf.c:199-300`

### erfc

**zmath:** The Zig wrapper handles NaN policy before direct C kernels.

**CORE-MATH:** The asymptotic split, exact scaling, and subnormal correction are already present.

**glibc:** f32 is CORE-derived. f64 uses a legacy approximation without strict correct rounding.

**Decision / experiment [INFERENCE]:** Measure finite-wrapper and asymptotic costs separately. Keep exact scaling and underflow corrections.

Source locations:

- `Z/src/scalar_erfc.zig:7-43`
- `Z/src/coremath_erfch.c:80-149`
- `Z/src/coremath_erfcf.c:72-139`
- `Z/src/coremath_erfcd.c:47-100,813-1134,1215-1265`
- `C/src/binary64/erfc/erfc.c:792-909,1038-1043,1123-1253`
- `G/sysdeps/ieee754/flt-32/s_erfcf.c:81-187`
- `G/sysdeps/ieee754/dbl-64/s_erf.c:303-423`

### exp10

**zmath:** Each precision has a dedicated kernel. f32/f64 keep exact-power branches and reduction.

**CORE-MATH:** The exact integer handling and accurate fallback follow CORE.

**glibc:** f32/f64 use shorter table kernels without the same strict interval and database path.

**Decision / experiment [INFERENCE]:** Measure integer-heavy inputs and code placement. Preserve exact powers and rounding bounds.

Source locations:

- `Z/src/scalar_exp10h.zig:37-47`
- `Z/src/scalar_exp10f.zig:83-156`
- `Z/src/scalar_exp10d.zig:159-317`
- `C/src/binary16/exp10/exp10f16.c:1038-1056`
- `C/src/binary32/exp10/exp10f.c:77-148`
- `C/src/binary64/exp10/exp10.c:151-379`
- `G/sysdeps/ieee754/flt-32/e_exp10f.c:29-199`
- `G/sysdeps/ieee754/dbl-64/e_exp10.c:26-154`

### exp10m1

**zmath:** f16/f32 have direct kernels. f64 uses double-double reduction and separate tiny/main accurate paths.

**CORE-MATH:** The direct cancellation-safe algorithm and exception tables are present.

**glibc:** f32 is CORE-derived. f64 composes expm1 near zero and exp10 minus one elsewhere.

**Decision / experiment [INFERENCE]:** Measure exception frequency and accurate-code placement. Preserve compensated subtraction and all hard-case tables.

Source locations:

- `Z/src/scalar_exp10m1h.zig:39-84`
- `Z/src/scalar_exp10m1f.zig:68-270`
- `Z/src/scalar_exp10m1d.zig:183-304`
- `C/src/binary16/exp10m1/exp10m1f16.c:1039-1093`
- `C/src/binary32/exp10m1/exp10m1f.c:42-158`
- `C/src/binary64/exp10m1/exp10m1.c:600-1153`
- `G/sysdeps/ieee754/flt-32/s_exp10m1f.c:32-224`
- `G/math/s_exp10m1_template.c:21-45`

### exp2

**zmath:** Separate precision kernels retain exact integers. f64 has local double-double and accurate paths.

**CORE-MATH:** The CORE stages are present.

**glibc:** The shorter glibc kernels lack strict all-input correct rounding.

**Decision / experiment [INFERENCE]:** Inspect accurate-call placement and finite branch cost. Keep exact powers and interval checks.

Source locations:

- `Z/src/scalar_exp2.zig:34-53,68-139,275-422`
- `C/src/binary16/exp2/exp2f16.c:993-1016`
- `C/src/binary32/exp2/exp2f.c:68-133`
- `C/src/binary64/exp2/exp2.c:269-384`
- `G/sysdeps/ieee754/flt-32/e_exp2f.c:27-95`
- `G/sysdeps/ieee754/dbl-64/e_exp2.c:28-149`

### exp2m1

**zmath:** f16/f32 use direct kernels. f64 owns double-double reduction, exception searches, and fast/accurate stages.

**CORE-MATH:** The dedicated cancellation-safe algorithm remains present.

**glibc:** f32 is CORE-derived. f64 composes expm1 or subtracts one from exp2.

**Decision / experiment [INFERENCE]:** Measure accurate-code placement and tiny/general branch frequency. Preserve the exception data and subtraction order.

Source locations:

- `Z/src/scalar_exp2m1h.zig:34-72`
- `Z/src/scalar_exp2m1f.zig:34-190`
- `Z/src/scalar_exp2m1d.zig:183-362`
- `C/src/binary16/exp2m1/exp2m1f16.c:994-1045`
- `C/src/binary32/exp2m1/exp2m1f.c:42-146`
- `C/src/binary64/exp2m1/exp2m1.c:579-713,845-1021`
- `G/sysdeps/ieee754/flt-32/s_exp2m1f.c:35-191`
- `G/math/s_exp2m1_template.c:21-65`

### expm1

**zmath:** Dedicated precision kernels preserve tiny-input behavior. f64 combines a small table, fast reduction, and accurate fallback.

**CORE-MATH:** The direct algorithm and compensated subtraction are present.

**glibc:** f32 is CORE-derived. f64 uses the older Sun algorithm without strict correct rounding.

**Decision / experiment [INFERENCE]:** Measure hot-body size and database frequency. Never replace the small path with exp(x) minus one.

Source locations:

- `Z/src/scalar_expm1h.zig:37-70`
- `Z/src/scalar_expm1f.zig:80-165`
- `Z/src/scalar_expm1d.zig:39-122,295-489`
- `C/src/binary16/expm1/expm1f16.c:1034-1070`
- `C/src/binary32/expm1/expm1f.c:77-150`
- `C/src/binary64/expm1/expm1.c:156-439`
- `G/sysdeps/ieee754/flt-32/s_expm1f.c:33-124`
- `G/sysdeps/ieee754/dbl-64/s_expm1.c:139-268`

### lgamma

**zmath:** The wrapper owns value/sign special rules and calls CORE kernels through an out-sign ABI.

**CORE-MATH:** The double-double, table, and accurate stages remain present.

**glibc:** f32 is CORE-derived. f64 uses the older Sun reduction, Stirling, and reflection paths.

**Decision / experiment [INFERENCE]:** Measure positive inputs separately from reflection and ambiguity. The timing comparison covers log|Gamma|, not the returned sign.

Source locations:

- `Z/src/scalar_lgamma.zig:17-76,79-154`
- `Z/src/coremath_lgammah.c:89-186`
- `Z/src/coremath_lgammaf.c:82-258`
- `Z/src/coremath_lgammad.c:48-66,158-194,758-1030`
- `G/sysdeps/ieee754/flt-32/e_lgammaf_r.c:9-31,111-366`
- `G/sysdeps/ieee754/dbl-64/e_lgamma_r.c:13-78,203-312`

### log10

**zmath:** f16/f32 use direct kernels. f64 scans 23 exact powers before reduction, an interval, and Dint fallback.

**CORE-MATH:** CORE hashes the exponent to one candidate and performs one exact bit comparison.

**glibc:** f32 is CORE-derived. f64 uses an older nested-log algorithm.

**Decision / experiment [INFERENCE]:** Prove candidate-index equivalence for the 23 powers and all exponent classes. Then measure the scan replacement and exception behavior.

Source locations:

- `Z/src/root.zig:172-177`
- `Z/src/scalar_log10h.zig:2122-2138`
- `Z/src/scalar_log10f.zig:205-261`
- `Z/src/scalar_log10d.zig:1038-1131`
- `C/src/binary16/log10/log10f16.c:584-607`
- `C/src/binary32/log10/log10f.c:64-149`
- `C/src/binary64/log10/log10.c:534-550,690-750,722-735`
- `G/sysdeps/ieee754/dbl-64/e_log10.c:1-31,58-88`
- `G/sysdeps/ieee754/flt-32/e_log10f.c:1-161`

### log10p1

**zmath:** Zig handles special values and signed zero. Finite inputs call direct C kernels.

**CORE-MATH:** The f64 kernel keeps tiny, small, general, and accurate stages.

**glibc:** f32 is CORE-derived. f64 multiplies log1p by log10(e).

**Decision / experiment [INFERENCE]:** Measure wrapper cost through the same ABI. Keep direct evaluation, signed zero, and all intervals.

Source locations:

- `Z/src/root.zig:172-177`
- `Z/src/scalar_log10p1.zig:1-10,33-85`
- `Z/build.zig:60-64,225-235`
- `C/src/binary16/log10p1/log10p1f16.c:171-224`
- `C/src/binary32/log10p1/log10p1f.c:64-149`
- `C/src/binary64/log10p1/log10p1.c:1229-1236,1416-1471`
- `G/sysdeps/ieee754/flt-32/s_log10p1f.c:1-7,49-162`
- `G/math/s_log10p1_template.c:1-16,25-47`

### log1p

**zmath:** f16/f32 use widened arithmetic. f64 uses double-double evaluation and a multi-double refinement. logp1 shares this kernel.

**CORE-MATH:** The direct tiny, cancellation, and correction paths are present.

**glibc:** f32 is CORE-derived. f64 uses the older Sun algorithm.

**Decision / experiment [INFERENCE]:** Measure tiny, near-domain-boundary, ordinary, and forced-refinement inputs. Change layout only if measured.

Source locations:

- `Z/src/root.zig:431-437`
- `Z/src/scalar_log1p.zig:54-184`
- `Z/src/scalar_log1pd.zig:41-190`
- `C/src/binary16/log1p/log1pf16.c:162-224`
- `C/src/binary32/log1p/log1pf.c:59-140`
- `C/src/binary64/log1p/log1p.c:137,380-405`
- `G/sysdeps/ieee754/dbl-64/s_log1p.c:1-18,108-185`
- `G/sysdeps/ieee754/flt-32/s_log1pf.c:1-26,49-145`
- `G/sysdeps/x86_64/fpu/multiarch/s_log1p.c:28-31`

### log2

**zmath:** f16 uses tables. f32 widens polynomial arithmetic. f64 has double-double evaluation and quadripartite refinement.

**CORE-MATH:** The exact-power branch, table sizes, interval, and refinement are present.

**glibc:** Smaller tables and lower-degree polynomials lack the same ambiguity certificate.

**Decision / experiment [INFERENCE]:** Measure refinement placement and table access. Preserve exact powers, subnormal handling, and the interval.

Source locations:

- `Z/src/root.zig:149-154`
- `Z/src/scalar_log2h.zig:37-53`
- `Z/src/scalar_log2f.zig:85-125`
- `Z/src/scalar_log2d.zig:424-540`
- `C/src/binary16/log2/log2f16.c:578-601`
- `C/src/binary32/log2/log2f.c:59-125`
- `C/src/binary64/log2/log2.c:74-190`
- `G/sysdeps/ieee754/dbl-64/e_log2.c:48-140`
- `G/sysdeps/ieee754/flt-32/e_log2f.c:25-95`

### log2p1

**zmath:** Zig checks special bits, then calls direct C kernels for finite values.

**CORE-MATH:** Finite arithmetic already uses the CORE-derived direct algorithm.

**glibc:** f32 is CORE-derived. f64 multiplies log1p by log2(e).

**Decision / experiment [INFERENCE]:** Measure wrapper versus direct entry. Audit signed-zero behavior before considering a wrapper zero return.

Source locations:

- `Z/src/root.zig:160-165`
- `Z/src/scalar_log2p1.zig:1-10,36-70`
- `Z/build.zig:60-64,214-223`
- `C/src/binary16/log2p1/log2p1f16.c:171-224`
- `C/src/binary32/log2p1/log2p1f.c:59-124`
- `C/src/binary64/log2p1/log2p1.c:1801-1808,1994-2056`
- `G/sysdeps/ieee754/flt-32/s_log2p1f.c:1-7,35-124`
- `G/math/s_log2p1_template.c:1-16,24-43`

### rsqrt

**zmath:** f16 uses tables. f32 widens sqrt/division and repairs three hard cases. f64 has FMA residuals and exact refinement.

**CORE-MATH:** The direct correction and exact fallback are present.

**glibc:** The short reciprocal-of-sqrt template lacks the same rounding correction.

**Decision / experiment [INFERENCE]:** Inspect refinement placement and table locality. Do not substitute a reciprocal estimate or remove exact correction.

Source locations:

- `Z/src/scalar_rsqrt.zig:48-69,99-132,160-213,219-259`
- `Z/src/scalar_rsqrth_data.zig:24-31,162-165`
- `C/src/binary16/rsqrt/rsqrtf16.c:44-61,320-604`
- `C/src/binary32/rsqrt/rsqrtf.c:43-88`
- `C/src/binary64/rsqrt/rsqrt.c:119-165,168-212`
- `G/math/s_rsqrt_template.c:21-29`

### sinh

**zmath:** Each precision has a dedicated kernel. f64 computes negative-side table products and a polynomial before magnitude branches.

**CORE-MATH:** CORE places negative-side work inside branches that need it.

**glibc:** f32 is CORE-derived. f64 composes expm1 and exp.

**Decision / experiment [INFERENCE]:** Move only proven unnecessary work into its branches in a prototype. Measure assembly because the compiler may already sink some work.

Source locations:

- `Z/src/scalar_sinhh.zig:37-50`
- `Z/src/scalar_sinhf.zig:45-145`
- `Z/src/scalar_sinhd.zig:217-303`
- `C/src/binary16/sinh/sinhf16.c:2157-2176`
- `C/src/binary64/sinh/sinh.c:337-394`
- `G/sysdeps/ieee754/flt-32/e_sinhf.c:34-107`
- `G/sysdeps/ieee754/dbl-64/e_sinh.c:50-98`

### sinpi

**zmath:** f16/f32 use dedicated tables. f64 keeps double-double products, intervals, and targeted refinement.

**CORE-MATH:** The direct integer, half-integer, and refinement paths remain present.

**glibc:** f32 is CORE-derived. f64 reduces and calls ordinary sin/cos.

**Decision / experiment [INFERENCE]:** Measure table locality and sincosN2/refinement frequency. Preserve exact integer and half-integer results.

Source locations:

- `Z/src/root.zig:229-234`
- `Z/src/scalar_sinpih.zig:35-75`
- `C/src/binary16/sinpi/sinpif16.c:1759-1793`
- `Z/src/scalar_sinpif.zig:37-93`
- `C/src/binary32/sinpi/sinpif.c:42-116`
- `Z/src/scalar_sinpid.zig:226-324,327-428`
- `C/src/binary64/sinpi/sinpi.c:154-244,239-400`
- `G/sysdeps/ieee754/flt-32/s_sinpif.c:1-35,35-79`
- `G/math/s_sinpi_template.c:1-47`

### tanh

**zmath:** Hyperbolic tanh uses tanhh/tanhf/tanhd. The f16 middle range delegates to tanhf.

**CORE-MATH:** CORE binary16 directly evaluates table-based FMA sums and a quotient, including its hard case.

**glibc:** f32 is CORE-derived. f64 uses an expm1-based formula.

**Decision / experiment [INFERENCE]:** Prototype the direct half kernel. Exhaustively check all half values, saturation boundaries, and the 0xbfd5 case.

Source locations:

- `Z/src/scalar_tanh.zig:8330-8344,8346,8693-8847`
- `C/src/binary16/tanh/tanhf16.c:2157-2202`
- `C/src/binary64/tanh/tanh.c:179-387`
- `G/sysdeps/ieee754/flt-32/s_tanhf.c:33-89`
- `G/sysdeps/ieee754/dbl-64/s_tanh.c:55-100`

### tanpi

**zmath:** f16 uses table FMAs and division. f32 uses two ties-even reductions. f64 has multiple ranges and hard-case refinement.

**CORE-MATH:** The direct pole, quarter, integer, and correction paths are present.

**glibc:** f32 is CORE-derived. f64 calls ordinary tan and reciprocal.

**Decision / experiment [INFERENCE]:** Measure duplicate reduction work before combining it. Prove every quarter and halfway boundary first.

Source locations:

- `Z/src/root.zig:295-303`
- `Z/src/scalar_tanpih.zig:36-92`
- `C/src/binary16/tanpi/tanpif16.c:1763-1811`
- `Z/src/scalar_tanpif.zig:31-106`
- `C/src/binary32/tanpi/tanpif.c:81-130`
- `Z/src/scalar_tanpid.zig:53-102,147-174,247-478`
- `C/src/binary64/tanpi/tanpi.c:75-85,88-164,167-388`
- `G/sysdeps/ieee754/flt-32/s_tanpif.c:1-37,34-90`
- `G/math/s_tanpi_template.c:1-65`

### tgamma

**zmath:** The wrapper handles NaNs and poles before CORE C kernels.

**CORE-MATH:** Keep precision thresholds, hard cases, accurate paths, and exact subnormal scaling.

**glibc:** f32 is CORE-derived with a degree-15 polynomial and corrections. f64 uses recurrence, exp(lgamma), Stirling expansion, and reflection.

**Decision / experiment [INFERENCE]:** Measure positive, reflection, and wrapper costs separately. The sampled glibc f64 error reaches 4 ULP, so it is not a replacement.

Source locations:

- `Z/src/scalar_tgamma.zig:7-59,61-113`
- `Z/src/coremath_tgammah.c:45-59,75-153`
- `Z/src/coremath_tgammaf.c:10-30,41-156`
- `Z/src/coremath_tgammad.c:34-67,198-284,610-805`
- `C/src/binary64/tgamma/tgamma.c:42-53,208-303,629-853`
- `G/math/w_tgamma_template.c:1-53`
- `G/sysdeps/ieee754/flt-32/e_gammaf_r.c:1-32,85-174`
- `G/sysdeps/ieee754/dbl-64/e_gamma_r.c:1-17,47-118,165-208`

## Acceptance sequence for runtime changes

1. Change one function and precision at a time.
2. Establish exact predicate or error-bound equivalence before timing acceptance.
3. Retain the existing hard-case corpus and every ambiguous fallback.
4. Exhaustively audit binary16 changes. Audit higher precisions against MPFR and the pinned CORE kernels, with targeted boundary inputs.
5. Check payload, signaling-NaN, signed-zero, and exception contracts separately from MPFR numerical values.
6. Repeat normal, wide, special, and forced-hard measurements through the same ABI.
7. Require the 1.5x ratio separately against each available reference for each case.
8. Repeat near-threshold measurements on a less contended host before declaring acceptance.
9. Verify other supported targets before making a portability claim.

A new correct-rounding proof may be necessary for an algorithm that departs from CORE's certified stages.
Do not shrink tables, alter polynomial degree, or relax an error interval solely because a sampled audit passes.

## Verification and retained evidence

- Final `zig build compare --summary all`: 8/8 steps succeeded.
- Final evidence-loader suite: 28/28 tests passed.
- `zig fmt --check .`: passed.
- Clang-format checks for the five C/C++ comparison files: passed.
- Final full audit: 1,476 records, with 1,173 available timing cells.
- Full timing run: 1,173 rows, each with five repetitions.
- Focused timing repeat: 32 rows, each with seven repetitions.
- Independent ELF inspection: 121 expected CORE kernels and four metadata exports.
- Binary16 CORE probe: 10,813,440 evaluations with zero recorded mismatches.
- Isolated hypot candidate: 2,100,224 comparisons with zero mismatches, ignoring NaN payloads.

Coverage fault injection demonstrated the availability defect before the repair.
The old executable accepted 1,170 rows after removing supported `zig/sin/f16`.
It accepted 1,176 rows after adding unsupported `zig/atan2/f16`.
The final executable rejects both cases. The Python runner has matching rejection tests.

Local raw evidence:

```text
bench/results/run_20260909_103926/
bench/results/reference-focused-repeat/
bench/results/reference-final-audit-2/
bench/results/hypot-threshold-probe.json
bench/results/reference-profiles.json
bench/results/reference-probe-sources.zip
```

The committed CSV preserves the complete summarized matrix and the focused repeat.
The raw directories preserve timing samples, source hashes, input digests, binary identities, and framework diagnostics.
The probe archive preserves the temporary source files and experiment provenance.

To reproduce the complete comparison in the declared environment:

```sh
direnv exec . zig build compare
direnv exec . python3 bench/run_comparative.py --no-build --cpu=7
```

Use a CPU allowed by the process affinity mask. Do not reuse an existing output directory.
See [the comparison procedure](../test/corpus/README.md#comparative-google-benchmark-matrix) for all runner options.

Primary upstream repositories: [CORE-MATH](https://gitlab.inria.fr/core-math/core-math) and [glibc](https://sourceware.org/glibc/).
The local pinned trees, not moving upstream branches, define this analysis.

## API-surface round 2026-10-03

This round compares a frozen zmath source tree with measured optimization trees.
Both sides use the same SDK-independent `bench-api-round` harness and the same runner.
The portability checks and final-tree repeats are separate from the first measurement image.
It is not a new CORE-MATH/glibc comparison or numerical acceptance publication.
The earlier 1.5x reference criterion does not apply to this internal optimization round.

Three measured images appear below, and every number carries its image.
The final-v4 image is the primary one; the earlier cohorts are kept, not replaced.

| Image | Role | Runtime source digest | Benchmark executable SHA256 |
| --- | --- | --- | --- |
| Frozen | reference side of every cohort | `3fb1f666f503cc250` | `8dec706c3766ed553` |
| Optimization | 7,428-case coverage run and cohorts 06-18 | `c333efd356d3ca80` | `0979d723c02108db` |
| Final-v4 | primary measured image, cohorts 19-25 | `4f0461fe588b63b0` | `e01622851dd86b0b` |

### Environment and measurement rule

- Zig 0.16.0, target `x86_64-linux-gnu.2.38`, CPU `haswell`, `ReleaseSafe`.
- Linux x86-64 host: Intel Xeon Gold 6354, 72 logical CPUs.
- Measurements pinned to allowed CPU 0 with `taskset`. The shared host and clock frequency were not isolated.
- Retention rule: at least 2% lower median time and the same direction in at least eight of nine paired runs.
- Runs alternate AB/BA order. The percentage is `1 - candidate_median / baseline_median`, not the median paired ratio.
- Semantic checksums must match across versions, repetitions, and profile invocations.
- Failed attempts retain their full reserved binary32 charge. No refunds or independent per-agent budgets.
The retention rule is a practical heuristic, not a confidence interval.
It estimates no probability, no error bar and no significance for any row below.
Identical-image controls produced false faster and slower flags on this host.

Timed calls include input generation and result hashing.
For trivial methods, these costs can exceed the API cost.
LU/Cholesky solve and reconstruction use prepared factors outside their timed method loops.
Process profiles still include setup, dispatch, hashing, JSON output, and dynamic-loader work.
`perf record` used its default `cycles:Pu` event, without call graphs.
The runner's `--perf-events` flag selects `perf stat` events only.

### Complete selected surface

The complete timed coverage run has 7,428 named cases, four calls each, and one baseline/candidate pair.
It ran against the optimization image and is explicitly scoped `coverage_only`.
All sampled semantic checksums match.
That run establishes bounded coverage, not stable speed comparisons.

| Namespace | Named cases |
| --- | ---: |
| `ieee` | 141 |
| `scalar` | 828 |
| root umbrella | 117 |
| `vector` | 3,247 |
| `quaternion` | 137 |
| `complex` | 154 |
| `matrix` | 412 |
| `linalg` | 282 |
| `geometry` | 1,110 |
| `algebra` | 1,000 |
| **Total** | **7,428** |

The six bundles contain leaf 1,086, lanes 2,889, values 495, aggregates 848, geometry 1,110, and algebra 1,000 cases.
The portable-layer inventory covers 417 exports with direct, identical-canonical, or compile-only routes.
Lane measurements use widths 2, 4, and 8 with normal, boundary, and skewed inputs.
The three compile-only mapping helpers have explicit inventory entries.
All twelve concrete geometric algebras are included.
Generic matrix shapes are sampled classes, not every possible `Mat` instantiation.

The initial whole-surface run used four calls and one pair.
Larger profiling runs used geometry 24 calls, leaf/values/aggregates/algebra 64 calls, and lanes 32 calls.
These baseline/profile rounds also matched all sampled semantic checksums.

The final-v4 image was never re-run over all 7,428 cases, because that would spend the shared ledger again.
Instead an untimed replay of the final-v4 runtime tree reproduced the frozen baseline receipts of the
final coverage run: 7,428 cases, four calls each, zero clock reads, and zero mismatches, zero missing and
zero extra cases, exit 0. The replay executable is `459cbf31a3975bab`, its output digest is `b57dd9dd57d847a7`,
and it is bound to the final-v4 runtime tree digest.
This is a semantic equivalence check over the same surface, not a timing result for final-v4.

### Source and executable identity

The runner folds relative paths and file contents into one digest per tree.
Both source snapshots are packaged with this report and reconstruct their recorded digests exactly.

| Artifact | Files | Bytes | SHA256 |
| --- | ---: | ---: | --- |
| Frozen benchmark executable | - | 41,373,856 | `8dec706c3766ed55397bb3cf0c77c898175dbeb76d1061640d7fccc8668c19ea` |
| Frozen runtime source tree | 247 | - | `3fb1f666f503cc250ba57fedb252028a3dd6761e3d40c131bf825445d75b67d6` |
| Optimization benchmark executable | - | 41,403,544 | `0979d723c02108db2dce7d8dbe216dffaf617cc1720a2f125cdcb76e62edbaa2` |
| Optimization runtime source tree | 247 | - | `c333efd356d3ca80572850a9b37c50b2e94eaf37c9b81f72f0f9583837a40a48` |
| Final-v4 benchmark executable | - | 41,420,728 | `e01622851dd86b0b8c7dfba09bc29e06571667aad6bc69994b3b68242f92bd03` |
| Final-v4 runtime source tree | 247 | - | `4f0461fe588b63b0ba322a7433048a5ea432a1eeef0782ded985d3992261837a` |
| Runner `bench/run_api_round.py` | - | - | `16d95359ab487c89bfa410504acca938ce3cdeb760bcbf5f91989772a6bdc750` |
| Harness tree at the coverage run | 32 | - | `8974f9cc27d78cae0d8ed8a7b2bc0cf83779c6e79efb65f9d762122ca70f4080` |
| Harness tree at the final-v4 run | 34 | - | `b2648a58f0aa247b3760c0576355081f294be4a5c348d204502016a7bdd55c74` |

The per-file identity map of the final-v4 tree, hashed as a sorted path-to-digest JSON document,
is `d18dbfa5367f019badd2c679d131fffd95634534a49648011821a95427dd8370` over the same 247 files.
That is a different construction from the runner digest and the two must not be compared with each other.

Exactly seven files differ between the frozen tree and the final-v4 tree:

| File | Role |
| --- | --- |
| `src/scalar_power_exact.zig` | retained binary32/binary64 root scratch narrowing |
| `src/geometry.zig` | retained exact-predicate output buffers and scratch reuse |
| `src/geometry_test.zig` | added exact-orientation, containment and tangency references |
| `src/vector_value.zig` | `Vec` bridges publish named components by logical lane index |
| `src/vector_core.zig` | scoped boolean-mask publication workaround |
| `src/vector_value_test.zig` | added lane-order and mask-width regression tests |
| `src/vector_surface_test.zig` | added one-hot lane coverage tests |

`src/algebra.zig` is unchanged, byte for byte, between the two trees.

Every measurement receipt in this section belongs to the final-v4 image and to nothing later. The edits to
`src/vector_core.zig` and `src/vector_surface_test.zig` postdate that image and are covered by the
whole-tree correctness receipts under
[Runtime verification status](#runtime-verification-status), which contain no timing. The measured source
tree, the benchmark executable and every number here stay bound to the final-v4 digests above; nothing is
re-baselined onto later source.

### Profiles and retained changes

The pre-optimization candidate profiles identified two integer-scratch costs:

| Bundle | Observed self-time |
| --- | --- |
| Leaf | `compiler_rt.memset` 89.79% |
| Lanes | `compiler_rt.memset` 95.44% |
| Geometry | `compiler_rt.memset` 67.17%; `memcpyFast` 16.54% |
| Values | Harness `main` 75.18%, from only 47 samples |
| Aggregates | Harness `main` 38.96%; matrix multiplication 3.38% |
| Algebra | Harness `main` 13.31%; Cga4d geometric product 6.87% |

**Retain binary32/binary64 exact-root scratch narrowing.**
Root storage falls from 256 to 53 limbs for binary32 and from 2,048 to 111 limbs for binary64.
Virtual alignment compares shifted integer views instead of materializing alignment buffers.
The conservative bound is derived from precision and maximum degree; it is not a minimum limb count.
Power search, seed, and rounding decisions remain unchanged.
`pown` and `compoundn` retain their original storage limits.
Binary16 retains its original 32-limb multiplication path.
No dynamic allocation, runtime dispatch, or vector polynomial was added.

The final-v4 root cohort used 64 calls and nine pairs over 64 cases.
All 43 binary32 and binary64 cases met the rule, 89.84% to 96.57% lower measured time,
with nine faster pairs in every one of them.
The 21 binary16 cases in that cohort are unchanged controls, not additional retained optimizations.

| Final-v4 root case | Calls | Baseline median, ns | Candidate median, ns | Lower time | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Scalar binary32, normal | 64 | 4,162,924 | 216,394 | 94.80% | 9 |
| Scalar binary32, boundary | 64 | 2,260,546 | 126,145 | 94.42% | 9 |
| Scalar binary64, normal | 64 | 33,734,217 | 1,909,302 | 94.34% | 9 |
| Scalar binary64, boundary | 64 | 26,218,253 | 1,601,902 | 93.89% | 9 |
| Root umbrella dispatch | 64 | 17,040,572 | 977,662 | 94.26% | 9 |
| Binary32 lanes, width 4, boundary | 64 | 3,960,926 | 196,196 | 95.05% | 9 |
| Binary32 lanes, width 8, boundary | 64 | 12,610,134 | 431,978 | 96.57% | 9 |
| Binary32 lane-typed root, width 2, normal | 64 | 5,232,819 | 420,026 | 91.97% | 9 |
| Binary32 lane-typed root, width 8, normal | 64 | 23,703,601 | 1,582,914 | 93.32% | 9 |
| Binary64 lanes, width 4, normal | 64 | 97,602,936 | 6,772,375 | 93.06% | 9 |
| Binary64 lane-typed root, width 4, boundary | 64 | 53,894,469 | 2,293,792 | 95.74% | 9 |
| Binary64 lane-typed root, width 8, boundary | 64 | 110,005,516 | 4,468,609 | 95.94% | 9 |

The assembly explains the cost.
ReleaseSafe emits `0xaa` poison for undefined `Big` temporaries.
The old binary64 power path repeatedly clears 16,392 bytes; the narrowed path clears 896 bytes.
Safety checks remain enabled.
In the matched final-v4 root profiles, `compiler_rt.memset` self-time fell from 93.36% to 40.44% for leaf
and from 96.71% to 64.08% for lanes.
Those four profiles reported 474, 74, 8,000 and 602 samples respectively, with zero lost samples each.
The candidate profiles split the remaining time across the narrowed 53-limb and 111-limb multiply and
power specializations, which the frozen profiles could not name because they did not exist.
Shares with 74 samples are indicative, not a stable attribution.
Portable result-array wrappers gain through the scalar kernel; this is not new SIMD throughput.

**Retain exact-predicate output buffers and scratch reuse.**
Geometry keeps its fixed 132-limb integer bound.
Private arithmetic now writes into caller-owned outputs, clears active prefixes, and skips zero left limbs in multiplication.
Predicates reuse scratch buffers instead of copying complete limb arrays.

The final-v4 orientation cohort ran 24 cases at 4,096 calls and nine pairs:
20 faster, four undecided, no slower case.
The faster cases fall between 12.94% and 58.71% lower time.
The four undecided cases are Point2(f64) ordinary at +29.80% over seven faster pairs,
Point2(f64) exponent-extreme at +27.57% over seven, and the two Point2 near-degenerate cases at
+8.64% and +9.27% over six each. They did not reach the eight-of-nine quorum and are not retained as gains.

| Final-v4 orientation case | Calls | Baseline median, ns | Candidate median, ns | Lower time | Faster pairs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Point2(f32), ordinary | 4,096 | 22,511,323 | 13,020,925 | 42.16% | 9 |
| Point3(f32), ordinary | 4,096 | 55,349,434 | 32,602,013 | 41.10% | 9 |
| Point4(f32), ordinary | 4,096 | 127,061,396 | 52,461,113 | 58.71% | 9 |
| Point4(f32), perturbed ULP | 4,096 | 75,808,431 | 37,145,688 | 51.00% | 9 |
| Point3(f64), ordinary | 4,096 | 55,589,834 | 29,996,912 | 46.04% | 9 |
| Point3(f64), perturbed ULP | 4,096 | 33,242,075 | 28,942,062 | 12.94% | 9 |
| Point4(f64), ordinary | 4,096 | 119,521,869 | 74,305,163 | 37.83% | 9 |

The earlier 320-case `adaptive_exact` sweep and its longer 24-case orientation and 15-case binary64-line
repeats reached the same direction from shorter schedules, and the final-v4 cohort reproduces the
24-case orientation result on the final image.

The first output-buffer candidate left a float's low limb prefix uninitialized.
Existing tests and independent integer-reference tests failed.
Clearing that prefix restored the required mixed normal/subnormal collinearity.
The 24 sampled orientation checksums did not expose this defect before the repair.
They are not substitutes for numerical regression tests.
The new reference also needed alias, normal-power-of-two decoding, and mixed-precision scale repairs.
The first integration result, 936 passed / ten failed / one crashed, therefore includes both production and reference defects.
After repair and candidate rejection the earlier image passed all 947 native ReleaseSafe tests.
The final-v4 gate's native `zig build test` section reports ok, and the same suite in the cross-test
Debug build passes all 954 tests on native x86_64 Linux; the seven extra cases are the added
lane-order and mask-width regressions.

**Retain logical-lane vector publication and the scoped mask workaround.**
This is a correctness change on big-endian targets, not a speed result.
The `Vec` bridges previously used the language array-to-`@Vector` coercion, and indexed boolean result
stores lost earlier true lanes on LLVM AArch64 big-endian.
The bridges now assign and read named components by logical lane index.
`mapBinary` and the per-lane helpers publish boolean results through byte lanes on that one target and
mode, with a Debug-only lane reversal at power-of-two widths; every other target and result type keeps
direct vector storage.

The final-v4 bridge and Aabb cohort ran 24 cases at 4,096 calls and nine pairs:
one faster case, `values/Vec4f.fromVector/ordinary` at +6.10% over eight faster pairs, and 23 undecided
cases spanning -3.04% to +14.08%. No lane-order regression appeared in those 24 cases.
The evidence for this change is the correctness material below, not the timing row.

### Rejected candidates and timing controls

The 27-limb binary16 root candidate failed retention.
Its width-4 skewed per-lane-degree case was 14.96% slower in eight of nine pairs.
The final tree restores the original 32-limb path.
A final 21-case binary16 repeat on the earlier image used 4,096 calls and nine pairs, with no slower verdicts.

Destination-major algebra products also failed retention.
The 34-case dense/sparse/motor cohort used 1,024 calls and nine pairs.
It yielded zero faster, 14 slower, and 20 undecided cases.
Cl3f dense products took 3.78x baseline time; Cl3d took 2.54x.
Cga4f and Cga4d dense products were 5.91% and 9.97% slower.
The product implementation and its candidate-only tests were removed.
`src/algebra.zig` is restored byte-for-byte to the frozen source.

Restored algebra repeats each flagged one different row, despite the unchanged product source.
Identical-image controls demonstrate the limit of the practical rule:
the frozen-image control flagged one faster and one slower row;
the final-image control flagged two slower rows and no faster row.
Each control used the same executable SHA256 on both sides, 34 cases, 4,096 calls, and nine pairs.

The final-v4 lane control repeats the same test at lane scale.
The final-v4 identical-image control used the final-v4 executable on both sides, three cases,
1,024 calls and nine pairs, and produced no faster and no slower verdict at all
(-0.93%, +0.15% and +0.10%).

| Identical-image control | Cases | Calls | Pairs | Faster | Slower | Undecided |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Frozen image, both sides | 34 | 4,096 | 9 | 1 | 1 | 32 |
| Optimization image, both sides | 34 | 4,096 | 9 | 0 | 2 | 32 |
| Final-v4 lanes, both sides | 3 | 1,024 | 9 | 0 | 0 | 3 |

Thus small verdicts on this shared host are not a general performance guarantee.
No algebra gain or whole-surface no-regression claim is made.
No new value, complex, matrix, or factorization candidate was retained.

### Retained slower flags

Every row that met the slower criterion is listed here and kept in the focused CSV.
None was discarded, and none was resolved by rerunning until it disappeared.

| Cohort | Case | Calls | Baseline median, ns | Candidate median, ns | Slower by | Slower pairs |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 06 root retention | `lanes.rootnhvLanes.f16.w4.skewed` | 64 | 232,485 | 267,270 | 14.96% | 8 |
| 07 algebra retention | `algebra.Multivector(3,f32,.clifford,.{ 1, 1, 1 },3).geometricProduct` | 1,024 | 271,674 | 1,025,850 | 277.60% | 9 |
| 07 algebra retention | `algebra.Multivector(3,f32,.clifford,.{ 1, 1, 1 },3).geometricProduct.sparse` | 1,024 | 112,538 | 149,505 | 32.85% | 8 |
| 07 algebra retention | `algebra.Multivector(3,f64,.clifford,.{ 1, 1, 1 },3).geometricProduct` | 1,024 | 324,310 | 824,163 | 154.13% | 9 |
| 07 algebra retention | `algebra.Multivector(3,f64,.clifford,.{ 1, 1, 1 },3).geometricProduct.sparse` | 1,024 | 104,024 | 154,093 | 48.13% | 8 |
| 07 algebra retention | `algebra.Multivector(4,f64,.clifford,.{ 1, 1, 1, 1 },4).geometricProduct.sparse` | 1,024 | 230,416 | 293,277 | 27.28% | 8 |
| 07 algebra retention | `algebra.Multivector(4,f32,.projective,.{ 0, 1, 1, 1 },3).geometricProduct` | 1,024 | 2,032,773 | 2,506,704 | 23.31% | 8 |
| 07 algebra retention | `algebra.Multivector(4,f32,.projective,.{ 0, 1, 1, 1 },3).geometricProduct.motor` | 1,024 | 212,622 | 270,441 | 27.19% | 8 |
| 07 algebra retention | `algebra.Multivector(4,f64,.projective,.{ 0, 1, 1, 1 },3).geometricProduct` | 1,024 | 1,927,341 | 2,547,546 | 32.18% | 9 |
| 07 algebra retention | `algebra.Multivector(4,f64,.projective,.{ 0, 1, 1, 1 },3).geometricProduct.sparse` | 1,024 | 233,951 | 282,784 | 20.87% | 8 |
| 07 algebra retention | `algebra.Multivector(5,f32,.projective,.{ 0, 1, 1, 1, 1 },4).geometricProduct` | 1,024 | 7,729,712 | 9,114,537 | 17.92% | 8 |
| 07 algebra retention | `algebra.Multivector(5,f32,.conformal,.{ 1, 1, 1, 1, -1 },3).geometricProduct` | 1,024 | 10,020,290 | 11,510,004 | 14.87% | 8 |
| 07 algebra retention | `algebra.Multivector(6,f32,.conformal,.{ 1, 1, 1, 1, 1, -1 },4).geometricProduct` | 1,024 | 38,990,971 | 41,294,533 | 5.91% | 9 |
| 07 algebra retention | `algebra.Multivector(6,f32,.conformal,.{ 1, 1, 1, 1, 1, -1 },4).geometricProduct.motor` | 1,024 | 2,169,004 | 3,428,509 | 58.07% | 8 |
| 07 algebra retention | `algebra.Multivector(6,f64,.conformal,.{ 1, 1, 1, 1, 1, -1 },4).geometricProduct` | 1,024 | 38,733,377 | 42,596,453 | 9.97% | 8 |
| 10 algebra rollback | `algebra.Multivector(4,f32,.clifford,.{ 1, 1, 1, 1 },4).geometricProduct.motor` | 1,024 | 143,785 | 218,884 | 52.23% | 8 |
| 12 adaptive sweep | `geometry.Point2(f64).orientation.policy.adaptive_exact.ordinary` | 2 | 8,239 | 14,684 | 78.23% | 9 |
| 12 adaptive sweep | `geometry.LineOf(2,f64).intersect.policy.adaptive_exact.coincident.normalized_operands` | 2 | 14,838 | 25,897 | 74.53% | 8 |
| 16 algebra rollback repeat | `algebra.Multivector(5,f64,.conformal,.{ 1, 1, 1, 1, -1 },3).geometricProduct.motor` | 4,096 | 1,606,583 | 1,854,461 | 15.43% | 8 |
| 17 frozen identical-image control | `algebra.Multivector(6,f64,.conformal,.{ 1, 1, 1, 1, 1, -1 },4).geometricProduct.motor` | 4,096 | 8,097,641 | 10,236,807 | 26.42% | 8 |
| 18 optimization identical-image control | `algebra.Multivector(4,f32,.projective,.{ 0, 1, 1, 1 },3).geometricProduct.motor` | 4,096 | 693,910 | 873,465 | 25.88% | 8 |
| 18 optimization identical-image control | `algebra.Multivector(5,f64,.projective,.{ 0, 1, 1, 1, 1 },4).geometricProduct.motor` | 4,096 | 1,828,572 | 2,433,869 | 33.10% | 8 |
| 19 final-v4 roots | `lanes.rootnhvLanes.f16.w8.normal` | 64 | 294,488 | 347,911 | 18.14% | 8 |
| 20 final-v4 portable lanes | `lanes.totalOrderdv.f64.w4.skewed` | 1,024 | 132,613 | 138,321 | 4.30% | 8 |
| 20 final-v4 portable lanes | `lanes.totalOrderdv.f64.w4.boundary` | 1,024 | 149,815 | 156,058 | 4.17% | 8 |
| 20 final-v4 portable lanes | `lanes.totalOrderfv.f32.w4.boundary` | 1,024 | 150,265 | 156,252 | 3.98% | 9 |
| 23 final-v4 binary16 controls | `lanes.rootnhvLanes.f16.w4.boundary` | 4,096 | 3,501,633 | 4,079,301 | 16.50% | 8 |
| 24 final-v4 lane flags, longer schedule | `lanes.totalOrderfv.f32.w4.boundary` | 2,048 | 376,530 | 440,225 | 16.92% | 8 |

The final-v4 lane flags were re-measured on a longer 2,048-call schedule.
Two of the three did not meet the criterion there either (-22.43% over three faster pairs and -18.29% over three),
and `lanes.totalOrderfv.f32.w4.boundary` stayed slower at 16.92% with eight of nine pairs slower.
Its binary32 charge is the `totalOrderf` canonical key and is recorded below.

The 21 binary16 control cases in the final-v4 binary16 cohort are unchanged code on both sides.
Their verdicts are 0 faster, 1 slower and 20 undecided over -16.50% to +37.07%.
That spread on unchanged code is the size of the host's practical noise floor for these cohorts,
and it bounds how much any single small row above can be believed.

All 28 rows above remain unresolved measured observations.
No later repeat, control or rerun dismisses a real-image flag, and none of them is treated as a pass.
The identical-image controls show only that the practical rule also fires on unchanged code;
they neither explain nor cancel the real-image rows, which still stand as measured regressions
against the frozen image on this host.

### Global binary32 measurement ledger

The shared cap is 1,048,576 reserved evaluations per canonical binary32 kernel.
Aliases, lanes, transitive half wrappers, profiles, both versions, diagnostics, and failed measurements share the ledger.
Correctness suites and untimed consumer smoke checks are separate.
The ledger has 109 canonical keys and 5,747,842 total reservations across those keys.
Every key remains below its cap.

| Canonical key | Reserved evaluations | Remaining |
| --- | ---: | ---: |
| `hypotf` | 1,044,802 | 3,774 |
| `totalOrderf` | 1,009,304 | 39,272 |
| `totalOrderMagf` | 781,694 | 266,882 |
| `fmaf` | 580,825 | 467,751 |
| `absf` | 477,034 | 571,542 |
| `fmaxf` | 423,638 | 624,938 |
| `rootnf` | 351,896 | 696,680 |
| `fminf` | 100,992 | 947,584 |
| `sqrtf` | 88,561 | 960,015 |
| `scalbnf` | 44,324 | 1,004,252 |

Two whole-surface coverage-shaped reservation windows, at 19:56Z and 20:13Z, retained 189,616 evaluations each.
The first of them is the failed initial fixture campaign; the second is the retried coverage run.
The one-call whole-surface failure scan retained another 23,702.
The final-v4 cohorts retained 1,882,112 more, attributed per round by the runner's own receipts:
cohort 19 took 112,640 on `rootnf`, cohort 20 took 774,144 each on `totalOrderf` and `totalOrderMagf`,
cohort 24 took 147,456 on `totalOrderf`, and the identical-image control in cohort 25 took 73,728 on
`totalOrderf`. Cohorts 21, 22 and 23 reserved nothing, because geometry and value cases reach no binary32 kernel.
The remaining 3,865,730 predates the final-v4 cohorts.
The longer orientation, line and algebra cohorts reach no accepted binary32 kernel.
Do not reset this ledger to extend the same campaign.

### Runtime verification status

Two different source states are described here and they must not be merged. The receipts in the first half
below belong to the measured final-v4 image. The current source tree carries its own whole-tree
correctness receipts, recorded in the second half of this section; they postdate the final-v4 measurement
and are not bound to its digests.

| Gate section | Final-v4 outcome |
| --- | --- |
| `zig fmt --check` | ok |
| `zig build` | ok |
| `zig build test` | ok |
| `zig ast-check` | ok |
| `ziglint` | 263 findings, exit 1 |
| `zlint` | 263 findings, exit 0 |
| `zbc` | 144 errors, exit 1 |
| `zwanzig` | 351 findings, exit 1 |
| `cross-test` | fail: 19 pass, 1 fail, 33 build-only over 53 targets |

Recorded tool output on the frozen tree shows 265 `ziglint` findings, 269 `zlint` findings,
145 `zbc` findings and 375 `zwanzig` findings.
The final-v4 counts are lower by 2, 6, 1 and 24 findings respectively.
That is one total per tool, not a per-rule comparison, and it does not settle whether this campaign
introduced findings. Comparing the frozen and final-v4 analyzer runs rule by rule names two rule families
that rose while their tools' totals fell: `ziglint` rule Z006 went from 32 to 34, and `zwanzig`
`identifier-style` went from 190 to 205. Both tools' totals still fell, so a falling total does not imply a
finding-free campaign. Whether those findings come from the files this campaign touched is resolved by
`campaign-provenance/linter-baseline.tar.gz` and the final-v4 analyzer output, and is not asserted here
without that comparison being run and recorded.
The three tools that exited non-zero stay on record as failing. The count decline does not clear them,
and the rule-level rises are not dismissed as inherited.

The final-v4 cross-test failure is `armeb-linux`: 948 of 954 tests passed and six failed.
All six are `vector_value_test` cases that check `toVector` and `fromVector` lane order, and each
reverses the two lanes it compares.
Every other one of the 20 targets that had a local runner passed, including `aarch64_be-linux`,
`s390x-linux`, `powerpc64-linux`, `powerpc-linux`, `mips-linux` and `mipsel-linux`.
The remaining 33 targets built only, with no local runner.
Earlier gates in the same campaign failed on more targets, and `armeb-linux` failed in all of them.

The strict one-hot consumer that drives the real public API over 35 mask widths reports nine of ten
target and mode combinations passing on the final-v4 image.
It is a correctness driver, not a timing run.
`aarch64_be-linux` in `ReleaseSafe` fails at width 64 with a logical-lane mismatch, while its `Debug`
build passes.
The separate 35-width array publication probe on `aarch64_be-linux` `ReleaseSafe` passes all 753
one-hot positions.
The bridge consumer matrix passes in all ten target and mode combinations, and the default-backend
native consumer passes.

#### Verification of the current source tree

The current tree is the runtime source after the big-endian lane-publication work. These are whole-tree
receipts, not focused probes. None of them is a measurement: this run reserved nothing and left the shared
ledger at `8d1b385ec50acb23da73533f9cd50a9ea01142e30d5ebb5526f93e71dd401c1b`, 678 records.

| Check | Extent | Result |
| --- | --- | --- |
| native `zig build test`, `x86_64-linux-gnu.2.38`, `Debug` | 956 tests | 956 pass |
| native `zig build test`, `x86_64-linux-gnu.2.38`, `ReleaseSafe` | 956 tests | 956 pass |
| `cross-test` `Debug`, all 53 Zig 0.16.0 Tier 1/2 targets | 53 targets | 19 pass, 1 fail, 33 build-only, 0 partial, 489.79 s |
| `cross-test` `ReleaseSafe`, `armeb-linux` and `aarch64_be-linux` | 2 targets | 2 pass, 0 fail, 0 build-only |
| `zig fmt --check` | both repositories | clean |
| full `gate`, `direnv exec . gate` | whole tree, 568.38 s | exit 1, not green; sections below |

The native run used `--cache-dir` under the campaign scratch, `--global-cache-dir
/tmp/cache/zig` and `--summary all`. The `Debug` cross-test ran under the project profile
with `--jobs 16 --build-jobs 3` in run `20261004-153923-46001-17397`. The `ReleaseSafe` cross-test ran
`--targets armeb-linux,aarch64_be-linux --jobs 2 --build-jobs 28 -- -Doptimize=ReleaseSafe`.

`loongarch64-linux`, `aarch64_be-linux`, `thumbeb-linux`, `x86_64-linux`, `mips-linux`, `s390x-linux` and
`riscv64-linux` each report `All 956 tests passed.` The `ReleaseSafe` run matters twice: it is the first
receipt for the integer boolean-publication route in `src/vector_core.zig`, which needs an `aarch64_be`
target and a non-`Debug` mode at the same time, and it establishes that the `armeb-linux` register defect
below is `Debug`-only. Missing OS runtimes stay build-only and are never counted as passes; no success is
claimed for any of the 33 targets that only built, and none of this is corpus acceptance evidence.

##### The six `armeb-linux` `Debug` failures

`armeb-linux` in `Debug` reports `950 passed; 0 skipped; 6 failed`. The six are the pre-existing
`toVector` and `fromVector` lane-order cases in `src/vector_value_test.zig`, and they fail identically at
the parent commit, so they are not a regression from this work. They read the returned `@Vector` register:
LLVM's ARM big-endian backend computes the returned vector's big-endian reversal into a scratch register it
never reads, returns the unreversed register, and the caller then applies one extra reversal, so every
forwarded result arrives with one lane swapped. Reading the published bytes instead of the returned
register is correct, which is why the new `toVector publishes lane zero at the lowest address, on every
target` test passes on that target while the register-read tests fail.

Three source forms of `toVectorOf` were tried and all three leave those six failing: the original per-lane
`@Vector` assignment, a private `inline` variant, and an array-plus-`@bitCast` variant. The array variant
was reverted, so `src/vector_value.zig` carries no change and no `Vec`-bridge repair is claimed. The six
tests stay in the suite; drop neither the failing cases nor the target to make a run green, and record the
count instead.

##### Boolean-mask widths excluded from the one-hot sweep

Four widths are excluded, on two measured grounds.

| Excluded width | Target and mode | Evidence |
| --- | --- | --- |
| 32, 64, 128 | `loongarch64-linux` `Debug` | publishes a spurious true lane 0, and reproduces identically against a `git archive HEAD src` export |
| 14 | `aarch64_be-linux` `ReleaseSafe` | `cross-test --targets aarch64_be-linux -- -Doptimize=ReleaseSafe` reported 955 of 956 before the exclusion and 956 of 956 after it |

Width 14 is clean in `Debug` and in isolated single-width programs, so it is program-shape sensitive rather
than a stable width-specific defect. The excluded set is therefore not a stable boundary.

Two standalone-probe results disagree with the repository test binary and stay open: width 16 on
`loongarch64-linux` in `Debug`, and every power-of-two width on `aarch64_be-linux` in `Debug`. The first was
re-run with operands built from a runtime loop index and still reproduced, so constant folding does not
explain it. Both are recorded as unresolved reports about program-shape sensitivity, not as widths to
exclude.

##### The gate is not green

`direnv exec . gate` ran the full gate on this tree with its internal cross-test parallelised through
`CROSS_TEST_ARGS="--jobs 16 --build-jobs 3"`, run `20261004-155201-25886-32090`, in 568.38 s, exit 1.
The gate is not green and is not reported as green.

| Gate section | Current-tree outcome |
| --- | --- |
| `zig fmt --check` | ok |
| `zig build` | ok |
| `zig build test` | ok |
| `zig ast-check` | ok |
| `ziglint` | 263 issues, exit 1 |
| `zlint` | 263 issues, exit 0 |
| `zbc` | 146 `use-undefined` errors, exit 1 |
| `zwanzig` | 353 findings across 8 rule classes, exit 1 |
| `cross-test` | fail: 19 pass, 1 fail, 33 build-only, 0 partial, the one failure `armeb-linux` at 950 of 956 |

The gate log truncates each analyzer section to its first lines, so these totals and exit codes are the only
durable analyzer results in it, and no finding list is claimed from it.

The baseline these four analyzer counts compare against is the campaign's frozen measured source snapshot,
not the parent commit: 213 files with `ziglint` 265, `zlint` 269, `zbc` 145 and `zwanzig` 375. That is the
same baseline tabulated for the final-v4 image earlier in this section, and these two sets of counts are
not a comparison against the parent commit.

`zbc` is the one count that rose, from 145 to 146. Comparing per file rather than by line number, because the
whole change set shifted line numbers: `src/vector_core.zig` 13 to 6, `src/geometry.zig` 28 to 22 and
`src/vector_test.zig` 2 to 0, against `src/vector_value_test.zig` 2 to 8, `src/linalg.zig` 19 to 23,
`src/vector_value.zig` 24 to 28 and `src/geometry_test.zig` 0 to 2. The byte-staging change in
`src/vector_core.zig` removed seven findings, and the net rise of one is spread across the wider uncommitted
change set rather than concentrated in the four files of the lane-publication work. `src/vector_value.zig`
carries no change from that work at all, because the experimental array variant was reverted.

### Reproduction and evidence

Run from `zmath-testing`, with both source versions built against the same harness:

```sh
source "$HOME/.local/lib/host-scratch.sh"
export PERF_BUILDID_DIR="$XDG_CACHE_HOME/perf"
zig build bench-api-round -Dtarget=x86_64-linux-gnu.2.38 -Dcpu=haswell -Doptimize=ReleaseSafe \
  --cache-dir "$ZIG_LOCAL_CACHE_DIR" --prefix "$TMPDIR/zmath-api"
python3 bench/run_api_round.py \
  --baseline-exe "$BASELINE_EXE" --candidate-exe "$CANDIDATE_EXE" \
  --out-dir "$TMPDIR/api-round-new" --ledger "$GLOBAL_LEDGER" \
  --calls 4 --pairs 1 --cpu 0 --plan-only
```

Select an allowed CPU and use a new output directory.
Remove `--plan-only` only when the selection fits the existing shared ledger.
Use repeatable `--case` filters, at most 64 names, for focused cohorts.
The receipts preserve the actual commands, source hashes, executable identities, inputs, checksums, and reservations.

- [Complete selected coverage CSV](../bench/results/api-surface-20261003-coverage.csv): 7,428 rows, explicitly `coverage_only`, measured on the optimization image.
- [Focused paired CSV](../bench/results/api-surface-20261003-focused.csv): 895 rows over 23 cohorts, including rejected candidates, unchanged binary16 controls, longer repeats and identical-image controls. It retains 291 faster, 28 slower and 576 undecided rows.
- [Retained final-v4 evidence package](../bench/results/api-surface-20261003-final-v4/): 116 members, 10,614,487 bytes, no executables, caches or perf sample data. The 116 members are the ones `package-manifest.json` hashes; it does not hash itself, so the directory holds 117 files and 10,640,697 bytes.

The evidence package holds both source snapshots, the per-round manifests, reports and results, the
four profile reports, the shared ledger and its summary, the measurement input scripts, the
verification receipts quoted above, and a `campaign-provenance/` subtree that archives the earlier
cohorts behind the two committed CSVs.
Its `archive-verification.json` recomputes both source tree digests from the packaged archives and
reproduces the recorded values exactly, and its `package-manifest.json` re-checks all 193 final-v4
report rows against the committed CSV with zero mismatches.

The `campaign-provenance/` subtree exists because the 895-row focused CSV and the 7,428-row coverage CSV
were published without the per-cohort receipts that back their rows. It holds loose `manifest.json`,
`report.txt` and `results.json` for the sixteen pre-final-v4 focused cohorts, including both
identical-image controls and every rejected candidate, plus nine archives covering the coverage rounds
and their plan-only case listing, the five early profiling and first-integration cohorts behind the
schedule and defect paragraphs, the raw per-pair streams of cohorts 06-18, the 107 per-target logs
behind the cross-test summary, the four frozen-tree analyzer logs behind the linter counts, the
untimed replay checksum stream, and the current-tree cross-test runs. Beside them it holds the six
current-tree verification receipts themselves: the `gate` log of this tree, the `Debug` and
`ReleaseSafe` cross-test summaries with the per-target logs of their runs, and the full 146-line `zbc`
listing that the truncated gate log cannot supply, so the per-file `zbc` disposition above is
recomputable from the package alone. Its `provenance-index.json` states which published artifact each
member backs and transcribes the command behind each current-tree receipt with its `run_id`. All 1,008
files were compared against the campaign working copies with zero size or SHA256 mismatch, and the
archives are reproducible because member order, ownership and mtime are pinned.
`perf .perf.data` streams are excluded here as they are elsewhere; they are regenerable from
`profiles/perf-report-commands.json`.

All three paths are the only entries under `bench/results/` that are tracked in this repository. The
`package-manifest.json` totals are the manifest's own exclusion of itself, and every one of the 116
listed members' recorded size and SHA256 was re-checked against the file on disk with no mismatch, no
listed member missing and no unlisted file present. The packaged copies of both source snapshot
archives, the shared ledger, all seven measurement input scripts and five of the seven `verification/`
receipts are byte-identical to the campaign working files they were taken from. The two without a
byte-identical working counterpart are the gate and cross-test summaries, which were reduced from
`gate-final-v4.log` and from the per-target `runs/` logs of `gate-cross-final-v4`; both inputs are now
archived in `campaign-provenance/`, so those two summaries are the only derived files in the package.

Every round receipt in this campaign reports protocol 1 and harness digest `f3492d07de0e3b95`.

Native checks exercised the real consumer module, not just test imports:
binary16/32/64 roots, reciprocal and portable-lane roots, exact versus rounded orientation,
mixed-scale collinearity, and the restored Cl3d basis product.
Observed root bits were `4000/40000000/4010000000000000`, reciprocal `3fd0000000000000`;
lanes returned 2/3/4/5, mixed-scale orientation was zero, and `e1*e2` had coefficient 1 at mask 3.
The harness suite passed 65/65 tests and the Python runner suite passed 95/95 on the optimization image,
before the final-v4 lane-order changes.

A separate protocol check on the current tree, after the big-endian repairs and before any whole-tree
gate, ran only the runner's own unit tests. It invoked no benchmark, no profiler and no corpus:

```sh
source "$HOME/.local/lib/host-scratch.sh"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s bench -p test_api_round_runner.py
```

It exited 0 after `Ran 95 tests in 9.720s` and `OK`, spawning only test fixture subprocesses. The run
fixes the current tree's `bench/run_api_round.py` at
`16d95359ab487c89bfa410504acca938ce3cdeb760bcbf5f91989772a6bdc750` and its
`bench/test_api_round_runner.py` at
`11016080c077f6e396b0e9a71395bd6fbd735de908e3674d4c70911d78b3eacf`. The shared ledger file was
unchanged by it: `8d1b385ec50acb23da73533f9cd50a9ea01142e30d5ebb5526f93e71dd401c1b`, 678 records, and
no reservation was made.
This is runner-harness protocol evidence for the current tree and nothing else. It exercises no zmath
symbol, so it is not a gate, a correctness result or a measurement, and it is not one of the
whole-tree receipts under [Runtime verification status](#runtime-verification-status). The 65/65 and
95/95 figures above remain attributed to the optimization image.

No oracle generation or corpus replay was run in this round.
Checksums can collide and cover only their fixtures.
Lane widths outside 2/4/8, other generic matrix shapes, and other hardware throughput remain unmeasured.
The schema-5 corpus manifest remains the numerical acceptance authority.
This section publishes bounded coverage and named measured cases.
It is not a correctness acceptance result and it is not a whole-domain performance claim.
