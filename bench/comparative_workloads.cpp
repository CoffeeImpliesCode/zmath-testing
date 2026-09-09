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

double special_value(std::size_t index, bool single) {
  index %= special_value_count;
  if (single)
    return f32_bits_to_double(special_f32_bits[index]);
  return bits_to_value<double>(special_f64_bits[index]);
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

double narrow_if_requested(double value, bool single) {
  if (!single)
    return value;
  const float narrowed = static_cast<float>(value);
  return static_cast<double>(narrowed);
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

GeneratedPair generate_normal(std::uint32_t operation, Rng &rng, bool single) {
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
  default:
    break;
  }
  (void)single;
  throw std::invalid_argument("comparative: unknown normal operation");
}

GeneratedPair generate_wide(std::uint32_t operation, Rng &rng, bool single) {
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
  default:
    break;
  }
  throw std::invalid_argument("comparative: unknown wide operation");
}

void put_pair(Inputs &inputs, std::size_t index, GeneratedPair pair,
              bool single) {
  inputs.x[index] = narrow_if_requested(pair.first, single);
  inputs.y[index] = narrow_if_requested(pair.second, single);
}

enum class ValueClass : std::uint8_t { finite, zero, infinity, nan };

template <typename T> ValueClass classify(T value) {
  if (std::isnan(value))
    return ValueClass::nan;
  if (std::isinf(value))
    return ValueClass::infinity;
  if (value == static_cast<T>(0))
    return ValueClass::zero;
  return ValueClass::finite;
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
  default:
    throw std::invalid_argument("comparative: unknown reference operation");
  }
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
      } else {
        return inputs.x[index];
      }
    }();
    const T second_value = [&]() -> T {
      if constexpr (std::is_same<T, float>::value) {
        return input_f32(inputs.y[index]);
      } else {
        return inputs.y[index];
      }
    }();
    const double first_double = static_cast<double>(first_value);
    const double second_double = static_cast<double>(second_value);
    (void)mpfr_set_d(first, first_double, MPFR_RNDN);
    (void)mpfr_set_d(second, second_double, MPFR_RNDN);
    evaluate_reference(operation, reference, first, second);

    const T expected = [&]() -> T {
      if constexpr (std::is_same<T, float>::value) {
        return mpfr_get_flt(reference, MPFR_RNDN);
      } else {
        return mpfr_get_d(reference, MPFR_RNDN);
      }
    }();
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
          if (std::signbit(expected) != std::signbit(actual)) {
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
               std::signbit(expected) != std::signbit(actual)) {
      ++result.nonfinite_mismatches;
    }
    // NaN payloads and NaN signs are intentionally ignored.
  }

  mpfr_clear(reference);
  mpfr_clear(second);
  mpfr_clear(first);
  return result;
}

bool values_have_same_bits(double left, double right) {
  return value_to_bits(left) == value_to_bits(right);
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

Inputs make_inputs(std::uint32_t operation, Distribution distribution,
                   bool single) {
  reject_bad_operation(operation);
  if (distribution != Distribution::normal &&
      distribution != Distribution::wide &&
      distribution != Distribution::special) {
    throw std::invalid_argument("comparative: unknown input distribution");
  }

  Inputs inputs;
  const std::uint64_t distribution_tag =
      static_cast<std::uint64_t>(distribution);
  const std::uint64_t single_tag = single ? UINT64_C(0xd) : UINT64_C(0x0);
  const std::uint64_t state =
      input_seed ^
      (UINT64_C(0x9e3779b97f4a7c15) *
       (static_cast<std::uint64_t>(operation) + 1)) ^
      (UINT64_C(0xbf58476d1ce4e5b9) * (distribution_tag + 1)) ^ single_tag;
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
      inputs.x[index] = special_value(first_index, single);
      inputs.y[index] = special_value(second_index, single);
    }
    return inputs;
  }

  for (std::size_t index = 0; index < sample_count; ++index) {
    const GeneratedPair pair = distribution == Distribution::normal
                                   ? generate_normal(operation, rng, single)
                                   : generate_wide(operation, rng, single);
    put_pair(inputs, index, pair, single);
  }
  return inputs;
}

