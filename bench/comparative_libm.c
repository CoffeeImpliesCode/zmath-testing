#define _GNU_SOURCE

#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "comparative.h"

#if defined(__clang__)
#define COMPARE_NOINLINE __attribute__((noinline))
#elif defined(__GNUC__)
#define COMPARE_NOINLINE __attribute__((noinline, noclone))
#else
#define COMPARE_NOINLINE
#endif

#ifndef COMPARATIVE_LIBM_PATH
#error "COMPARATIVE_LIBM_PATH must be defined"
#endif
#ifndef COMPARATIVE_COREMATH_PATH
#error "COMPARATIVE_COREMATH_PATH must be defined"
#endif

typedef _Float16 (*CompareUnaryF16)(_Float16);
typedef float (*CompareUnaryF32)(float);
typedef double (*CompareUnaryF64)(double);
typedef _Float16 (*CompareBinaryF16)(_Float16, _Float16);
typedef float (*CompareBinaryF32)(float, float);
typedef double (*CompareBinaryF64)(double, double);
typedef const char *(*CompareMetadata)(void);

typedef struct {
  CompareUnaryF16 unary_f16[COMPARE_OPERATION_COUNT];
  CompareUnaryF32 unary_f32[COMPARE_OPERATION_COUNT];
  CompareUnaryF64 unary_f64[COMPARE_OPERATION_COUNT];
  CompareBinaryF16 binary_f16[COMPARE_OPERATION_COUNT];
  CompareBinaryF32 binary_f32[COMPARE_OPERATION_COUNT];
  CompareBinaryF64 binary_f64[COMPARE_OPERATION_COUNT];
} CompareSymbols;

typedef struct {
  void *handle;
  CompareSymbols symbols;
  const char *revision;
  const char *compiler;
  const char *flags;
  const char *source;
} CompareCoreMathState;

#define COMPARE_GLIBC_UNARY_OPS(X)                                             \
  X(EXP, exp)                                                                  \
  X(LOG, log)                                                                  \
  X(SIN, sin)                                                                  \
  X(COS, cos)                                                                  \
  X(TAN, tan)                                                                  \
  X(SQRT, sqrt)                                                                \
  X(ACOS, acos)                                                                \
  X(ACOSH, acosh)                                                              \
  X(ACOSPI, acospi)                                                            \
  X(ASIN, asin)                                                                \
  X(ASINH, asinh)                                                              \
  X(ASINPI, asinpi)                                                            \
  X(ATAN, atan)                                                                \
  X(ATANH, atanh)                                                              \
  X(ATANPI, atanpi)                                                            \
  X(CBRT, cbrt)                                                                \
  X(COSH, cosh)                                                                \
  X(COSPI, cospi)                                                              \
  X(ERF, erf)                                                                  \
  X(ERFC, erfc)                                                                \
  X(EXP10, exp10)                                                              \
  X(EXP10M1, exp10m1)                                                          \
  X(EXP2, exp2)                                                                \
  X(EXP2M1, exp2m1)                                                            \
  X(EXPM1, expm1)                                                              \
  X(LGAMMA, lgamma)                                                            \
  X(LOG10, log10)                                                              \
  X(LOG10P1, log10p1)                                                          \
  X(LOG1P, log1p)                                                              \
  X(LOG2, log2)                                                                \
  X(LOG2P1, log2p1)                                                            \
  X(RSQRT, rsqrt)                                                              \
  X(SINH, sinh)                                                                \
  X(SINPI, sinpi)                                                              \
  X(TANH, tanh)                                                                \
  X(TANPI, tanpi)                                                              \
  X(TGAMMA, tgamma)

