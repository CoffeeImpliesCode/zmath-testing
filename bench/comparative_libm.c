#define _GNU_SOURCE

#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#include "comparative.h"

#if defined(__clang__)
#define COMPARE_NOINLINE __attribute__((noinline))
#elif defined(__GNUC__)
#define COMPARE_NOINLINE __attribute__((noinline, noclone))
#else
#define COMPARE_NOINLINE
#endif

/*
 * The C provider is compiled with -fno-builtin, -fno-fast-math, and no LTO.
 * Every timed call goes through one of these cached function pointers. The
 * wrapper dispatch therefore includes the ordinary indirect library call
 * overhead, while dlopen/dlsym and validation stay on the setup path.
 */
#ifndef COMPARATIVE_LIBM_PATH
#error "COMPARATIVE_LIBM_PATH must be defined"
#endif

typedef float (*CompareUnaryF32)(float);
typedef double (*CompareUnaryF64)(double);
typedef float (*CompareBinaryF32)(float, float);
typedef double (*CompareBinaryF64)(double, double);

typedef struct {
  CompareUnaryF32 exp_f32;
  CompareUnaryF32 log_f32;
  CompareUnaryF32 sin_f32;
  CompareUnaryF32 cos_f32;
  CompareUnaryF32 tan_f32;
  CompareUnaryF32 sqrt_f32;
  CompareBinaryF32 hypot_f32;
  CompareBinaryF32 atan2_f32;
  CompareBinaryF32 pow_f32;
  CompareUnaryF64 exp_f64;
  CompareUnaryF64 log_f64;
  CompareUnaryF64 sin_f64;
  CompareUnaryF64 cos_f64;
  CompareUnaryF64 tan_f64;
  CompareUnaryF64 sqrt_f64;
  CompareBinaryF64 hypot_f64;
  CompareBinaryF64 atan2_f64;
  CompareBinaryF64 pow_f64;
} CompareLibmSymbols;

static CompareLibmSymbols compare_libm_symbols;
static void *compare_libm_handle;
static pthread_once_t compare_libm_once = PTHREAD_ONCE_INIT;

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

static void compare_libm_init(void) {
  compare_libm_handle = dlopen(COMPARATIVE_LIBM_PATH, RTLD_NOW | RTLD_LOCAL);
  if (compare_libm_handle == NULL) {
    return;
  }

  compare_libm_symbols.exp_f32 =
      compare_lookup_unary_f32(compare_libm_handle, "expf");
  compare_libm_symbols.log_f32 =
      compare_lookup_unary_f32(compare_libm_handle, "logf");
  compare_libm_symbols.sin_f32 =
      compare_lookup_unary_f32(compare_libm_handle, "sinf");
  compare_libm_symbols.cos_f32 =
      compare_lookup_unary_f32(compare_libm_handle, "cosf");
  compare_libm_symbols.tan_f32 =
      compare_lookup_unary_f32(compare_libm_handle, "tanf");
  compare_libm_symbols.sqrt_f32 =
      compare_lookup_unary_f32(compare_libm_handle, "sqrtf");
  compare_libm_symbols.hypot_f32 =
      compare_lookup_binary_f32(compare_libm_handle, "hypotf");
  compare_libm_symbols.atan2_f32 =
      compare_lookup_binary_f32(compare_libm_handle, "atan2f");
  compare_libm_symbols.pow_f32 =
      compare_lookup_binary_f32(compare_libm_handle, "powf");
  compare_libm_symbols.exp_f64 =
      compare_lookup_unary_f64(compare_libm_handle, "exp");
  compare_libm_symbols.log_f64 =
      compare_lookup_unary_f64(compare_libm_handle, "log");
  compare_libm_symbols.sin_f64 =
      compare_lookup_unary_f64(compare_libm_handle, "sin");
  compare_libm_symbols.cos_f64 =
      compare_lookup_unary_f64(compare_libm_handle, "cos");
  compare_libm_symbols.tan_f64 =
      compare_lookup_unary_f64(compare_libm_handle, "tan");
  compare_libm_symbols.sqrt_f64 =
      compare_lookup_unary_f64(compare_libm_handle, "sqrt");
  compare_libm_symbols.hypot_f64 =
      compare_lookup_binary_f64(compare_libm_handle, "hypot");
  compare_libm_symbols.atan2_f64 =
      compare_lookup_binary_f64(compare_libm_handle, "atan2");
  compare_libm_symbols.pow_f64 =
      compare_lookup_binary_f64(compare_libm_handle, "pow");
}

