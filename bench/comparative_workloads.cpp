#include "comparative_workloads.hpp"

#include <mpfr.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>

namespace comparative {
namespace {

constexpr unsigned mpfr_precision_bits = 512;
constexpr std::size_t special_value_count = 16;

// These are deliberately explicit IEEE encodings. They are copied into
// floating objects with memcpy, never through a type-punning pointer.
constexpr std::uint32_t special_f32_bits[special_value_count] = {
    UINT32_C(0x00000000), // +0
    UINT32_C(0x80000000), // -0
    UINT32_C(0x00000001), // +minimum subnormal
    UINT32_C(0x80000001), // -minimum subnormal
    UINT32_C(0x00800000), // +minimum normal
    UINT32_C(0x80800000), // -minimum normal
    UINT32_C(0x7f7fffff), // +maximum finite
    UINT32_C(0xff7fffff), // -maximum finite
    UINT32_C(0x7f800000), // +infinity
    UINT32_C(0xff800000), // -infinity
    UINT32_C(0x7fc00001), // +quiet NaN
    UINT32_C(0xffc00001), // -quiet NaN
    UINT32_C(0x7f800001), // +signaling NaN
    UINT32_C(0xff800001), // -signaling NaN
    UINT32_C(0x7fc12345), // +quiet NaN with another payload
    UINT32_C(0xff812345), // -signaling NaN with another payload
};

constexpr std::uint64_t special_f64_bits[special_value_count] = {
    UINT64_C(0x0000000000000000), // +0
    UINT64_C(0x8000000000000000), // -0
    UINT64_C(0x0000000000000001), // +minimum subnormal
    UINT64_C(0x8000000000000001), // -minimum subnormal
    UINT64_C(0x0010000000000000), // +minimum normal
    UINT64_C(0x8010000000000000), // -minimum normal
    UINT64_C(0x7fefffffffffffff), // +maximum finite
    UINT64_C(0xffefffffffffffff), // -maximum finite
    UINT64_C(0x7ff0000000000000), // +infinity
    UINT64_C(0xfff0000000000000), // -infinity
    UINT64_C(0x7ff8000000000001), // +quiet NaN
    UINT64_C(0xfff8000000000001), // -quiet NaN
    UINT64_C(0x7ff0000000000001), // +signaling NaN
    UINT64_C(0xfff0000000000001), // -signaling NaN
    UINT64_C(0x7ff8123456789abc), // +quiet NaN with another payload
    UINT64_C(0xfff0123456789abc), // -signaling NaN with another payload
};

constexpr std::uint16_t special_f16_bits[special_value_count] = {
    UINT16_C(0x0000), // +0
    UINT16_C(0x8000), // -0
    UINT16_C(0x0001), // +minimum subnormal
    UINT16_C(0x8001), // -minimum subnormal
    UINT16_C(0x0400), // +minimum normal
    UINT16_C(0x8400), // -minimum normal
    UINT16_C(0x7bff), // +maximum finite
    UINT16_C(0xfbff), // -maximum finite
    UINT16_C(0x7c00), // +infinity
    UINT16_C(0xfc00), // -infinity
    UINT16_C(0x7e01), // +quiet NaN
    UINT16_C(0xfe01), // -quiet NaN
    UINT16_C(0x7c01), // +signaling NaN
    UINT16_C(0xfc01), // -signaling NaN
    UINT16_C(0x7f09), // +quiet NaN with another payload
    UINT16_C(0xfc89), // -signaling NaN with another payload
};

class Rng {
public:
  explicit Rng(std::uint64_t state) : state_(state) {}

  std::uint64_t next() {
    // SplitMix64 is specified in unsigned arithmetic, so its sequence is
    // independent of implementation-defined integer overflow behavior.
    state_ += UINT64_C(0x9e3779b97f4a7c15);
    std::uint64_t z = state_;
    z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
    return z ^ (z >> 31);
  }

  double unit() { return static_cast<double>(next() >> 11) * 0x1.0p-53; }