#define COMPARE_CORE_UNARY_OPS(X)                                              \
  X(EXP, exp)                                                                  \
  X(LOG, log)                                                                  \
  X(SIN, sin)                                                                  \
  X(COS, cos)                                                                  \
  X(TAN, tan)                                                                  \
  X(ACOS, acos)                                                                \
  X(ACOSH, acosh)                                                              \
  X(ACOSPI, acospi)                                                            \
  X(ASIN, asin)                                                                \
  X(ASINH, asinh)                                                              \
  X(ASINPI, asinpi)                                                            \
  X(ATAN, atan)                                                                \
  X(ATANH, atanh)                                                              \
  X(ATANPI, atanpi)                                                            \
  X(CBRT, cbrt)                                                                \
  X(COSH, cosh)                                                                \
  X(COSPI, cospi)                                                              \
  X(ERF, erf)                                                                  \
  X(ERFC, erfc)                                                                \
  X(EXP10, exp10)                                                              \
  X(EXP10M1, exp10m1)                                                          \
  X(EXP2, exp2)                                                                \
  X(EXP2M1, exp2m1)                                                            \
  X(EXPM1, expm1)                                                              \
  X(LGAMMA, lgamma)                                                            \
  X(LOG10, log10)                                                              \
  X(LOG10P1, log10p1)                                                          \
  X(LOG1P, log1p)                                                              \
  X(LOG2, log2)                                                                \
  X(LOG2P1, log2p1)                                                            \
  X(RSQRT, rsqrt)                                                              \
  X(SINH, sinh)                                                                \
  X(SINPI, sinpi)                                                              \
  X(TANH, tanh)                                                                \
  X(TANPI, tanpi)                                                              \
  X(TGAMMA, tgamma)

#define COMPARE_CORE_HALF_UNARY_OPS(X)                                         \
  X(SQRT, sqrt)                                                                \
  COMPARE_CORE_UNARY_OPS(X)

#define COMPARE_BINARY_OPS(X)                                                  \
  X(HYPOT, hypot)                                                              \
  X(ATAN2, atan2)                                                              \
  X(ATAN2PI, atan2pi)                                                          \
  X(POW, pow)

#define GLIBC_UNARY_NAME(op, name) [COMPARE_##op] = #name "f",
#define GLIBC_BINARY_NAME(op, name) [COMPARE_##op] = #name "f",
#define CORE_UNARY_NAME(op, name) [COMPARE_##op] = "cr_" #name "f",
#define CORE_BINARY_NAME(op, name) [COMPARE_##op] = "cr_" #name "f",

static const char *const
    compare_glibc_unary_names_f32[COMPARE_OPERATION_COUNT] = {
        COMPARE_GLIBC_UNARY_OPS(GLIBC_UNARY_NAME)};
static const char *const
    compare_glibc_unary_names_f64[COMPARE_OPERATION_COUNT] = {
#define GLIBC_UNARY_NAME_F64(op, name) [COMPARE_##op] = #name,
        COMPARE_GLIBC_UNARY_OPS(GLIBC_UNARY_NAME_F64)
#undef GLIBC_UNARY_NAME_F64
};
static const char *const
    compare_glibc_binary_names_f32[COMPARE_OPERATION_COUNT] = {
        COMPARE_BINARY_OPS(GLIBC_BINARY_NAME)};
static const char *const
    compare_glibc_binary_names_f64[COMPARE_OPERATION_COUNT] = {
#define GLIBC_BINARY_NAME_F64(op, name) [COMPARE_##op] = #name,
        COMPARE_BINARY_OPS(GLIBC_BINARY_NAME_F64)
#undef GLIBC_BINARY_NAME_F64
};

static const char *const compare_core_unary_names_f32[COMPARE_OPERATION_COUNT] =
    {COMPARE_CORE_UNARY_OPS(CORE_UNARY_NAME)};
static const char *const compare_core_unary_names_f64[COMPARE_OPERATION_COUNT] =
    {
#define CORE_UNARY_NAME_F64(op, name) [COMPARE_##op] = "cr_" #name,
        COMPARE_CORE_UNARY_OPS(CORE_UNARY_NAME_F64)
#undef CORE_UNARY_NAME_F64
};
static const char *const
    compare_core_binary_names_f32[COMPARE_OPERATION_COUNT] = {
        COMPARE_BINARY_OPS(CORE_BINARY_NAME)};