std::string input_hash(const Inputs &inputs, bool single) {
  std::uint64_t hash = UINT64_C(1469598103934665603);
  const auto absorb = [&hash](std::uint8_t byte) {
    hash ^= static_cast<std::uint64_t>(byte);
    hash *= UINT64_C(1099511628211);
  };
  absorb(single ? 1 : 0);
  const auto absorb_value = [&absorb, single](double value) {
    if (single) {
      const std::uint32_t bits =
          static_cast<std::uint32_t>(value_to_bits(input_f32(value)));
      for (unsigned byte = 0; byte < 4; ++byte) {
        absorb(static_cast<std::uint8_t>(bits >> (byte * 8)));
      }
      return;
    }
    const std::uint64_t bits = value_to_bits(value);
    for (unsigned byte = 0; byte < 8; ++byte) {
      absorb(static_cast<std::uint8_t>(bits >> (byte * 8)));
    }
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
            CompareF32 function) {
  return audit_impl<float>(operation, inputs, function);
}

Audit audit(std::uint32_t operation, const Inputs &inputs,
            CompareF64 function) {
  return audit_impl<double>(operation, inputs, function);
}

bool self_check(std::string *error) {
  try {
    for (std::uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
         ++operation) {
      for (Distribution distribution :
           {Distribution::normal, Distribution::wide, Distribution::special}) {
        const Inputs first = make_inputs(operation, distribution, false);
        const Inputs second = make_inputs(operation, distribution, false);
        if (input_hash(first, false) != input_hash(second, false)) {
          set_error(error, "comparative: non-deterministic binary64 digest");
          return false;
        }
        const Inputs narrow = make_inputs(operation, distribution, true);
        const Inputs narrow_repeat = make_inputs(operation, distribution, true);
        if (input_hash(narrow, true) != input_hash(narrow_repeat, true)) {
          set_error(error, "comparative: non-deterministic binary32 digest");
          return false;
        }
        for (std::size_t index = 0; index < sample_count; ++index) {
          if (distribution != Distribution::special &&
              (!std::isfinite(narrow.x[index]) ||
               !std::isfinite(narrow.y[index]))) {
            set_error(
                error,
                "comparative: generated finite distribution is non-finite");
            return false;
          }
          if (distribution != Distribution::special) {
            if (static_cast<double>(static_cast<float>(narrow.x[index])) !=
                    narrow.x[index] ||
                static_cast<double>(static_cast<float>(narrow.y[index])) !=
                    narrow.y[index]) {
              set_error(error, "comparative: single dataset is not exact f32");
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
              if (!values_have_same_bits(first.x[tuple],
                                         special_value(first_index, false)) ||
                  !values_have_same_bits(first.y[tuple],
                                         special_value(second_index, false))) {
                set_error(error,
                          "comparative: missing required f64 special tuple");
                return false;
              }
              const std::uint32_t actual_first = static_cast<std::uint32_t>(
                  value_to_bits(input_f32(narrow.x[tuple])));
              const std::uint32_t actual_second = static_cast<std::uint32_t>(
                  value_to_bits(input_f32(narrow.y[tuple])));
              if (actual_first != special_f32_bits[first_index] ||
                  actual_second != special_f32_bits[second_index]) {
                set_error(error,
                          "comparative: f32 special tuple conversion changed");
                return false;
              }
            }
          }
        }
      }
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
      boundary_inputs.x[index] =
          bits_to_value<double>(UINT64_C(0x8000000000000000));
      boundary_inputs.y[index] =
          bits_to_value<double>(UINT64_C(0x8000000000000000));
    }
    // The shared zero coordinate must not hide a provider's zero-sign
    // mismatch in either format.
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

    set_error(error, nullptr);
    return true;
  } catch (const std::exception &exception) {
    if (error != nullptr)
      *error = exception.what();
    return false;
  }
}

} // namespace comparative
