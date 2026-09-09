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

// Operation order is fixed. Values 0..40 are part of the serialized workload
// contract; append new operations only.
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
  COMPARE_ACOS = 9,
  COMPARE_ACOSH = 10,
  COMPARE_ACOSPI = 11,
  COMPARE_ASIN = 12,
  COMPARE_ASINH = 13,
  COMPARE_ASINPI = 14,
  COMPARE_ATAN = 15,
  COMPARE_ATAN2PI = 16,
  COMPARE_ATANH = 17,
  COMPARE_ATANPI = 18,
  COMPARE_CBRT = 19,
  COMPARE_COSH = 20,
  COMPARE_COSPI = 21,
  COMPARE_ERF = 22,
  COMPARE_ERFC = 23,
  COMPARE_EXP10 = 24,
  COMPARE_EXP10M1 = 25,
  COMPARE_EXP2 = 26,
  COMPARE_EXP2M1 = 27,
  COMPARE_EXPM1 = 28,
  COMPARE_LGAMMA = 29,
  COMPARE_LOG10 = 30,
  COMPARE_LOG10P1 = 31,
  COMPARE_LOG1P = 32,
  COMPARE_LOG2 = 33,
  COMPARE_LOG2P1 = 34,
  COMPARE_RSQRT = 35,
  COMPARE_SINH = 36,
  COMPARE_SINPI = 37,
  COMPARE_TANH = 38,
  COMPARE_TANPI = 39,
  COMPARE_TGAMMA = 40,
  COMPARE_OPERATION_COUNT = 41
};
// Binary C ABI for every provider. Unary operations ignore the second
// argument; the caller still passes both so all providers share one call
// shape and no per-call operation switch runs inside timing.
typedef _Float16 (*CompareF16)(_Float16, _Float16);
typedef float (*CompareF32)(float, float);
typedef double (*CompareF64)(double, double);

// Format values are serialized and therefore deliberately keep f64=0 and
// f32=1 from the original two-format matrix.
typedef enum compare_format {
  COMPARE_F64 = 0,
  COMPARE_F32 = 1,
  COMPARE_F16 = 2,
} CompareFormat;
// Each getter resolves one (provider, format, operation) triple to an opaque
// function pointer. Call once per benchmark setup, then invoke the pointer in
// the timed loop. CORE-MATH returns NULL only for format-specific unsupported
// entries or invalid selectors; binary16 supports SQRT.
CompareF32 compare_zmath_f32(uint32_t op);
CompareF64 compare_zmath_f64(uint32_t op);
CompareF16 compare_zmath_f16(uint32_t op);
CompareF32 compare_zig_f32(uint32_t op);
CompareF64 compare_zig_f64(uint32_t op);
CompareF16 compare_zig_f16(uint32_t op);
CompareF32 compare_glibc_f32(uint32_t op);
CompareF64 compare_glibc_f64(uint32_t op);
CompareF16 compare_glibc_f16(uint32_t op);
const char *compare_glibc_origin(uint32_t op, CompareFormat format);
const char *compare_glibc_version(void);
CompareF32 compare_coremath_f32(uint32_t op);
CompareF64 compare_coremath_f64(uint32_t op);
CompareF16 compare_coremath_f16(uint32_t op);
const char *compare_coremath_revision(void);
const char *compare_coremath_compiler(void);
const char *compare_coremath_flags(void);
const char *compare_coremath_source(void);
const char *compare_coremath_origin(uint32_t op, CompareFormat format);

#ifdef __cplusplus
}
#endif

#endif