static void compare_libm_ensure(void) {
  (void)pthread_once(&compare_libm_once, compare_libm_init);
}

COMPARE_NOINLINE float compare_glibc_exp_f32(float x, float y) {
  (void)y;
  return compare_libm_symbols.exp_f32(x);
}

COMPARE_NOINLINE float compare_glibc_log_f32(float x, float y) {
  (void)y;
  return compare_libm_symbols.log_f32(x);
}

COMPARE_NOINLINE float compare_glibc_sin_f32(float x, float y) {
  (void)y;
  return compare_libm_symbols.sin_f32(x);
}

COMPARE_NOINLINE float compare_glibc_cos_f32(float x, float y) {
  (void)y;
  return compare_libm_symbols.cos_f32(x);
}

COMPARE_NOINLINE float compare_glibc_tan_f32(float x, float y) {
  (void)y;
  return compare_libm_symbols.tan_f32(x);
}

COMPARE_NOINLINE float compare_glibc_sqrt_f32(float x, float y) {
  (void)y;
  return compare_libm_symbols.sqrt_f32(x);
}

COMPARE_NOINLINE float compare_glibc_hypot_f32(float x, float y) {
  return compare_libm_symbols.hypot_f32(x, y);
}

COMPARE_NOINLINE float compare_glibc_atan2_f32(float y, float x) {
  return compare_libm_symbols.atan2_f32(y, x);
}

COMPARE_NOINLINE float compare_glibc_pow_f32(float x, float y) {
  return compare_libm_symbols.pow_f32(x, y);
}

COMPARE_NOINLINE double compare_glibc_exp_f64(double x, double y) {
  (void)y;
  return compare_libm_symbols.exp_f64(x);
}

COMPARE_NOINLINE double compare_glibc_log_f64(double x, double y) {
  (void)y;
  return compare_libm_symbols.log_f64(x);
}

COMPARE_NOINLINE double compare_glibc_sin_f64(double x, double y) {
  (void)y;
  return compare_libm_symbols.sin_f64(x);
}

COMPARE_NOINLINE double compare_glibc_cos_f64(double x, double y) {
  (void)y;
  return compare_libm_symbols.cos_f64(x);
}

COMPARE_NOINLINE double compare_glibc_tan_f64(double x, double y) {
  (void)y;
  return compare_libm_symbols.tan_f64(x);
}

COMPARE_NOINLINE double compare_glibc_sqrt_f64(double x, double y) {
  (void)y;
  return compare_libm_symbols.sqrt_f64(x);
}

COMPARE_NOINLINE double compare_glibc_hypot_f64(double x, double y) {
  return compare_libm_symbols.hypot_f64(x, y);
}

COMPARE_NOINLINE double compare_glibc_atan2_f64(double y, double x) {
  return compare_libm_symbols.atan2_f64(y, x);
}

COMPARE_NOINLINE double compare_glibc_pow_f64(double x, double y) {
  return compare_libm_symbols.pow_f64(x, y);
}

/*
 * POSIX dladdr accepts code addresses as const void *. The cast is confined to
 * that API boundary; every symbol keeps its declared math prototype.
 */
#define COMPARE_RETURN_ORIGIN(function)                                        \
  do {                                                                         \
    Dl_info info;                                                              \
    if ((function) == NULL || dladdr((const void *)(function), &info) == 0 ||  \
        info.dli_fname == NULL) {                                              \
      return NULL;                                                             \
    }                                                                          \
    return info.dli_fname;                                                     \
  } while (0)

const char *compare_glibc_origin(uint32_t op, uint32_t single) {
  compare_libm_ensure();
  if (single > 1U) {
    return NULL;
  }

  switch (op) {
  case COMPARE_EXP:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.exp_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.exp_f64);
  case COMPARE_LOG:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.log_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.log_f64);
  case COMPARE_SIN:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.sin_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.sin_f64);
  case COMPARE_COS:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.cos_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.cos_f64);
  case COMPARE_TAN:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.tan_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.tan_f64);
  case COMPARE_SQRT:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.sqrt_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.sqrt_f64);
  case COMPARE_HYPOT:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.hypot_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.hypot_f64);
  case COMPARE_ATAN2:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.atan2_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.atan2_f64);
  case COMPARE_POW:
    if (single == 1U) {
      COMPARE_RETURN_ORIGIN(compare_libm_symbols.pow_f32);
    }
    COMPARE_RETURN_ORIGIN(compare_libm_symbols.pow_f64);
  default:
    return NULL;
  }
}

