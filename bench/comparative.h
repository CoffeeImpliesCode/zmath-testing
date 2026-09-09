#ifndef ZMATH_TESTING_BENCH_COMPARATIVE_H
#define ZMATH_TESTING_BENCH_COMPARATIVE_H

// Shared fair-comparison contract for the C++ Google Benchmark comparison.
// Owner: WorkloadAudit. Bridge implements the getters; Runner consumes them.
// Framework measures every provider through the returned opaque function
// pointer with equal C ABI. Input generation, auditing, and serialization
// stay outside timing.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Operation order is fixed: EXP, LOG, SIN, COS, TAN, SQRT, HYPOT, ATAN2, POW.
// Values 0..8; COMPARE_OPERATION_COUNT is 9. Do not reorder.
enum compare_operation {
  COMPARE_EXP = 0,
  COMPARE_LOG = 1,
  COMPARE_SIN = 2,
  COMPARE_COS = 3,
  COMPARE_TAN = 4,
  COMPARE_SQRT = 5,
  COMPARE_HYPOT = 6,
  COMPARE_ATAN2 = 7,
  COMPARE_POW = 8,
  COMPARE_OPERATION_COUNT = 9
};

// Binary C ABI for every provider. Unary operations (EXP, LOG, SIN, COS,
// TAN, SQRT) ignore the second argument; the caller still passes both so
// all providers share one call shape and no per-call operation switch runs
// inside timing.
typedef float (*CompareF32)(float, float);
typedef double (*CompareF64)(double, double);

// Each getter resolves one (provider, format, operation) triple to an
// opaque function pointer. Call once per benchmark setup, then invoke the
// pointer in the timed loop. Returns NULL only for unsupported CORE-MATH
// entries; zmath, zig, and glibc entries cover all 9 operations.
CompareF32 compare_zmath_f32(uint32_t op);
CompareF64 compare_zmath_f64(uint32_t op);
CompareF32 compare_zig_f32(uint32_t op);
CompareF64 compare_zig_f64(uint32_t op);
CompareF32 compare_glibc_f32(uint32_t op);
CompareF64 compare_glibc_f64(uint32_t op);
// Resolve the actual libm provider for one operation and format. `single`
// must be 0 for f64 or 1 for f32. Returns NULL on invalid input or failure.
const char *compare_glibc_origin(uint32_t op, uint32_t single);
const char *compare_glibc_version(void);
// Vendored CORE-MATH: resolves only already-vendored symbols that match the
// pinned revision. It is labeled "vendored CORE-MATH", not an independent
// algorithm, wherever zmath shares the same code. Returns NULL explicitly
// for operations with no matching vendored symbol.
CompareF32 compare_coremath_f32(uint32_t op);
CompareF64 compare_coremath_f64(uint32_t op);

#ifdef __cplusplus
}
#endif

#endif