  bool sign() { return (next() & UINT64_C(1)) != 0; }

private:
  std::uint64_t state_;
};

template <typename T> T bits_to_value(std::uint64_t bits) {
  T value;
  static_assert(sizeof(T) <= sizeof(bits), "unexpected floating width");
  std::memcpy(&value, &bits, sizeof(T));
  return value;
}

template <typename T> std::uint64_t value_to_bits(T value) {
  std::uint64_t bits = 0;
  std::memcpy(&bits, &value, sizeof(value));
  return bits;
}

// Convert an IEEE binary32 encoding to a double without asking the host to
// convert a signaling NaN (which is allowed to quiet it). Finite encodings are
// converted by the language after the exact f32 value is reconstructed.
double f32_bits_to_double(std::uint32_t bits) {
  const std::uint32_t exponent = (bits >> 23) & UINT32_C(0xff);
  const std::uint32_t fraction = bits & UINT32_C(0x7fffff);
  if (exponent == UINT32_C(0xff) && fraction != 0) {
    const std::uint64_t sign = (bits & UINT32_C(0x80000000)) != 0
                                   ? UINT64_C(0x8000000000000000)
                                   : UINT64_C(0);
    const std::uint64_t widened_fraction = static_cast<std::uint64_t>(fraction)
                                           << 29;
    return bits_to_value<double>(sign | UINT64_C(0x7ff0000000000000) |
                                 widened_fraction);
  }
  const float value = bits_to_value<float>(bits);
  return static_cast<double>(value);
}

double f16_bits_to_double(std::uint16_t bits) {
  const std::uint16_t exponent = (bits >> 10) & UINT16_C(0x1f);
  const std::uint16_t fraction = bits & UINT16_C(0x03ff);
  if (exponent == UINT16_C(0x1f) && fraction != 0) {
    const std::uint64_t sign = (bits & UINT16_C(0x8000)) != 0
                                   ? UINT64_C(0x8000000000000000)
                                   : UINT64_C(0);
    const std::uint64_t widened_fraction = static_cast<std::uint64_t>(fraction)
                                           << 42;
    return bits_to_value<double>(sign | UINT64_C(0x7ff0000000000000) |
                                 widened_fraction);
  }
  const _Float16 value = bits_to_value<_Float16>(bits);
  return static_cast<double>(value);
}

_Float16 narrow_half(double value) {
  if (std::isnan(value)) {
    const std::uint64_t bits = value_to_bits(value);
    const std::uint16_t source_fraction =
        static_cast<std::uint16_t>((bits & UINT64_C(0x000fffffffffffff)) >> 42);
    std::uint16_t fraction = source_fraction & UINT16_C(0x03ff);
    if (fraction == 0)
      fraction = UINT16_C(1);
    const std::uint16_t sign = (bits & UINT64_C(0x8000000000000000)) != 0
                                   ? UINT16_C(0x8000)
                                   : UINT16_C(0);
    return bits_to_value<_Float16>(sign | UINT16_C(0x7c00) | fraction);
  }
  return static_cast<_Float16>(value);
}

std::uint16_t f16_step(std::uint16_t bits, bool toward_positive) {
  const std::uint16_t magnitude = bits & UINT16_C(0x7fff);
  if (magnitude == 0)
    return toward_positive ? UINT16_C(0x0001) : UINT16_C(0x8001);
  const bool negative = (bits & UINT16_C(0x8000)) != 0;
  if (negative)
    return toward_positive ? static_cast<std::uint16_t>(bits - 1)
                           : static_cast<std::uint16_t>(bits + 1);
  return toward_positive ? static_cast<std::uint16_t>(bits + 1)
                         : static_cast<std::uint16_t>(bits - 1);
}

void reject_bad_format(CompareFormat format) {
  if (format != COMPARE_F64 && format != COMPARE_F32 && format != COMPARE_F16) {
    throw std::invalid_argument("comparative: unknown comparison format");
  }
}

double special_value(std::size_t index, CompareFormat format) {
  index %= special_value_count;
  switch (format) {
  case COMPARE_F64:
    return bits_to_value<double>(special_f64_bits[index]);
  case COMPARE_F32:
    return f32_bits_to_double(special_f32_bits[index]);
  case COMPARE_F16:
    return f16_bits_to_double(special_f16_bits[index]);
  default:
    break;
  }
  reject_bad_format(format);
  return 0.0;
}

double uniform(Rng &rng, double low, double high) {
  return low + (high - low) * rng.unit();
}

double signed_scaled(Rng &rng, int low_exponent, int high_exponent) {
  const int span = high_exponent - low_exponent + 1;
  const int exponent =
      low_exponent +
      static_cast<int>(rng.next() % static_cast<std::uint64_t>(span));
  const double magnitude = std::ldexp(0.5 + 1.5 * rng.unit(), exponent);
  return rng.sign() ? -magnitude : magnitude;
}

double positive_scaled(Rng &rng, int low_exponent, int high_exponent) {
  const int span = high_exponent - low_exponent + 1;
  const int exponent =
      low_exponent +
      static_cast<int>(rng.next() % static_cast<std::uint64_t>(span));
  return std::ldexp(0.5 + 1.5 * rng.unit(), exponent);
}

double narrow_if_requested(double value, CompareFormat format) {
  switch (format) {
  case COMPARE_F64:
    return value;
  case COMPARE_F32:
    return static_cast<double>(static_cast<float>(value));
  case COMPARE_F16:
    return static_cast<double>(narrow_half(value));
  default:
    break;
  }
  reject_bad_format(format);
  return 0.0;
}

std::uint64_t target_bits(double value, CompareFormat format) {
  switch (format) {
  case COMPARE_F64:
    return value_to_bits(value);
  case COMPARE_F32:
    return value_to_bits(input_f32(value));
  case COMPARE_F16:
    return value_to_bits(narrow_half(value)) & UINT64_C(0xffff);
  default:
    break;
  }
  reject_bad_format(format);
  return 0;
}

double target_step(double value, CompareFormat format, bool toward_positive) {
  switch (format) {
  case COMPARE_F64:
    return std::nextafter(
        value, toward_positive ? std::numeric_limits<double>::infinity()
                               : -std::numeric_limits<double>::infinity());
  case COMPARE_F32: {
    const float narrowed = static_cast<float>(value);
    return static_cast<double>(std::nextafterf(
        narrowed, toward_positive ? std::numeric_limits<float>::infinity()
                                  : -std::numeric_limits<float>::infinity()));
  }
  case COMPARE_F16: {
    const std::uint16_t bits =
        static_cast<std::uint16_t>(value_to_bits(narrow_half(value)));
    return f16_bits_to_double(f16_step(bits, toward_positive));
  }
  default:
    break;
  }
  reject_bad_format(format);
  return 0.0;
}

void reject_bad_operation(std::uint32_t operation) {
  if (operation >= static_cast<std::uint32_t>(COMPARE_OPERATION_COUNT)) {
    throw std::invalid_argument(
        "comparative: operation is outside COMPARE_OPERATION_COUNT");
  }
}

struct GeneratedPair {
  double first;
  double second;
};

double inverse_argument(Rng &rng, std::size_t index, CompareFormat format) {
  switch (index & 7U) {
  case 0:
    return -1.0;
  case 1:
    return 1.0;
  case 2:
    return target_step(-1.0, format, true);
  case 3:
    return target_step(1.0, format, false);
  default:
    return uniform(rng, -0.95, 0.95);
  }
}

double atanh_argument(Rng &rng, std::size_t index, CompareFormat format) {
  switch (index & 7U) {
  case 0:
    return target_step(-1.0, format, true);
  case 1:
    return target_step(1.0, format, false);
  default:
    return uniform(rng, -0.95, 0.95);
  }
}

double acosh_argument(Rng &rng, std::size_t index, CompareFormat format) {
  if ((index & 7U) == 0)
    return 1.0;
  if ((index & 7U) == 1)
    return target_step(1.0, format, true);
  return 1.0 + uniform(rng, 0.01, 64.0);
}

double log1p_argument(Rng &rng, std::size_t index, CompareFormat format) {
  if ((index & 7U) == 0)
    return target_step(-1.0, format, true);
  if ((index & 7U) == 1)
    return -0.5;
  return uniform(rng, -0.9, 16.0);
}

double gamma_argument(Rng &rng, std::size_t index, bool wide,
                      CompareFormat format) {
  const bool negative = (index & 1U) != 0;
  if (!negative) {
    const double upper = format == COMPARE_F16 ? 8.0 : (wide ? 32.0 : 16.0);
    return uniform(rng, 0.125, upper);
  }
  const int integer_part = static_cast<int>(
      rng.next() % static_cast<std::uint64_t>(wide ? 32U : 8U));
  return -static_cast<double>(integer_part) - uniform(rng, 0.25, 0.75);
}

double tanpi_argument(Rng &rng, bool wide, CompareFormat format) {
  const int integer_part =
      static_cast<int>(rng.next() %
                       static_cast<std::uint64_t>(wide ? 64U : 8U)) -
      (wide ? 32 : 4);
  const double offset = uniform(rng, -0.45, 0.45);
  return narrow_if_requested(static_cast<double>(integer_part) + offset,
                             format);
}

GeneratedPair generate_normal(std::uint32_t operation, Rng &rng,
                              CompareFormat format, std::size_t index) {
  const bool single = format == COMPARE_F32;
  switch (operation) {
  case COMPARE_EXP:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_LOG:
    return {uniform(rng, 0.125, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_SIN:
  case COMPARE_COS:
    return {uniform(rng, -16.0, 16.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_TAN:
    return {uniform(rng, -3.0, 3.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_SQRT:
    return {uniform(rng, 0.125, 256.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_HYPOT:
  case COMPARE_ATAN2:
    return {uniform(rng, -128.0, 128.0), uniform(rng, -128.0, 128.0)};
  case COMPARE_POW:
    // Positive bases and modest exponents keep the reference inexpensive
    // while still exercising both fractional and integral powers.
    return {uniform(rng, 0.25, 4.0), uniform(rng, -4.0, 4.0)};
  case COMPARE_ACOS:
  case COMPARE_ASIN:
  case COMPARE_ACOSPI:
  case COMPARE_ASINPI:
    return {inverse_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_ACOSH:
    return {acosh_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_ASINH:
    return {uniform(rng, -16.0, 16.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_ATAN:
    return {uniform(rng, -32.0, 32.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_ATAN2PI:
    return {uniform(rng, -128.0, 128.0), uniform(rng, -128.0, 128.0)};
  case COMPARE_ATANH:
    return {atanh_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_ATANPI:
    return {uniform(rng, -32.0, 32.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_CBRT:
    return {uniform(rng, -256.0, 256.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_COSH:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_COSPI:
  case COMPARE_SINPI:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_ERF:
  case COMPARE_ERFC:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP10:
    return {uniform(rng, format == COMPARE_F16 ? -4.0 : -8.0,
                    format == COMPARE_F16 ? 4.0 : 8.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP10M1:
    return {uniform(rng, -4.0, 4.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP2:
    return {uniform(rng, format == COMPARE_F16 ? -14.0 : -32.0,
                    format == COMPARE_F16 ? 14.0 : 32.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP2M1:
    return {uniform(rng, format == COMPARE_F16 ? -14.0 : -16.0,
                    format == COMPARE_F16 ? 14.0 : 16.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXPM1:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_LGAMMA:
  case COMPARE_TGAMMA:
    return {gamma_argument(rng, index, false, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_LOG10:
  case COMPARE_LOG2:
    return {uniform(rng, 0.125, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_LOG10P1:
  case COMPARE_LOG1P:
  case COMPARE_LOG2P1:
    return {log1p_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_RSQRT:
    return {uniform(rng, 0.125, 256.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_SINH:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_TANH:
    return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
  case COMPARE_TANPI:
    return {tanpi_argument(rng, false, format), uniform(rng, -1.0, 1.0)};
  default:
    break;
  }
  (void)single;
  throw std::invalid_argument("comparative: unknown normal operation");
}

GeneratedPair generate_wide(std::uint32_t operation, Rng &rng,
                            CompareFormat format, std::size_t index) {
  const bool single = format == COMPARE_F32;
  if (format == COMPARE_F16) {
    switch (operation) {
    case COMPARE_EXP:
      return {uniform(rng, -11.0, 11.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_LOG:
      return {positive_scaled(rng, -14, 14), uniform(rng, -1.0, 1.0)};
    case COMPARE_SIN:
    case COMPARE_COS:
    case COMPARE_TAN:
      return {signed_scaled(rng, -8, 8), uniform(rng, -1.0, 1.0)};
    case COMPARE_SQRT:
      return {positive_scaled(rng, -14, 14), uniform(rng, -1.0, 1.0)};
    case COMPARE_HYPOT:
    case COMPARE_ATAN2:
      return {signed_scaled(rng, -14, 14), signed_scaled(rng, -14, 14)};
    case COMPARE_POW:
      return {positive_scaled(rng, -10, 10), uniform(rng, -8.0, 8.0)};
    case COMPARE_COSH:
      return {uniform(rng, -11.0, 11.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_EXP10:
      return {uniform(rng, -4.0, 4.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_EXP10M1:
      return {uniform(rng, -3.0, 3.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_EXP2:
      return {uniform(rng, -14.0, 14.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_EXP2M1:
      return {uniform(rng, -14.0, 14.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_EXPM1:
      return {uniform(rng, -11.0, 11.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_ERF:
    case COMPARE_ERFC:
      return {uniform(rng, -8.0, 8.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_ACOS:
    case COMPARE_ASIN:
    case COMPARE_ACOSPI:
    case COMPARE_ASINPI:
      return {inverse_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
    case COMPARE_ACOSH:
      return {acosh_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
    case COMPARE_ASINH:
    case COMPARE_ATAN:
    case COMPARE_ATANPI:
      return {signed_scaled(rng, -10, 10), uniform(rng, -1.0, 1.0)};
    case COMPARE_ATAN2PI:
      return {signed_scaled(rng, -14, 14), signed_scaled(rng, -14, 14)};
    case COMPARE_ATANH:
      return {atanh_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
    case COMPARE_CBRT:
      return {signed_scaled(rng, -14, 14), uniform(rng, -1.0, 1.0)};
    case COMPARE_COSPI:
    case COMPARE_SINPI:
      return {signed_scaled(rng, -8, 8), uniform(rng, -1.0, 1.0)};
    case COMPARE_LGAMMA:
    case COMPARE_TGAMMA:
      return {gamma_argument(rng, index, true, format),
              uniform(rng, -1.0, 1.0)};
    case COMPARE_LOG10:
    case COMPARE_LOG2:
      return {positive_scaled(rng, -14, 14), uniform(rng, -1.0, 1.0)};
    case COMPARE_LOG10P1:
    case COMPARE_LOG1P:
    case COMPARE_LOG2P1:
      return {log1p_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
    case COMPARE_RSQRT:
      return {positive_scaled(rng, -14, 14), uniform(rng, -1.0, 1.0)};
    case COMPARE_SINH:
      return {uniform(rng, -11.0, 11.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_TANH:
      return {uniform(rng, -11.0, 11.0), uniform(rng, -1.0, 1.0)};
    case COMPARE_TANPI:
      return {tanpi_argument(rng, true, format), uniform(rng, -1.0, 1.0)};
    default:
      break;
    }
    throw std::invalid_argument("comparative: unknown wide operation");
  }

  const int finite_low = single ? -120 : -1000;
  const int finite_high = single ? 120 : 1000;
  switch (operation) {
  case COMPARE_EXP:
    // Keep both precisions within a useful finite-input envelope. Outputs
    // may still overflow naturally and are audited as a status difference.
    return {uniform(rng, single ? -80.0 : -700.0, single ? 80.0 : 700.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_LOG:
    return {positive_scaled(rng, finite_low, finite_high),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_SIN:
  case COMPARE_COS:
  case COMPARE_TAN:
    // Large finite angles stress range reduction without making MPFR
    // process thousands of decimal exponent digits.
    return {signed_scaled(rng, single ? -10 : -20, single ? 10 : 20),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_SQRT:
    return {positive_scaled(rng, finite_low, finite_high),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_HYPOT:
  case COMPARE_ATAN2:
    return {signed_scaled(rng, finite_low, finite_high),
            signed_scaled(rng, finite_low, finite_high)};
  case COMPARE_POW:
    // Exponents are deliberately bounded. The base still spans many
    // finite exponents, but MPFR never receives a pathological exponent.
    return {positive_scaled(rng, single ? -30 : -128, single ? 30 : 128),
            uniform(rng, -4.0, 4.0)};
  case COMPARE_ACOS:
  case COMPARE_ASIN:
  case COMPARE_ACOSPI:
  case COMPARE_ASINPI:
    return {inverse_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_ACOSH:
    return {1.0 + positive_scaled(rng, single ? -10 : -32, single ? 10 : 32),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_ASINH:
    return {signed_scaled(rng, single ? -20 : -100, single ? 20 : 100),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_ATAN:
  case COMPARE_ATANPI:
    return {signed_scaled(rng, single ? -20 : -100, single ? 20 : 100),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_ATAN2PI:
    return {signed_scaled(rng, finite_low, finite_high),
            signed_scaled(rng, finite_low, finite_high)};
  case COMPARE_ATANH:
    return {atanh_argument(rng, index, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_CBRT:
    return {signed_scaled(rng, finite_low, finite_high),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_COSH:
    return {uniform(rng, single ? -80.0 : -700.0, single ? 80.0 : 700.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_COSPI:
  case COMPARE_SINPI:
    return {signed_scaled(rng, single ? -10 : -20, single ? 10 : 20),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_ERF:
  case COMPARE_ERFC:
    return {signed_scaled(rng, single ? -8 : -16, single ? 8 : 16),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP10:
    return {uniform(rng, single ? -38.0 : -300.0, single ? 38.0 : 300.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP10M1:
    return {uniform(rng, single ? -38.0 : -300.0, single ? 38.0 : 300.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXP2:
  case COMPARE_EXP2M1:
    return {uniform(rng, single ? -120.0 : -1000.0, single ? 120.0 : 1000.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_EXPM1:
    return {uniform(rng, single ? -80.0 : -700.0, single ? 80.0 : 700.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_LGAMMA:
  case COMPARE_TGAMMA:
    return {gamma_argument(rng, index, true, format), uniform(rng, -1.0, 1.0)};
  case COMPARE_LOG10:
  case COMPARE_LOG2:
    return {positive_scaled(rng, finite_low, finite_high),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_LOG10P1:
  case COMPARE_LOG1P:
  case COMPARE_LOG2P1:
    return {index & 1U
                ? positive_scaled(rng, single ? -20 : -100, single ? 20 : 100)
                : target_step(-1.0, format, true),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_RSQRT:
    return {positive_scaled(rng, finite_low, finite_high),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_SINH:
    return {uniform(rng, single ? -80.0 : -700.0, single ? 80.0 : 700.0),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_TANH:
    return {signed_scaled(rng, single ? -20 : -100, single ? 20 : 100),
            uniform(rng, -1.0, 1.0)};
  case COMPARE_TANPI:
    return {tanpi_argument(rng, true, format), uniform(rng, -1.0, 1.0)};
  default:
    break;
  }
  throw std::invalid_argument("comparative: unknown wide operation");
}

void put_pair(Inputs &inputs, std::size_t index, GeneratedPair pair,
              CompareFormat format) {
  inputs.x[index] = narrow_if_requested(pair.first, format);
  inputs.y[index] = narrow_if_requested(pair.second, format);
}

enum class ValueClass : std::uint8_t { finite, zero, infinity, nan };

template <typename T> ValueClass classify(T value) {
  if constexpr (std::is_same<T, _Float16>::value) {
    const std::uint16_t bits = static_cast<std::uint16_t>(value_to_bits(value));
    const std::uint16_t exponent = (bits >> 10) & UINT16_C(0x1f);
    const std::uint16_t fraction = bits & UINT16_C(0x03ff);
    if (exponent == UINT16_C(0x1f)) {
      return fraction == 0 ? ValueClass::infinity : ValueClass::nan;
    }
    return (exponent == 0 && fraction == 0) ? ValueClass::zero
                                            : ValueClass::finite;
  } else {
    if (std::isnan(value))
      return ValueClass::nan;
    if (std::isinf(value))
      return ValueClass::infinity;
    if (value == static_cast<T>(0))
      return ValueClass::zero;
    return ValueClass::finite;
  }
}

template <typename T> bool value_signbit(T value) {
  if constexpr (std::is_same<T, _Float16>::value) {
    return (value_to_bits(value) & UINT64_C(0x8000)) != 0;
  } else {
    return std::signbit(value);
  }
}

template <typename T> std::uint64_t ordered_bits(T value) {
  constexpr unsigned width = static_cast<unsigned>(sizeof(T) * 8);
  constexpr std::uint64_t sign_mask = UINT64_C(1) << (width - 1);
  const std::uint64_t bits = value_to_bits(value);
  const std::uint64_t magnitude = bits & (sign_mask - 1);
  // Use one shared coordinate for both signed zeros. Adjacent finite
  // values on either side of zero then differ by exactly one ULP.
  return (bits & sign_mask) != 0 ? sign_mask - magnitude
                                 : sign_mask + magnitude;
}

bool signaling_nan(double value) {
  const std::uint64_t magnitude =
      value_to_bits(value) & UINT64_C(0x7fffffffffffffff);
  return magnitude > UINT64_C(0x7ff0000000000000) &&
         (magnitude & UINT64_C(0x0008000000000000)) == 0;
}

void evaluate_reference(std::uint32_t operation, mpfr_t output,
                        mpfr_srcptr first, mpfr_srcptr second) {
  switch (operation) {
  case COMPARE_EXP:
    (void)mpfr_exp(output, first, MPFR_RNDN);
    return;
  case COMPARE_LOG:
    (void)mpfr_log(output, first, MPFR_RNDN);
    return;
  case COMPARE_SIN:
    (void)mpfr_sin(output, first, MPFR_RNDN);
    return;
  case COMPARE_COS:
    (void)mpfr_cos(output, first, MPFR_RNDN);
    return;
  case COMPARE_TAN:
    (void)mpfr_tan(output, first, MPFR_RNDN);
    return;
  case COMPARE_SQRT:
    (void)mpfr_sqrt(output, first, MPFR_RNDN);
    return;
  case COMPARE_HYPOT:
    (void)mpfr_hypot(output, first, second, MPFR_RNDN);
    return;
  case COMPARE_ATAN2:
    (void)mpfr_atan2(output, first, second, MPFR_RNDN);
    return;
  case COMPARE_POW:
    (void)mpfr_pow(output, first, second, MPFR_RNDN);
    return;
  case COMPARE_ACOS:
    (void)mpfr_acos(output, first, MPFR_RNDN);
    return;
  case COMPARE_ACOSH:
    (void)mpfr_acosh(output, first, MPFR_RNDN);
    return;
  case COMPARE_ACOSPI:
    (void)mpfr_acospi(output, first, MPFR_RNDN);
    return;
  case COMPARE_ASIN:
    (void)mpfr_asin(output, first, MPFR_RNDN);
    return;
  case COMPARE_ASINH:
    (void)mpfr_asinh(output, first, MPFR_RNDN);
    return;
  case COMPARE_ASINPI:
    (void)mpfr_asinpi(output, first, MPFR_RNDN);
    return;
  case COMPARE_ATAN:
    (void)mpfr_atan(output, first, MPFR_RNDN);
    return;
  case COMPARE_ATAN2PI:
    (void)mpfr_atan2pi(output, first, second, MPFR_RNDN);
    return;
  case COMPARE_ATANH:
    (void)mpfr_atanh(output, first, MPFR_RNDN);
    return;
  case COMPARE_ATANPI:
    (void)mpfr_atanpi(output, first, MPFR_RNDN);
    return;
  case COMPARE_CBRT:
    (void)mpfr_cbrt(output, first, MPFR_RNDN);
    return;
  case COMPARE_COSH:
    (void)mpfr_cosh(output, first, MPFR_RNDN);
    return;
  case COMPARE_COSPI:
    (void)mpfr_cospi(output, first, MPFR_RNDN);
    return;
  case COMPARE_ERF:
    (void)mpfr_erf(output, first, MPFR_RNDN);
    return;
  case COMPARE_ERFC:
    (void)mpfr_erfc(output, first, MPFR_RNDN);
    return;
  case COMPARE_EXP10:
    (void)mpfr_exp10(output, first, MPFR_RNDN);
    return;
  case COMPARE_EXP10M1:
    (void)mpfr_exp10m1(output, first, MPFR_RNDN);
    return;
  case COMPARE_EXP2:
    (void)mpfr_exp2(output, first, MPFR_RNDN);
    return;
  case COMPARE_EXP2M1:
    (void)mpfr_exp2m1(output, first, MPFR_RNDN);
    return;
  case COMPARE_EXPM1:
    (void)mpfr_expm1(output, first, MPFR_RNDN);
    return;
  case COMPARE_LGAMMA: {
    int sign = 0;
    (void)mpfr_lgamma(output, &sign, first, MPFR_RNDN);
    return;
  }
  case COMPARE_LOG10:
    (void)mpfr_log10(output, first, MPFR_RNDN);
    return;
  case COMPARE_LOG10P1:
    (void)mpfr_log10p1(output, first, MPFR_RNDN);
    return;
  case COMPARE_LOG1P:
    (void)mpfr_log1p(output, first, MPFR_RNDN);
    return;
  case COMPARE_LOG2:
    (void)mpfr_log2(output, first, MPFR_RNDN);
    return;
  case COMPARE_LOG2P1:
    (void)mpfr_log2p1(output, first, MPFR_RNDN);
    return;
  case COMPARE_RSQRT:
    if (mpfr_zero_p(first)) {
      mpfr_set_inf(output, mpfr_signbit(first) ? -1 : 1);
    } else {
      (void)mpfr_rec_sqrt(output, first, MPFR_RNDN);
    }
    return;
  case COMPARE_SINH:
    (void)mpfr_sinh(output, first, MPFR_RNDN);
    return;
  case COMPARE_SINPI:
    (void)mpfr_sinpi(output, first, MPFR_RNDN);
    return;
  case COMPARE_TANH:
    (void)mpfr_tanh(output, first, MPFR_RNDN);
    return;
  case COMPARE_TANPI:
    (void)mpfr_tanpi(output, first, MPFR_RNDN);
    return;
  case COMPARE_TGAMMA:
    (void)mpfr_gamma(output, first, MPFR_RNDN);
    return;
  default:
    throw std::invalid_argument("comparative: unknown reference operation");
  }
}

_Float16 mpfr_get_f16(mpfr_srcptr value) {
  const mpfr_exp_t old_emin = mpfr_get_emin();
  const mpfr_exp_t old_emax = mpfr_get_emax();
  mpfr_t rounded;
  mpfr_init2(rounded, 11);
  (void)mpfr_set_emin(-23);
  (void)mpfr_set_emax(16);
  int ternary = mpfr_set(rounded, value, MPFR_RNDN);
  ternary = mpfr_check_range(rounded, ternary, MPFR_RNDN);
  (void)mpfr_subnormalize(rounded, ternary, MPFR_RNDN);
  const double result = mpfr_get_d(rounded, MPFR_RNDN);
  mpfr_clear(rounded);
  (void)mpfr_set_emax(old_emax);
  (void)mpfr_set_emin(old_emin);
  return static_cast<_Float16>(result);
}

template <typename T> T mpfr_to_target(mpfr_srcptr value);

template <> float mpfr_to_target<float>(mpfr_srcptr value) {
  return mpfr_get_flt(value, MPFR_RNDN);
}

template <> double mpfr_to_target<double>(mpfr_srcptr value) {
  return mpfr_get_d(value, MPFR_RNDN);
}

template <> _Float16 mpfr_to_target<_Float16>(mpfr_srcptr value) {
  return mpfr_get_f16(value);
}

template <typename T, typename Function>
Audit audit_impl(std::uint32_t operation, const Inputs &inputs,
                 Function function) {
  reject_bad_operation(operation);
  if (function == nullptr) {
    throw std::invalid_argument("comparative: null comparison function");
  }

  Audit result;
  result.samples = sample_count;
  const bool binary = operation == COMPARE_HYPOT || operation == COMPARE_ATAN2 ||
                      operation == COMPARE_POW || operation == COMPARE_ATAN2PI;

  mpfr_t first;
  mpfr_t second;
  mpfr_t reference;
  mpfr_init2(first, mpfr_precision_bits);
  mpfr_init2(second, mpfr_precision_bits);
  mpfr_init2(reference, mpfr_precision_bits);

  for (std::size_t index = 0; index < sample_count; ++index) {
    const T first_value = [&]() -> T {
      if constexpr (std::is_same<T, float>::value) {
        return input_f32(inputs.x[index]);
      } else if constexpr (std::is_same<T, _Float16>::value) {
        return input_f16(inputs.x[index]);
      } else {
        return inputs.x[index];
      }
    }();
    const T second_value = [&]() -> T {
      if constexpr (std::is_same<T, float>::value) {
        return input_f32(inputs.y[index]);
      } else if constexpr (std::is_same<T, _Float16>::value) {
        return input_f16(inputs.y[index]);
      } else {
        return inputs.y[index];
      }
    }();
    const double first_double = static_cast<double>(first_value);
    const double second_double = static_cast<double>(second_value);
    (void)mpfr_set_d(first, first_double, MPFR_RNDN);
    (void)mpfr_set_d(second, second_double, MPFR_RNDN);
    // MPFR has one NaN class. Preserve signaling precedence before pow
    // identities or hypot's infinity rule can hide that information.
    if (signaling_nan(inputs.x[index]) ||
        (binary && signaling_nan(inputs.y[index]))) {
      mpfr_set_nan(reference);
    } else {
      evaluate_reference(operation, reference, first, second);
    }

    const T expected = mpfr_to_target<T>(reference);
    const T actual = function(first_value, second_value);
    const ValueClass expected_class = classify(expected);
    const ValueClass actual_class = classify(actual);

    if (expected_class == ValueClass::finite ||
        expected_class == ValueClass::zero) {
      if (actual_class == ValueClass::finite ||
          actual_class == ValueClass::zero) {
        ++result.finite_compared;
        if (expected_class == ValueClass::zero &&
            actual_class == ValueClass::zero) {
          if (value_signbit(expected) != value_signbit(actual)) {
            ++result.signed_zero_mismatches;
          }
          continue;
        }
        const std::uint64_t expected_order = ordered_bits(expected);
        const std::uint64_t actual_order = ordered_bits(actual);
        const std::uint64_t distance = expected_order > actual_order
                                           ? expected_order - actual_order
                                           : actual_order - expected_order;
        if (distance > result.max_ulp)
          result.max_ulp = distance;
      } else {
        ++result.nonfinite_mismatches;
      }
      continue;
    }

    if (actual_class != expected_class) {
      ++result.nonfinite_mismatches;
    } else if (expected_class == ValueClass::infinity &&
               value_signbit(expected) != value_signbit(actual)) {
      ++result.nonfinite_mismatches;
    }
    // NaN payloads and NaN signs are intentionally ignored.
  }

  mpfr_clear(reference);
  mpfr_clear(second);
  mpfr_clear(first);
  return result;
}

void set_error(std::string *error, const char *message) {
  if (error == nullptr)
    return;
  if (message == nullptr) {
    error->clear();
  } else {
    *error = message;
  }
}

float self_check_exp_one_f32(float first, float second) {
  (void)first;
  (void)second;
  return bits_to_value<float>(UINT32_C(0x3f800000));
}

float self_check_exp_next_f32(float first, float second) {
  (void)first;
  (void)second;
  return bits_to_value<float>(UINT32_C(0x3f800001));
}

float self_check_exp_inf_f32(float first, float second) {
  (void)first;
  (void)second;
  return bits_to_value<float>(UINT32_C(0x7f800000));
}

float self_check_sqrt_negative_zero_f32(float first, float second) {
  (void)first;
  (void)second;
  return bits_to_value<float>(UINT32_C(0x80000000));
}

float self_check_positive_zero_f32(float first, float second) {
  (void)first;
  (void)second;
  return bits_to_value<float>(UINT32_C(0x00000000));
}

double self_check_exp_one_f64(double first, double second) {
  (void)first;
  (void)second;
  return bits_to_value<double>(UINT64_C(0x3ff0000000000000));
}

double self_check_exp_next_f64(double first, double second) {
  (void)first;
  (void)second;
  return bits_to_value<double>(UINT64_C(0x3ff0000000000001));
}

double self_check_exp_inf_f64(double first, double second) {
  (void)first;
  (void)second;
  return bits_to_value<double>(UINT64_C(0x7ff0000000000000));
}

double self_check_sqrt_negative_zero_f64(double first, double second) {
  (void)first;
  (void)second;
  return bits_to_value<double>(UINT64_C(0x8000000000000000));
}

double self_check_positive_zero_f64(double first, double second) {
  (void)first;
  (void)second;
  return bits_to_value<double>(UINT64_C(0x0000000000000000));
}

_Float16 self_check_inf_f16(_Float16 first, _Float16 second) {
  (void)first;
  (void)second;
  return bits_to_value<_Float16>(UINT16_C(0x7c00));
}

_Float16 self_check_negative_inf_f16(_Float16 first, _Float16 second) {
  (void)first;
  (void)second;
  return bits_to_value<_Float16>(UINT16_C(0xfc00));
}

_Float16 self_check_positive_zero_f16(_Float16 first, _Float16 second) {
  (void)first;
  (void)second;
  return bits_to_value<_Float16>(UINT16_C(0x0000));
}

template <typename T> bool self_check_ieee_reference(std::string *error) {
  const auto nan = +[](T, T) -> T {
    return static_cast<T>(std::numeric_limits<double>::quiet_NaN());
  };
  const auto inf = +[](T, T) -> T {
    return static_cast<T>(std::numeric_limits<double>::infinity());
  };
  const auto negative_inf = +[](T, T) -> T {
    return static_cast<T>(-std::numeric_limits<double>::infinity());
  };
  const auto one = +[](T, T) -> T { return static_cast<T>(1.0); };
  const auto check = [&](std::uint32_t operation, double first, double second,
                         T (*function)(T, T), const char *message) {
    Inputs inputs{};
    inputs.x.fill(first);
    inputs.y.fill(second);
    const Audit result = audit(operation, inputs, function);
    if (result.max_ulp || result.nonfinite_mismatches ||
        result.signed_zero_mismatches) {
      set_error(error, message);
      return false;
    }
    return true;
  };
  const double signaling =
      bits_to_value<double>(UINT64_C(0x7ff4000000000001));
  const double quiet = std::numeric_limits<double>::quiet_NaN();
  const double infinity = std::numeric_limits<double>::infinity();
  return check(COMPARE_HYPOT, signaling, infinity, nan,
               "hypot: signaling NaN must precede infinity") &&
         check(COMPARE_HYPOT, -infinity, signaling, nan,
               "hypot: signaling second operand must precede infinity") &&
         check(COMPARE_HYPOT, quiet, infinity, inf,
               "hypot: infinity must precede quiet NaN") &&
         check(COMPARE_HYPOT, -infinity, quiet, inf,
               "hypot: quiet second operand must not hide infinity") &&
         check(COMPARE_POW, signaling, 0.0, nan,
               "pow: signaling base must precede zero exponent") &&
         check(COMPARE_POW, 1.0, signaling, nan,
               "pow: signaling exponent must precede unit base") &&
         check(COMPARE_POW, quiet, 0.0, one,
               "pow: quiet base must preserve zero-exponent identity") &&
         check(COMPARE_POW, 1.0, quiet, one,
               "pow: quiet exponent must preserve unit-base identity") &&
         check(COMPARE_RSQRT, -0.0, 0.0, negative_inf,
               "rsqrt: negative zero must yield negative infinity") &&
         check(COMPARE_RSQRT, 0.0, 0.0, inf,
               "rsqrt: positive zero must yield positive infinity") &&
         check(COMPARE_SQRT, 1.0, signaling, one,
               "unary oracle must ignore its unused second argument");
}

double self_check_lgamma_f64(double first, double second) {
  (void)second;
  return std::lgamma(first);
}

float self_check_lgamma_f32(float first, float second) {
  (void)second;
  return static_cast<float>(std::lgamma(static_cast<double>(first)));
}

_Float16 self_check_lgamma_f16(_Float16 first, _Float16 second) {
  (void)second;
  return static_cast<_Float16>(std::lgamma(static_cast<double>(first)));
}
} // namespace

float input_f32(double value) {
  const std::uint64_t bits = value_to_bits(value);
  const std::uint64_t exponent = (bits >> 52) & UINT64_C(0x7ff);
  const std::uint64_t fraction = bits & UINT64_C(0x000fffffffffffff);
  if (exponent == UINT64_C(0x7ff) && fraction != 0) {
    std::uint32_t payload = static_cast<std::uint32_t>(fraction >> 29);
    // A double NaN may have only low payload bits. Keep it a NaN after
    // narrowing, while preserving the source quiet/signaling class.
    if (payload == 0)
      payload = UINT32_C(1);
    if ((fraction & UINT64_C(0x0008000000000000)) != 0) {
      payload |= UINT32_C(0x00400000);
    } else {
      payload &= ~UINT32_C(0x00400000);
    }
    const std::uint32_t sign = (bits & UINT64_C(0x8000000000000000)) != 0
                                   ? UINT32_C(0x80000000)
                                   : UINT32_C(0);
    const std::uint32_t output_bits = sign | UINT32_C(0x7f800000) | payload;
    return bits_to_value<float>(output_bits);
  }
  return static_cast<float>(value);
}

_Float16 input_f16(double value) { return narrow_half(value); }

Inputs make_inputs(std::uint32_t operation, Distribution distribution,
                   CompareFormat format) {
  reject_bad_operation(operation);
  reject_bad_format(format);
  if (distribution != Distribution::normal &&
      distribution != Distribution::wide &&
      distribution != Distribution::special) {
    throw std::invalid_argument("comparative: unknown input distribution");
  }

  Inputs inputs;
  const std::uint64_t distribution_tag =
      static_cast<std::uint64_t>(distribution);
  const std::uint64_t state =
      input_seed ^
      (UINT64_C(0x9e3779b97f4a7c15) *
       (static_cast<std::uint64_t>(operation) + 1)) ^
      (UINT64_C(0xbf58476d1ce4e5b9) * (distribution_tag + 1)) ^
      (format == COMPARE_F32   ? UINT64_C(0xd)
       : format == COMPARE_F16 ? UINT64_C(0x16)
                               : UINT64_C(0x0));
  Rng rng(state);

  if (distribution == Distribution::special) {
    for (std::size_t index = 0; index < sample_count; ++index) {
      // The first four cycles cover every ordered 16-by-16 tuple. This
      // keeps all unary specials visible while exercising binary
      // precedence combinations (x and y are not paired identically).
      const std::size_t tuple =
          index % (special_value_count * special_value_count);
      const std::size_t first_index = tuple / special_value_count;
      const std::size_t second_index = tuple % special_value_count;
      inputs.x[index] = special_value(first_index, format);
      inputs.y[index] = special_value(second_index, format);
    }
    return inputs;
  }

  for (std::size_t index = 0; index < sample_count; ++index) {
    const GeneratedPair pair =
        distribution == Distribution::normal
            ? generate_normal(operation, rng, format, index)
            : generate_wide(operation, rng, format, index);
    put_pair(inputs, index, pair, format);
  }
  return inputs;
}

std::string input_hash(const Inputs &inputs, CompareFormat format) {
  reject_bad_format(format);
  std::uint64_t hash = UINT64_C(1469598103934665603);
  const auto absorb = [&hash](std::uint8_t byte) {
    hash ^= static_cast<std::uint64_t>(byte);
    hash *= UINT64_C(1099511628211);
  };
  absorb(static_cast<std::uint8_t>(format));
  const auto absorb_value = [&absorb, format](double value) {
    const std::uint64_t bits = target_bits(value, format);
    const unsigned width = format == COMPARE_F16   ? 2U
                           : format == COMPARE_F32 ? 4U
                                                   : 8U;
    for (unsigned byte = 0; byte < width; ++byte)
      absorb(static_cast<std::uint8_t>(bits >> (byte * 8)));
  };
  for (double value : inputs.x)
    absorb_value(value);
  for (double value : inputs.y)
    absorb_value(value);

  static constexpr char hex[] = "0123456789abcdef";
  std::string digest(16, '0');
  for (unsigned nibble = 0; nibble < 16; ++nibble) {
    const unsigned shift = (15U - nibble) * 4U;
    digest[nibble] = hex[(hash >> shift) & UINT64_C(0xf)];
  }
  return digest;
}

Audit audit(std::uint32_t operation, const Inputs &inputs,
            CompareF16 function) {
  return audit_impl<_Float16>(operation, inputs, function);
}

Audit audit(std::uint32_t operation, const Inputs &inputs,
            CompareF32 function) {
  return audit_impl<float>(operation, inputs, function);
}

Audit audit(std::uint32_t operation, const Inputs &inputs,
            CompareF64 function) {
  return audit_impl<double>(operation, inputs, function);
}

bool self_check(std::string *error) {
  try {
    const CompareFormat formats[] = {COMPARE_F32, COMPARE_F64, COMPARE_F16};
    const auto check_domains = [&](std::uint32_t operation,
                                   Distribution distribution,
                                   CompareFormat format, const Inputs &inputs) {
      if (distribution == Distribution::special)
        return true;
      bool gamma_positive = false;
      bool gamma_negative = false;
      bool gamma_noninteger = false;
      for (std::size_t index = 0; index < sample_count; ++index) {
        const double first = inputs.x[index];
        const double second = inputs.y[index];
        if (!std::isfinite(first) || !std::isfinite(second)) {
          set_error(error, "comparative: generated finite distribution is "
                           "non-finite");
          return false;
        }
        switch (operation) {
        case COMPARE_LOG:
        case COMPARE_LOG10:
        case COMPARE_LOG2:
          if (!(first > 0.0)) {
            set_error(error, "comparative: logarithm domain is invalid");
            return false;
          }
          break;
        case COMPARE_SQRT:
          if (first < 0.0) {
            set_error(error, "comparative: square-root domain is invalid");
            return false;
          }
          break;
        case COMPARE_RSQRT:
          if (!(first > 0.0)) {
            set_error(error, "comparative: reciprocal square-root domain is "
                             "invalid");
            return false;
          }
          break;
        case COMPARE_ACOS:
        case COMPARE_ASIN:
        case COMPARE_ACOSPI:
        case COMPARE_ASINPI:
          if (first < -1.0 || first > 1.0) {
            set_error(error,
                      "comparative: inverse unit-domain input is invalid");
            return false;
          }
          break;
        case COMPARE_ACOSH:
          if (first < 1.0) {
            set_error(error, "comparative: acosh domain is invalid");
            return false;
          }
          break;
        case COMPARE_ATANH:
          if (!(first > -1.0 && first < 1.0)) {
            set_error(error, "comparative: atanh domain is invalid");
            return false;
          }
          break;
        case COMPARE_LOG10P1:
        case COMPARE_LOG1P:
        case COMPARE_LOG2P1:
          if (!(first > -1.0)) {
            set_error(error,
                      "comparative: logarithm-plus-one domain is invalid");
            return false;
          }
          break;
        case COMPARE_LGAMMA:
        case COMPARE_TGAMMA:
          if (first > 0.0)
            gamma_positive = true;
          if (first < 0.0) {
            gamma_negative = true;
            gamma_noninteger |= std::trunc(first) != first;
          }
          break;
        default:
          break;
        }
      }
      if (operation == COMPARE_LGAMMA || operation == COMPARE_TGAMMA) {
        if (!gamma_positive || !gamma_negative || !gamma_noninteger) {
          set_error(error, "comparative: gamma workload lacks signed "
                           "noninteger inputs");
          return false;
        }
      }

      const auto same_target = [&](double left, double right) {
        return target_bits(left, format) == target_bits(right, format);
      };
      if (distribution == Distribution::normal) {
        switch (operation) {
        case COMPARE_ACOS:
        case COMPARE_ASIN:
        case COMPARE_ACOSPI:
        case COMPARE_ASINPI:
          if (!same_target(inputs.x[0], -1.0) ||
              !same_target(inputs.x[1], 1.0) ||
              !same_target(inputs.x[2], target_step(-1.0, format, true)) ||
              !same_target(inputs.x[3], target_step(1.0, format, false))) {
            set_error(error, "comparative: inverse boundary neighbors missing");
            return false;
          }
          break;
        case COMPARE_ACOSH:
          if (!same_target(inputs.x[0], 1.0) ||
              !same_target(inputs.x[1], target_step(1.0, format, true))) {
            set_error(error, "comparative: acosh boundary missing");
            return false;
          }
          break;
        case COMPARE_ATANH:
          if (!same_target(inputs.x[0], target_step(-1.0, format, true)) ||
              !same_target(inputs.x[1], target_step(1.0, format, false))) {
            set_error(error, "comparative: atanh boundary missing");
            return false;
          }
          break;
        case COMPARE_LOG10P1:
        case COMPARE_LOG1P:
        case COMPARE_LOG2P1:
          if (!same_target(inputs.x[0], target_step(-1.0, format, true)) ||
              !same_target(inputs.x[1], -0.5)) {
            set_error(error,
                      "comparative: logarithm-plus-one boundary missing");
            return false;
          }
          break;
        default:
          break;
        }
      }
      return true;
    };

    for (std::uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
         ++operation) {
      for (Distribution distribution :
           {Distribution::normal, Distribution::wide, Distribution::special}) {
        for (CompareFormat format : formats) {
          const Inputs first = make_inputs(operation, distribution, format);
          const Inputs second = make_inputs(operation, distribution, format);
          if (input_hash(first, format) != input_hash(second, format)) {
            set_error(error, "comparative: non-deterministic input digest");
            return false;
          }
          if (!check_domains(operation, distribution, format, first))
            return false;
          if (distribution != Distribution::special && format != COMPARE_F64) {
            for (std::size_t index = 0; index < sample_count; ++index) {
              const double first_value =
                  format == COMPARE_F32
                      ? static_cast<double>(input_f32(first.x[index]))
                      : static_cast<double>(input_f16(first.x[index]));
              const double second_value =
                  format == COMPARE_F32
                      ? static_cast<double>(input_f32(first.y[index]))
                      : static_cast<double>(input_f16(first.y[index]));
              if (first_value != first.x[index] ||
                  second_value != first.y[index]) {
                set_error(error,
                          "comparative: narrowed dataset is not exact target "
                          "format");
                return false;
              }
            }
          }
          if (distribution == Distribution::special) {
            for (std::size_t first_index = 0; first_index < special_value_count;
                 ++first_index) {
              for (std::size_t second_index = 0;
                   second_index < special_value_count; ++second_index) {
                const std::size_t tuple =
                    first_index * special_value_count + second_index;
                if (target_bits(first.x[tuple], format) !=
                        target_bits(special_value(first_index, format),
                                    format) ||
                    target_bits(first.y[tuple], format) !=
                        target_bits(special_value(second_index, format),
                                    format)) {
                  set_error(error,
                            "comparative: missing required special tuple");
                  return false;
                }
              }
            }
          }
        }
      }
    }

    bool rejected_operation = false;
    try {
      (void)make_inputs(COMPARE_OPERATION_COUNT, Distribution::normal,
                        COMPARE_F64);
    } catch (const std::invalid_argument &) {
      rejected_operation = true;
    }
    if (!rejected_operation) {
      set_error(error, "comparative: invalid operation was accepted");
      return false;
    }
    bool rejected_format = false;
    try {
      (void)make_inputs(COMPARE_EXP, Distribution::normal,
                        static_cast<CompareFormat>(99));
    } catch (const std::invalid_argument &) {
      rejected_format = true;
    }
    if (!rejected_format) {
      set_error(error, "comparative: invalid format was accepted");
      return false;
    }

    // Exercise exact half conversion on both sides of tie points. The tiny
    // perturbations disappear when converted through binary64, so a
    // double-rounding implementation cannot pass these checks.
    mpfr_t midpoint;
    mpfr_t delta;
    mpfr_t below;
    mpfr_t above;
    mpfr_init2(midpoint, mpfr_precision_bits);
    mpfr_init2(delta, mpfr_precision_bits);
    mpfr_init2(below, mpfr_precision_bits);
    mpfr_init2(above, mpfr_precision_bits);
    const auto check_half = [&](mpfr_srcptr value, std::uint16_t expected,
                                const char *message) {
      if (static_cast<std::uint16_t>(value_to_bits(mpfr_get_f16(value))) !=
          expected) {
        set_error(error, message);
        return false;
      }
      return true;
    };
    (void)mpfr_set_ui(midpoint, 1, MPFR_RNDN);
    (void)mpfr_mul_2si(midpoint, midpoint, -25, MPFR_RNDN);
    (void)mpfr_set_ui(delta, 1, MPFR_RNDN);
    (void)mpfr_mul_2si(delta, delta, -80, MPFR_RNDN);
    (void)mpfr_sub(below, midpoint, delta, MPFR_RNDN);
    (void)mpfr_add(above, midpoint, delta, MPFR_RNDN);
    if (!check_half(below, UINT16_C(0x0000),
                    "comparative: half subnormal tie rounded below") ||
        !check_half(above, UINT16_C(0x0001),
                    "comparative: half subnormal tie rounded above")) {
      mpfr_clear(above);
      mpfr_clear(below);
      mpfr_clear(delta);
      mpfr_clear(midpoint);
      return false;
    }
    (void)mpfr_set_ui(midpoint, 1, MPFR_RNDN);
    (void)mpfr_set_ui(delta, 1, MPFR_RNDN);
    (void)mpfr_mul_2si(delta, delta, -11, MPFR_RNDN);
    (void)mpfr_add(midpoint, midpoint, delta, MPFR_RNDN);
    (void)mpfr_set_ui(delta, 1, MPFR_RNDN);
    (void)mpfr_mul_2si(delta, delta, -60, MPFR_RNDN);
    (void)mpfr_sub(below, midpoint, delta, MPFR_RNDN);
    (void)mpfr_add(above, midpoint, delta, MPFR_RNDN);
    if (!check_half(below, UINT16_C(0x3c00),
                    "comparative: half normal tie rounded below") ||
        !check_half(above, UINT16_C(0x3c01),
                    "comparative: half normal tie rounded above")) {
      mpfr_clear(above);
      mpfr_clear(below);
      mpfr_clear(delta);
      mpfr_clear(midpoint);
      return false;
    }
    (void)mpfr_set_ui(midpoint, 65520, MPFR_RNDN);
    (void)mpfr_set_ui(delta, 1, MPFR_RNDN);
    (void)mpfr_mul_2si(delta, delta, -40, MPFR_RNDN);
    (void)mpfr_sub(below, midpoint, delta, MPFR_RNDN);
    (void)mpfr_add(above, midpoint, delta, MPFR_RNDN);
    if (!check_half(below, UINT16_C(0x7bff),
                    "comparative: half overflow tie rounded below") ||
        !check_half(above, UINT16_C(0x7c00),
                    "comparative: half overflow tie rounded above")) {
      mpfr_clear(above);
      mpfr_clear(below);
      mpfr_clear(delta);
      mpfr_clear(midpoint);
      return false;
    }
    mpfr_clear(above);
    mpfr_clear(below);
    mpfr_clear(delta);
    mpfr_clear(midpoint);

    const Inputs atan2pi_inputs =
        make_inputs(COMPARE_ATAN2PI, Distribution::normal, COMPARE_F64);
    const Audit atan2pi_classes =
        audit(COMPARE_ATAN2PI, atan2pi_inputs, self_check_exp_inf_f64);
    if (atan2pi_classes.samples != sample_count ||
        atan2pi_classes.finite_compared != 0 ||
        atan2pi_classes.nonfinite_mismatches != sample_count) {
      set_error(error, "comparative: atan2pi oracle class check failed");
      return false;
    }
    const Audit half_classes =
        audit(COMPARE_ACOS,
              make_inputs(COMPARE_ACOS, Distribution::normal, COMPARE_F16),
              self_check_inf_f16);
    if (half_classes.samples != sample_count ||
        half_classes.finite_compared != 0 ||
        half_classes.nonfinite_mismatches != sample_count) {
      set_error(error, "comparative: half oracle class check failed");
      return false;
    }
    Inputs infinity_inputs{};
    infinity_inputs.x.fill(std::numeric_limits<double>::infinity());
    const Audit half_infinity_sign =
        audit(COMPARE_EXP, infinity_inputs, self_check_negative_inf_f16);
    if (half_infinity_sign.nonfinite_mismatches != sample_count) {
      set_error(error,
                "comparative: half infinity-sign mismatch is not reported");
      return false;
    }

    Inputs lgamma_positive{};
    Inputs lgamma_negative{};
    for (std::size_t index = 0; index < sample_count; ++index) {
      lgamma_positive.x[index] = 0.5;
      lgamma_negative.x[index] = -0.5;
    }
    const auto check_lgamma = [&](const Audit &value, const char *message) {
      if (value.samples != sample_count ||
          value.finite_compared != sample_count ||
          value.nonfinite_mismatches != 0) {
        set_error(error, message);
        return false;
      }
      return true;
    };
    if (!check_lgamma(
            audit(COMPARE_LGAMMA, lgamma_positive, self_check_lgamma_f64),
            "comparative: positive lgamma oracle check failed") ||
        !check_lgamma(
            audit(COMPARE_LGAMMA, lgamma_negative, self_check_lgamma_f64),
            "comparative: negative lgamma oracle check failed") ||
        !check_lgamma(
            audit(COMPARE_LGAMMA, lgamma_positive, self_check_lgamma_f32),
            "comparative: f32 lgamma oracle check failed") ||
        !check_lgamma(
            audit(COMPARE_LGAMMA, lgamma_positive, self_check_lgamma_f16),
            "comparative: f16 lgamma oracle check failed")) {
      return false;
    }

    const auto check_audit = [&](const Audit &value, std::uint64_t finite,
                                 std::uint64_t max_ulp, std::uint64_t nonfinite,
                                 std::uint64_t signed_zero,
                                 const char *message) {
      if (value.samples != sample_count || value.finite_compared != finite ||
          value.max_ulp != max_ulp || value.nonfinite_mismatches != nonfinite ||
          value.signed_zero_mismatches != signed_zero) {
        set_error(error, message);
        return false;
      }
      return true;
    };
    const Inputs zeros{};

    // Deliberate f32 faults prove the reporter detects one-ULP,
    // non-finite-class, and signed-zero errors rather than only checking
    // that input generation is repeatable.
    if (!check_audit(audit(COMPARE_EXP, zeros, self_check_exp_one_f32),
                     sample_count, 0, 0, 0,
                     "comparative: f32 clean audit is not clean") ||
        !check_audit(audit(COMPARE_EXP, zeros, self_check_exp_next_f32),
                     sample_count, 1, 0, 0,
                     "comparative: f32 ULP mismatch is not reported") ||
        !check_audit(audit(COMPARE_EXP, zeros, self_check_exp_inf_f32), 0, 0,
                     sample_count, 0,
                     "comparative: f32 non-finite mismatch is not reported") ||
        !check_audit(
            audit(COMPARE_SQRT, zeros, self_check_sqrt_negative_zero_f32),
            sample_count, 0, 0, sample_count,
            "comparative: f32 signed-zero mismatch is not reported")) {
      return false;
    }

    // Repeat the same observable checks through the binary64 overload.
    if (!check_audit(audit(COMPARE_EXP, zeros, self_check_exp_one_f64),
                     sample_count, 0, 0, 0,
                     "comparative: f64 clean audit is not clean") ||
        !check_audit(audit(COMPARE_EXP, zeros, self_check_exp_next_f64),
                     sample_count, 1, 0, 0,
                     "comparative: f64 ULP mismatch is not reported") ||
        !check_audit(audit(COMPARE_EXP, zeros, self_check_exp_inf_f64), 0, 0,
                     sample_count, 0,
                     "comparative: f64 non-finite mismatch is not reported") ||
        !check_audit(
            audit(COMPARE_SQRT, zeros, self_check_sqrt_negative_zero_f64),
            sample_count, 0, 0, sample_count,
            "comparative: f64 signed-zero mismatch is not reported")) {
      return false;
    }

    Inputs boundary_inputs{};
    for (std::size_t index = 0; index < sample_count; ++index) {
      const double value =
          -static_cast<double>(std::numeric_limits<float>::denorm_min());
      boundary_inputs.x[index] = value;
      boundary_inputs.y[index] = value;
    }
    // sin(-denorm_min) rounds to -denorm_min. A provider that returns +0
    // must therefore be exactly one ULP away across zero.
    if (!check_audit(
            audit(COMPARE_SIN, boundary_inputs, self_check_positive_zero_f32),
            sample_count, 1, 0, 0,
            "comparative: f32 cross-zero ULP distance is not one")) {
      return false;
    }

    for (std::size_t index = 0; index < sample_count; ++index) {
      const double value = -std::numeric_limits<double>::denorm_min();
      boundary_inputs.x[index] = value;
      boundary_inputs.y[index] = value;
    }
    if (!check_audit(
            audit(COMPARE_SIN, boundary_inputs, self_check_positive_zero_f64),
            sample_count, 1, 0, 0,
            "comparative: f64 cross-zero ULP distance is not one")) {
      return false;
    }

    for (std::size_t index = 0; index < sample_count; ++index) {
      boundary_inputs.x[index] = f16_bits_to_double(UINT16_C(0x8001));
      boundary_inputs.y[index] = boundary_inputs.x[index];
    }
    if (!check_audit(
            audit(COMPARE_SIN, boundary_inputs, self_check_positive_zero_f16),
            sample_count, 1, 0, 0,
            "comparative: f16 cross-zero ULP distance is not one")) {
      return false;
    }

    for (std::size_t index = 0; index < sample_count; ++index) {
      boundary_inputs.x[index] =
          bits_to_value<double>(UINT64_C(0x8000000000000000));
      boundary_inputs.y[index] = boundary_inputs.x[index];
    }
    // The shared zero coordinate must not hide a provider's zero-sign
    // mismatch in any format.
    if (!check_audit(
            audit(COMPARE_SIN, boundary_inputs, self_check_positive_zero_f32),
            sample_count, 0, 0, sample_count,
            "comparative: f32 negative-zero mismatch is not reported") ||
        !check_audit(
            audit(COMPARE_SIN, boundary_inputs, self_check_positive_zero_f64),
            sample_count, 0, 0, sample_count,
            "comparative: f64 negative-zero mismatch is not reported")) {
      return false;
    }
    for (std::size_t index = 0; index < sample_count; ++index) {
      boundary_inputs.x[index] = f16_bits_to_double(UINT16_C(0x8000));
      boundary_inputs.y[index] = boundary_inputs.x[index];
    }
    if (!check_audit(
            audit(COMPARE_SIN, boundary_inputs, self_check_positive_zero_f16),
            sample_count, 0, 0, sample_count,
            "comparative: f16 negative-zero mismatch is not reported")) {
      return false;
    }

    if (!self_check_ieee_reference<_Float16>(error) ||
        !self_check_ieee_reference<float>(error) ||
        !self_check_ieee_reference<double>(error)) {
      return false;
    }

    set_error(error, nullptr);
    return true;
  } catch (const std::exception &exception) {
    if (error != nullptr)
      *error = exception.what();
    return false;
  }
}

} // namespace comparative