#undef COMPARE_RETURN_ORIGIN

const char *compare_glibc_version(void) { return gnu_get_libc_version(); }

/*
 * Vendored CORE-MATH symbols from revision
 * 3bafed75e3c22399531857d63a3fa0e24bfb42fa, linked by zmath:
 *   cr_atan2f(float, float), cr_powf(float, float), and
 *   cr_pow(double, double).
 *
 * The binary64 atan2 source exports only an out-parameter/status API, which
 * does not match CompareF64 and is therefore intentionally unsupported here.
 * The other six operations have no matching vendored scalar symbols.
 */
extern float cr_atan2f(float, float);
extern float cr_powf(float, float);
extern double cr_pow(double, double);

COMPARE_NOINLINE float compare_coremath_atan2_f32(float y, float x) {
  return cr_atan2f(y, x);
}

COMPARE_NOINLINE float compare_coremath_pow_f32(float x, float y) {
  return cr_powf(x, y);
}

COMPARE_NOINLINE double compare_coremath_pow_f64(double x, double y) {
  return cr_pow(x, y);
}

CompareF32 compare_glibc_f32(uint32_t op) {
  compare_libm_ensure();
  switch (op) {
  case COMPARE_EXP:
    return compare_libm_symbols.exp_f32 != NULL ? compare_glibc_exp_f32 : NULL;
  case COMPARE_LOG:
    return compare_libm_symbols.log_f32 != NULL ? compare_glibc_log_f32 : NULL;
  case COMPARE_SIN:
    return compare_libm_symbols.sin_f32 != NULL ? compare_glibc_sin_f32 : NULL;
  case COMPARE_COS:
    return compare_libm_symbols.cos_f32 != NULL ? compare_glibc_cos_f32 : NULL;
  case COMPARE_TAN:
    return compare_libm_symbols.tan_f32 != NULL ? compare_glibc_tan_f32 : NULL;
  case COMPARE_SQRT:
    return compare_libm_symbols.sqrt_f32 != NULL ? compare_glibc_sqrt_f32
                                                 : NULL;
  case COMPARE_HYPOT:
    return compare_libm_symbols.hypot_f32 != NULL ? compare_glibc_hypot_f32
                                                  : NULL;
  case COMPARE_ATAN2:
    return compare_libm_symbols.atan2_f32 != NULL ? compare_glibc_atan2_f32
                                                  : NULL;
  case COMPARE_POW:
    return compare_libm_symbols.pow_f32 != NULL ? compare_glibc_pow_f32 : NULL;
  default:
    return NULL;
  }
}

CompareF64 compare_glibc_f64(uint32_t op) {
  compare_libm_ensure();
  switch (op) {
  case COMPARE_EXP:
    return compare_libm_symbols.exp_f64 != NULL ? compare_glibc_exp_f64 : NULL;
  case COMPARE_LOG:
    return compare_libm_symbols.log_f64 != NULL ? compare_glibc_log_f64 : NULL;
  case COMPARE_SIN:
    return compare_libm_symbols.sin_f64 != NULL ? compare_glibc_sin_f64 : NULL;
  case COMPARE_COS:
    return compare_libm_symbols.cos_f64 != NULL ? compare_glibc_cos_f64 : NULL;
  case COMPARE_TAN:
    return compare_libm_symbols.tan_f64 != NULL ? compare_glibc_tan_f64 : NULL;
  case COMPARE_SQRT:
    return compare_libm_symbols.sqrt_f64 != NULL ? compare_glibc_sqrt_f64
                                                 : NULL;
  case COMPARE_HYPOT:
    return compare_libm_symbols.hypot_f64 != NULL ? compare_glibc_hypot_f64
                                                  : NULL;
  case COMPARE_ATAN2:
    return compare_libm_symbols.atan2_f64 != NULL ? compare_glibc_atan2_f64
                                                  : NULL;
  case COMPARE_POW:
    return compare_libm_symbols.pow_f64 != NULL ? compare_glibc_pow_f64 : NULL;
  default:
    return NULL;
  }
}

CompareF32 compare_coremath_f32(uint32_t op) {
  switch (op) {
  case COMPARE_ATAN2:
    return compare_coremath_atan2_f32;
  case COMPARE_POW:
    return compare_coremath_pow_f32;
  default:
    return NULL;
  }
}

CompareF64 compare_coremath_f64(uint32_t op) {
  switch (op) {
  case COMPARE_POW:
    return compare_coremath_pow_f64;
  default:
    return NULL;
  }
}