static const char *const
    compare_core_binary_names_f64[COMPARE_OPERATION_COUNT] = {
#define CORE_BINARY_NAME_F64(op, name) [COMPARE_##op] = "cr_" #name,
        COMPARE_BINARY_OPS(CORE_BINARY_NAME_F64)
#undef CORE_BINARY_NAME_F64
};
static const char *const compare_core_unary_names_f16[COMPARE_OPERATION_COUNT] =
    {
#define CORE_UNARY_NAME_F16(op, name) [COMPARE_##op] = "cr_" #name "f16",
        COMPARE_CORE_HALF_UNARY_OPS(CORE_UNARY_NAME_F16)
#undef CORE_UNARY_NAME_F16
};
static const char *const
    compare_core_binary_names_f16[COMPARE_OPERATION_COUNT] = {
#define CORE_BINARY_NAME_F16(op, name) [COMPARE_##op] = "cr_" #name "f16",
        COMPARE_BINARY_OPS(CORE_BINARY_NAME_F16)
#undef CORE_BINARY_NAME_F16
};

static CompareSymbols compare_libm_symbols;
static void *compare_libm_handle;
static pthread_once_t compare_libm_once = PTHREAD_ONCE_INIT;
static CompareCoreMathState compare_coremath_state;
static pthread_once_t compare_coremath_once = PTHREAD_ONCE_INIT;

static void compare_fatal(const char *provider, const char *detail) {
  const char *loader_error = dlerror();
  if (loader_error != NULL) {
    fprintf(stderr, "comparative: %s setup failed for %s: %s\n", provider,
            detail, loader_error);
  } else {
    fprintf(stderr, "comparative: %s setup failed for %s\n", provider, detail);
  }
  abort();
}

static CompareUnaryF16 compare_lookup_unary_f16(void *handle,
                                                const char *name) {
  return (CompareUnaryF16)dlsym(handle, name);
}

static CompareUnaryF32 compare_lookup_unary_f32(void *handle,
                                                const char *name) {
  return (CompareUnaryF32)dlsym(handle, name);
}

static CompareUnaryF64 compare_lookup_unary_f64(void *handle,
                                                const char *name) {
  return (CompareUnaryF64)dlsym(handle, name);
}

static CompareBinaryF32 compare_lookup_binary_f32(void *handle,
                                                  const char *name) {
  return (CompareBinaryF32)dlsym(handle, name);
}

static CompareBinaryF64 compare_lookup_binary_f64(void *handle,
                                                  const char *name) {
  return (CompareBinaryF64)dlsym(handle, name);
}
static CompareBinaryF16 compare_lookup_binary_f16(void *handle,
                                                  const char *name) {
  return (CompareBinaryF16)dlsym(handle, name);
}

static void compare_libm_init(void) {
  compare_libm_handle = dlopen(COMPARATIVE_LIBM_PATH, RTLD_NOW | RTLD_LOCAL);
  if (compare_libm_handle == NULL) {
    compare_fatal("glibc", COMPARATIVE_LIBM_PATH);
  }
  for (uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
       ++operation) {
    const char *unary_f32 = compare_glibc_unary_names_f32[operation];
    const char *unary_f64 = compare_glibc_unary_names_f64[operation];
    const char *binary_f32 = compare_glibc_binary_names_f32[operation];
    const char *binary_f64 = compare_glibc_binary_names_f64[operation];
    if (unary_f32 != NULL) {
      compare_libm_symbols.unary_f32[operation] =
          compare_lookup_unary_f32(compare_libm_handle, unary_f32);
      compare_libm_symbols.unary_f64[operation] =
          compare_lookup_unary_f64(compare_libm_handle, unary_f64);
      if (compare_libm_symbols.unary_f32[operation] == NULL ||
          compare_libm_symbols.unary_f64[operation] == NULL) {
        compare_fatal("glibc", unary_f32);
      }
    } else if (binary_f32 != NULL) {
      compare_libm_symbols.binary_f32[operation] =
          compare_lookup_binary_f32(compare_libm_handle, binary_f32);
      compare_libm_symbols.binary_f64[operation] =
          compare_lookup_binary_f64(compare_libm_handle, binary_f64);
      if (compare_libm_symbols.binary_f32[operation] == NULL ||
          compare_libm_symbols.binary_f64[operation] == NULL) {
        compare_fatal("glibc", binary_f32);
      }
    } else {
      compare_fatal("glibc", "operation symbol table");
    }
  }
}

