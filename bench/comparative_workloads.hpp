#ifndef ZMATH_TESTING_BENCH_COMPARATIVE_WORKLOADS_HPP
#define ZMATH_TESTING_BENCH_COMPARATIVE_WORKLOADS_HPP

#include "comparative.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace comparative {

// Every provider sees this exact number and order of samples. Generation is
// deterministic and is performed before a benchmark's timed region.
constexpr std::size_t sample_count = 1024;
constexpr std::uint64_t input_seed = UINT64_C(0x5a4d4154485f434f);

enum class Distribution : std::uint8_t {
  normal = 0,
  wide = 1,
  special = 2,
};

struct Inputs {
  std::array<double, sample_count> x{};
  std::array<double, sample_count> y{};
};

// `single=true` narrows each generated finite value to binary32 and promotes
// it back to double. Thus the arrays carry exact f32 values for a fair f32
// call through CompareF32. `single=false` retains binary64 values.
//
// Binary calls consume fn(x[i], y[i]) in this order. For atan2, x is the
// standard first (y-coordinate) argument and y is the standard second
// (x-coordinate) argument. Unary wrappers ignore y.
Inputs make_inputs(std::uint32_t operation, Distribution distribution,
                   bool single);

// Stable, lowercase hexadecimal FNV-1a-64 digest over the complete ordered
// call-input bit representation of x and y, including the single flag. For
// single=true each value contributes its exact f32 encoding via input_f32;
// otherwise each value contributes its f64 encoding. This is a
// reproducibility digest, not a cryptographic hash. The byte order is fixed
// little-endian so the digest does not depend on host endianness.
std::string input_hash(const Inputs &inputs, bool single);
// Convert a generated binary64 input to its binary32 call value. Finite
// values use the ordinary IEEE narrowing conversion. NaNs are reconstructed
// from raw bits so their sign, quiet/signaling class, and high-order payload
// bits survive preparation; lower payload bits are outside binary32.
float input_f32(double value);

struct Audit {
  std::uint64_t samples = 0;
  std::uint64_t finite_compared = 0;
  std::uint64_t max_ulp = 0;
  std::uint64_t nonfinite_mismatches = 0;
  std::uint64_t signed_zero_mismatches = 0;
};

// Compare a provider against an MPFR-512, round-to-nearest-even reference.
// This is numerical audit evidence, not a formal correctly-rounded proof;
// the fixed MPFR precision can double-round an exact result. NaN payloads
// are ignored. `nonfinite_mismatches` counts finite/non-finite or NaN/Inf
// class differences and opposite infinity signs; `signed_zero_mismatches`
// reports zero sign differences separately. ULP distance is collected only
// for finite results, with an overflow-safe monotonic IEEE ordering.
Audit audit(std::uint32_t operation, const Inputs &inputs, CompareF32 function);
Audit audit(std::uint32_t operation, const Inputs &inputs, CompareF64 function);

// Check deterministic generation, f32 truncation, special-value coverage,
// and digest stability without invoking a provider. Returns true on success;
// when false and `error` is non-null, stores a concise failure description.
bool self_check(std::string *error = nullptr);

} // namespace comparative

#endif
