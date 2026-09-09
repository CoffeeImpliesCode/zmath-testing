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

// `format` narrows each generated finite value to the selected IEEE format
// and promotes it back to double. Thus the arrays carry exact call values for
// a fair comparison. Binary calls consume fn(x[i], y[i]) in this order. For
// atan2 and atan2pi, x is the standard first (y-coordinate) argument and y is
// the standard second (x-coordinate) argument. Unary wrappers ignore y.
Inputs make_inputs(std::uint32_t operation, Distribution distribution,
                   CompareFormat format);

// Stable, lowercase hexadecimal FNV-1a-64 digest over the complete ordered
// call-input bit representation of x and y, including the format tag. Each
// value contributes its exact target-format encoding. This is a
// reproducibility digest, not a cryptographic hash. The byte order is fixed
// little-endian so the digest does not depend on host endianness.
std::string input_hash(const Inputs &inputs, CompareFormat format);
// Convert a generated binary64 input to its binary16 or binary32 call value.
// Finite values use the ordinary IEEE narrowing conversion. NaNs are
// reconstructed from raw bits so their sign, quiet/signaling class, and
// high-order payload bits survive preparation; lower payload bits are outside
// the target format.
_Float16 input_f16(double value);
float input_f32(double value);

struct Audit {
  std::uint64_t samples = 0;
  std::uint64_t finite_compared = 0;
  std::uint64_t max_ulp = 0;
  std::uint64_t nonfinite_mismatches = 0;
  std::uint64_t signed_zero_mismatches = 0;
};

// Audit IEEE special-value rules and use MPFR-512, round-to-nearest-even
// for the remaining reference values. Preserve signaling-NaN precedence
// and rsqrt(-0) = -Inf. This is audit evidence, not a formal rounding proof:
// the fixed MPFR precision can double-round an exact result. NaN payloads
// are ignored. `nonfinite_mismatches` counts finite/non-finite or NaN/Inf
// class differences and opposite infinity signs; `signed_zero_mismatches`
// reports zero sign differences separately. ULP distance is collected only
// for finite results, with an overflow-safe monotonic IEEE ordering.
Audit audit(std::uint32_t operation, const Inputs &inputs, CompareF16 function);
Audit audit(std::uint32_t operation, const Inputs &inputs, CompareF32 function);
Audit audit(std::uint32_t operation, const Inputs &inputs, CompareF64 function);

// Check deterministic generation, exact target-format narrowing,
// special-value coverage, reference-oracle behavior, and digest stability
// without invoking a provider. Returns true on success; when false and
// `error` is non-null, stores a concise failure description.
bool self_check(std::string *error = nullptr);

} // namespace comparative

#endif