static void compare_libm_ensure(void) {
  (void)pthread_once(&compare_libm_once, compare_libm_init);
}

static void compare_coremath_init(void) {
  compare_coremath_state.handle =
      dlopen(COMPARATIVE_COREMATH_PATH, RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
  if (compare_coremath_state.handle == NULL) {
    compare_fatal("CORE-MATH", COMPARATIVE_COREMATH_PATH);
  }

  CompareMetadata revision = (CompareMetadata)dlsym(
      compare_coremath_state.handle, "zmath_reference_coremath_revision");
  CompareMetadata compiler = (CompareMetadata)dlsym(
      compare_coremath_state.handle, "zmath_reference_coremath_compiler");
  CompareMetadata flags = (CompareMetadata)dlsym(
      compare_coremath_state.handle, "zmath_reference_coremath_flags");
  CompareMetadata source = (CompareMetadata)dlsym(
      compare_coremath_state.handle, "zmath_reference_coremath_source");
  if (revision == NULL || compiler == NULL || flags == NULL || source == NULL) {
    compare_fatal("CORE-MATH", "required metadata symbol");
  }
  compare_coremath_state.revision = revision();
  compare_coremath_state.compiler = compiler();
  compare_coremath_state.flags = flags();
  compare_coremath_state.source = source();
  if (compare_coremath_state.revision == NULL ||
      compare_coremath_state.compiler == NULL ||
      compare_coremath_state.flags == NULL ||
      compare_coremath_state.source == NULL ||
      compare_coremath_state.revision[0] == '\0' ||
      compare_coremath_state.compiler[0] == '\0' ||
      compare_coremath_state.flags[0] == '\0' ||
      compare_coremath_state.source[0] == '\0') {
    compare_fatal("CORE-MATH", "metadata value");
  }

  for (uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
       ++operation) {
    const char *unary_f16 = compare_core_unary_names_f16[operation];
    const char *binary_f16 = compare_core_binary_names_f16[operation];
    const char *unary_f32 = compare_core_unary_names_f32[operation];
    const char *unary_f64 = compare_core_unary_names_f64[operation];
    const char *binary_f32 = compare_core_binary_names_f32[operation];
    const char *binary_f64 = compare_core_binary_names_f64[operation];
    if (unary_f32 != NULL) {
      compare_coremath_state.symbols.unary_f32[operation] =
          compare_lookup_unary_f32(compare_coremath_state.handle, unary_f32);
      compare_coremath_state.symbols.unary_f64[operation] =
          compare_lookup_unary_f64(compare_coremath_state.handle, unary_f64);
      if (compare_coremath_state.symbols.unary_f32[operation] == NULL ||
          compare_coremath_state.symbols.unary_f64[operation] == NULL) {
        compare_fatal("CORE-MATH", unary_f32);
      }
    } else if (binary_f32 != NULL) {
      compare_coremath_state.symbols.binary_f32[operation] =
          compare_lookup_binary_f32(compare_coremath_state.handle, binary_f32);
      compare_coremath_state.symbols.binary_f64[operation] =
          compare_lookup_binary_f64(compare_coremath_state.handle, binary_f64);
      if (compare_coremath_state.symbols.binary_f32[operation] == NULL ||
          compare_coremath_state.symbols.binary_f64[operation] == NULL) {
        compare_fatal("CORE-MATH", binary_f32);
      }
    } else if (operation != COMPARE_SQRT) {
      compare_fatal("CORE-MATH", "operation symbol table");
    }
    if (unary_f16 != NULL) {
      compare_coremath_state.symbols.unary_f16[operation] =
          compare_lookup_unary_f16(compare_coremath_state.handle, unary_f16);
      if (compare_coremath_state.symbols.unary_f16[operation] == NULL) {
        compare_fatal("CORE-MATH", unary_f16);
      }
    } else if (binary_f16 != NULL) {
      compare_coremath_state.symbols.binary_f16[operation] =
          compare_lookup_binary_f16(compare_coremath_state.handle, binary_f16);
      if (compare_coremath_state.symbols.binary_f16[operation] == NULL) {
        compare_fatal("CORE-MATH", binary_f16);
      }
    } else {
      compare_fatal("CORE-MATH", "binary16 operation symbol table");
    }
  }
}

static void compare_coremath_ensure(void) {
  (void)pthread_once(&compare_coremath_once, compare_coremath_init);
}

#define DEFINE_GLIBC_UNARY(op, name)                                           \
  COMPARE_NOINLINE float compare_glibc_##name##_f32(float x, float y) {        \
    (void)y;                                                                   \
    return compare_libm_symbols.unary_f32[COMPARE_##op](x);                    \
  }                                                                            \
  COMPARE_NOINLINE double compare_glibc_##name##_f64(double x, double y) {     \
    (void)y;                                                                   \
    return compare_libm_symbols.unary_f64[COMPARE_##op](x);                    \
  }
COMPARE_GLIBC_UNARY_OPS(DEFINE_GLIBC_UNARY)
#undef DEFINE_GLIBC_UNARY

#define DEFINE_GLIBC_BINARY(op, name)                                          \
  COMPARE_NOINLINE float compare_glibc_##name##_f32(float x, float y) {        \
    return compare_libm_symbols.binary_f32[COMPARE_##op](x, y);                \
  }                                                                            \
  COMPARE_NOINLINE double compare_glibc_##name##_f64(double x, double y) {     \
    return compare_libm_symbols.binary_f64[COMPARE_##op](x, y);                \
  }
COMPARE_BINARY_OPS(DEFINE_GLIBC_BINARY)
#undef DEFINE_GLIBC_BINARY

#define DEFINE_CORE_UNARY(op, name)                                            \
  COMPARE_NOINLINE _Float16 compare_coremath_##name##_f16(_Float16 x,          \
                                                          _Float16 y) {        \
    (void)y;                                                                   \
    return compare_coremath_state.symbols.unary_f16[COMPARE_##op](x);          \
  }                                                                            \
  COMPARE_NOINLINE float compare_coremath_##name##_f32(float x, float y) {     \
    (void)y;                                                                   \
    return compare_coremath_state.symbols.unary_f32[COMPARE_##op](x);          \
  }                                                                            \
  COMPARE_NOINLINE double compare_coremath_##name##_f64(double x, double y) {  \
    (void)y;                                                                   \
    return compare_coremath_state.symbols.unary_f64[COMPARE_##op](x);          \
  }
COMPARE_CORE_UNARY_OPS(DEFINE_CORE_UNARY)
#undef DEFINE_CORE_UNARY

COMPARE_NOINLINE _Float16 compare_coremath_sqrt_f16(_Float16 x, _Float16 y) {
  (void)y;
  return compare_coremath_state.symbols.unary_f16[COMPARE_SQRT](x);
}

#define DEFINE_CORE_BINARY(op, name)                                           \
  COMPARE_NOINLINE _Float16 compare_coremath_##name##_f16(_Float16 x,          \
                                                          _Float16 y) {        \
    return compare_coremath_state.symbols.binary_f16[COMPARE_##op](x, y);      \
  }                                                                            \
  COMPARE_NOINLINE float compare_coremath_##name##_f32(float x, float y) {     \
    return compare_coremath_state.symbols.binary_f32[COMPARE_##op](x, y);      \
  }                                                                            \
  COMPARE_NOINLINE double compare_coremath_##name##_f64(double x, double y) {  \
    return compare_coremath_state.symbols.binary_f64[COMPARE_##op](x, y);      \
  }
COMPARE_BINARY_OPS(DEFINE_CORE_BINARY)
#undef DEFINE_CORE_BINARY

#define GLIBC_UNARY_WRAPPER_F32(op, name)                                      \
  [COMPARE_##op] = compare_glibc_##name##_f32,
#define GLIBC_UNARY_WRAPPER_F64(op, name)                                      \
  [COMPARE_##op] = compare_glibc_##name##_f64,
#define GLIBC_BINARY_WRAPPER_F32(op, name)                                     \
  [COMPARE_##op] = compare_glibc_##name##_f32,
#define GLIBC_BINARY_WRAPPER_F64(op, name)                                     \
  [COMPARE_##op] = compare_glibc_##name##_f64,
#define CORE_UNARY_WRAPPER_F16(op, name)                                       \
  [COMPARE_##op] = compare_coremath_##name##_f16,
#define CORE_BINARY_WRAPPER_F16(op, name)                                      \
  [COMPARE_##op] = compare_coremath_##name##_f16,
#define CORE_UNARY_WRAPPER_F32(op, name)                                       \
  [COMPARE_##op] = compare_coremath_##name##_f32,
#define CORE_UNARY_WRAPPER_F64(op, name)                                       \
  [COMPARE_##op] = compare_coremath_##name##_f64,
#define CORE_BINARY_WRAPPER_F32(op, name)                                      \
  [COMPARE_##op] = compare_coremath_##name##_f32,
#define CORE_BINARY_WRAPPER_F64(op, name)                                      \
  [COMPARE_##op] = compare_coremath_##name##_f64,

static const CompareF32 compare_glibc_wrappers_f32[COMPARE_OPERATION_COUNT] = {
    COMPARE_GLIBC_UNARY_OPS(GLIBC_UNARY_WRAPPER_F32)
        COMPARE_BINARY_OPS(GLIBC_BINARY_WRAPPER_F32)};
static const CompareF64 compare_glibc_wrappers_f64[COMPARE_OPERATION_COUNT] = {
    COMPARE_GLIBC_UNARY_OPS(GLIBC_UNARY_WRAPPER_F64)
        COMPARE_BINARY_OPS(GLIBC_BINARY_WRAPPER_F64)};
static const CompareF16 compare_coremath_wrappers_f16[COMPARE_OPERATION_COUNT] =
    {COMPARE_CORE_HALF_UNARY_OPS(CORE_UNARY_WRAPPER_F16)
         COMPARE_BINARY_OPS(CORE_BINARY_WRAPPER_F16)};
static const CompareF32 compare_coremath_wrappers_f32[COMPARE_OPERATION_COUNT] =
    {COMPARE_CORE_UNARY_OPS(CORE_UNARY_WRAPPER_F32)
         COMPARE_BINARY_OPS(CORE_BINARY_WRAPPER_F32)};
static const CompareF64 compare_coremath_wrappers_f64[COMPARE_OPERATION_COUNT] =
    {COMPARE_CORE_UNARY_OPS(CORE_UNARY_WRAPPER_F64)
         COMPARE_BINARY_OPS(CORE_BINARY_WRAPPER_F64)};

#undef GLIBC_UNARY_WRAPPER_F32
#undef GLIBC_UNARY_WRAPPER_F64
#undef GLIBC_BINARY_WRAPPER_F32
#undef GLIBC_BINARY_WRAPPER_F64
#undef CORE_UNARY_WRAPPER_F16
#undef CORE_BINARY_WRAPPER_F16
#undef CORE_UNARY_WRAPPER_F32
#undef CORE_UNARY_WRAPPER_F64
#undef CORE_BINARY_WRAPPER_F32
#undef CORE_BINARY_WRAPPER_F64

static const char *compare_origin_from_function(const void *function) {
  Dl_info info;
  if (function == NULL || dladdr(function, &info) == 0 ||
      info.dli_fname == NULL) {
    return NULL;
  }
  return info.dli_fname;
}

const char *compare_glibc_origin(uint32_t op, CompareFormat format) {
  if (op >= COMPARE_OPERATION_COUNT || format == COMPARE_F16 ||
      (format != COMPARE_F32 && format != COMPARE_F64)) {
    return NULL;
  }
  compare_libm_ensure();
  if (format == COMPARE_F32) {
    if (compare_libm_symbols.unary_f32[op] != NULL) {
      return compare_origin_from_function(
          (const void *)compare_libm_symbols.unary_f32[op]);
    }
    return compare_origin_from_function(
        (const void *)compare_libm_symbols.binary_f32[op]);
  }
  if (compare_libm_symbols.unary_f64[op] != NULL) {
    return compare_origin_from_function(
        (const void *)compare_libm_symbols.unary_f64[op]);
  }
  return compare_origin_from_function(
      (const void *)compare_libm_symbols.binary_f64[op]);
}

const char *compare_glibc_version(void) {
  compare_libm_ensure();
  return gnu_get_libc_version();
}

CompareF16 compare_glibc_f16(uint32_t op) {
  (void)op;
  return NULL;
}

CompareF32 compare_glibc_f32(uint32_t op) {
  if (op >= COMPARE_OPERATION_COUNT) {
    return NULL;
  }
  compare_libm_ensure();
  return compare_glibc_wrappers_f32[op];
}

CompareF64 compare_glibc_f64(uint32_t op) {
  if (op >= COMPARE_OPERATION_COUNT) {
    return NULL;
  }
  compare_libm_ensure();
  return compare_glibc_wrappers_f64[op];
}

CompareF16 compare_coremath_f16(uint32_t op) {
  if (op >= COMPARE_OPERATION_COUNT) {
    return NULL;
  }
  compare_coremath_ensure();
  return compare_coremath_wrappers_f16[op];
}

CompareF32 compare_coremath_f32(uint32_t op) {
  if (op >= COMPARE_OPERATION_COUNT) {
    return NULL;
  }
  compare_coremath_ensure();
  return compare_coremath_wrappers_f32[op];
}

CompareF64 compare_coremath_f64(uint32_t op) {
  if (op >= COMPARE_OPERATION_COUNT) {
    return NULL;
  }
  compare_coremath_ensure();
  return compare_coremath_wrappers_f64[op];
}

const char *compare_coremath_revision(void) {
  compare_coremath_ensure();
  return compare_coremath_state.revision;
}

const char *compare_coremath_compiler(void) {
  compare_coremath_ensure();
  return compare_coremath_state.compiler;
}

const char *compare_coremath_flags(void) {
  compare_coremath_ensure();
  return compare_coremath_state.flags;
}

const char *compare_coremath_source(void) {
  compare_coremath_ensure();
  return compare_coremath_state.source;
}

const char *compare_coremath_origin(uint32_t op, CompareFormat format) {
  if (op >= COMPARE_OPERATION_COUNT ||
      (format != COMPARE_F16 && format != COMPARE_F32 &&
       format != COMPARE_F64)) {
    return NULL;
  }
  compare_coremath_ensure();
  if (format == COMPARE_F16) {
    if (compare_coremath_state.symbols.unary_f16[op] != NULL) {
      return compare_origin_from_function(
          (const void *)compare_coremath_state.symbols.unary_f16[op]);
    }
    return compare_origin_from_function(
        (const void *)compare_coremath_state.symbols.binary_f16[op]);
  }
  if (format == COMPARE_F32) {
    if (compare_coremath_state.symbols.unary_f32[op] != NULL) {
      return compare_origin_from_function(
          (const void *)compare_coremath_state.symbols.unary_f32[op]);
    }
    return compare_origin_from_function(
        (const void *)compare_coremath_state.symbols.binary_f32[op]);
  }
  if (compare_coremath_state.symbols.unary_f64[op] != NULL) {
    return compare_origin_from_function(
        (const void *)compare_coremath_state.symbols.unary_f64[op]);
  }
  return compare_origin_from_function(
      (const void *)compare_coremath_state.symbols.binary_f64[op]);
}

#undef GLIBC_UNARY_NAME
#undef GLIBC_BINARY_NAME
#undef CORE_UNARY_NAME
#undef CORE_BINARY_NAME
#undef COMPARE_GLIBC_UNARY_OPS
#undef COMPARE_CORE_UNARY_OPS
#undef COMPARE_BINARY_OPS
#undef COMPARE_CORE_HALF_UNARY_OPS
