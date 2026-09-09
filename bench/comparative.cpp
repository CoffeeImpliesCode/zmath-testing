#include "comparative.h"
#include "comparative_workloads.hpp"

#include <benchmark/benchmark.h>
#include <cctype>
#include <cstdlib>

#include <cfenv>
#include <cinttypes>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#if defined(__SSE__) || defined(__x86_64__)
#include <immintrin.h>
#endif
#if !defined(COMPARATIVE_BUILD_MODE) || !defined(COMPARATIVE_TARGET) ||        \
    !defined(COMPARATIVE_COMPILER) || !defined(COMPARATIVE_CXX_FLAGS)
#error                                                                         \
    "comparison build must define COMPARATIVE_BUILD_MODE, COMPARATIVE_TARGET, COMPARATIVE_COMPILER, and COMPARATIVE_CXX_FLAGS"
#endif

namespace {

constexpr std::uint32_t kMxcsrFlushMask = 0x8040u;
constexpr std::uint32_t kMxcsrRoundingMask = 0x6000u;
constexpr std::uint32_t kMxcsrExceptionFlags = 0x003fu;
constexpr std::size_t kBatchSize = comparative::sample_count;
constexpr std::size_t kGlibcOriginCount = COMPARE_OPERATION_COUNT * 2;

const char *const kOperationNames[COMPARE_OPERATION_COUNT] = {
    "exp", "log", "sin", "cos", "tan", "sqrt", "hypot", "atan2", "pow",
};

const char *const kDistributionNames[] = {"normal", "wide", "special"};
constexpr std::size_t kDistributionCount =
    sizeof(kDistributionNames) / sizeof(kDistributionNames[0]);

struct FpuState {
  int rounding = FE_TONEAREST;
  std::uint32_t mxcsr = 0;
};

FpuState capture_fpu_state() {
  FpuState state;
  state.rounding = std::fegetround();
#if defined(__SSE__) || defined(__x86_64__)
  state.mxcsr = _mm_getcsr();
#endif
  return state;
}

std::string fpu_state_text(const FpuState &state) {
  std::ostringstream output;
  output << "rounding=" << state.rounding << ",mxcsr=0x" << std::hex
         << state.mxcsr;
  return output.str();
}

bool fpu_controls_equal(const FpuState &expected, const FpuState &actual) {
  if (expected.rounding != actual.rounding) {
    return false;
  }
  // Exception flags are sticky result state, not control state. Compare all
  // other MXCSR bits so a provider cannot change rounding, FTZ, DAZ, masks,
  // or precision controls without being reported.
  return (expected.mxcsr & ~kMxcsrExceptionFlags) ==
         (actual.mxcsr & ~kMxcsrExceptionFlags);
}

bool verify_initial_fpu(const FpuState &state, std::string *error) {
  if (state.rounding != FE_TONEAREST) {
    if (error) {
      *error = "FE_TONEAREST is required; observed " +
               std::to_string(state.rounding);
    }
    return false;
  }
  if ((state.mxcsr & (kMxcsrFlushMask | kMxcsrRoundingMask)) != 0) {
    if (error) {
      std::ostringstream output;
      output
          << "MXCSR rounding, FTZ, and DAZ must be disabled; observed MXCSR=0x"
          << std::hex << state.mxcsr;
      *error = output.str();
    }
    return false;
  }
  return true;
}

struct ProviderDefinition {
  const char *name;
  const char *display_name;
  CompareF32 (*get_f32)(std::uint32_t);
  CompareF64 (*get_f64)(std::uint32_t);
  bool allows_missing;
};

const ProviderDefinition kProviders[] = {
    {"zmath", "zmath", &compare_zmath_f32, &compare_zmath_f64, false},
    {"zig", "Zig stdlib", &compare_zig_f32, &compare_zig_f64, false},
    {"glibc", "glibc libm", &compare_glibc_f32, &compare_glibc_f64, false},
    {"coremath", "vendored CORE-MATH", &compare_coremath_f32,
     &compare_coremath_f64, true},
};
constexpr std::size_t kProviderCount =
    sizeof(kProviders) / sizeof(kProviders[0]);

struct ProviderAvailability {
  const ProviderDefinition *definition = nullptr;
  CompareF32 f32[COMPARE_OPERATION_COUNT]{};
  CompareF64 f64[COMPARE_OPERATION_COUNT]{};
};
struct GlibcOrigin {
  std::uint32_t operation = 0;
  bool single = false;
  std::string path;
};

struct GlibcProvenance {
  std::string version;
  GlibcOrigin origins[kGlibcOriginCount];
};

struct Dataset {
  std::uint32_t operation = 0;
  comparative::Distribution distribution = comparative::Distribution::normal;
  bool single = false;
  comparative::Inputs inputs;
  std::vector<float> x32;
  std::vector<float> y32;
  std::vector<double> x64;
  std::vector<double> y64;
  std::string digest;

  Dataset()
      : x32(kBatchSize), y32(kBatchSize), x64(kBatchSize), y64(kBatchSize) {}
};

struct AccuracyRecord {
  const ProviderDefinition *provider = nullptr;
  const Dataset *dataset = nullptr;
  bool available = false;
  comparative::Audit audit;
};

struct BenchmarkBinding {
  const Dataset *dataset = nullptr;
  const ProviderDefinition *provider = nullptr;
  CompareF32 f32 = nullptr;
  CompareF64 f64 = nullptr;
  FpuState expected_fpu;
  std::string name;
};

struct CommandOptions {
  std::string accuracy_out;
  bool have_accuracy_out = false;
  bool audit_only = false;
};

bool truthy_benchmark_flag(std::string value) {
  if (value.size() == 1) {
    const unsigned char character = static_cast<unsigned char>(value.front());
    return std::isalnum(character) != 0 && value.front() != '0' &&
           value.front() != 'f' && value.front() != 'F' &&
           value.front() != 'n' && value.front() != 'N';
  }
  if (!value.empty()) {
    for (char &character : value) {
      character = static_cast<char>(
          std::tolower(static_cast<unsigned char>(character)));
    }
    return value != "false" && value != "no" && value != "off";
  }
  return true;
}

bool benchmark_list_tests_requested(int argc, char **argv) {
  bool requested = false;
  if (const char *environment = std::getenv("BENCHMARK_LIST_TESTS")) {
    requested = truthy_benchmark_flag(environment);
  }

  constexpr char prefix[] = "--benchmark_list_tests=";
  for (int index = 1; index < argc; ++index) {
    const std::string argument(argv[index]);
    if (argument == "--benchmark_list_tests") {
      requested = true;
    } else if (argument.compare(0, sizeof(prefix) - 1, prefix) == 0) {
      requested = truthy_benchmark_flag(argument.substr(sizeof(prefix) - 1));
    }
  }
  return requested;
}

std::string json_escape(const std::string &value) {
  std::ostringstream output;
  for (unsigned char character : value) {
    switch (character) {
    case '"':
      output << "\\\"";
      break;
    case '\\':
      output << "\\\\";
      break;
    case '\b':
      output << "\\b";
      break;
    case '\f':
      output << "\\f";
      break;
    case '\n':
      output << "\\n";
      break;
    case '\r':
      output << "\\r";
      break;
    case '\t':
      output << "\\t";
      break;
    default:
      if (character < 0x20) {
        output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
               << static_cast<unsigned int>(character) << std::dec;
      } else {
        output << static_cast<char>(character);
      }
      break;
    }
  }
  return output.str();
}

const char *format_name(bool single) { return single ? "f32" : "f64"; }
bool is_libm_shared_object_origin(const std::string &origin) {
  if (origin.empty() || origin.front() != '/' ||
      origin.find(';') != std::string::npos ||
      origin.find("compiler_rt") != std::string::npos ||
      origin.find("compiler-rt") != std::string::npos) {
    return false;
  }

  const std::filesystem::path path(origin);
  std::error_code filesystem_error;
  if (!std::filesystem::is_regular_file(path, filesystem_error) ||
      filesystem_error) {
    return false;
  }
  unsigned char header[18]{};
  std::ifstream object(path, std::ios::in | std::ios::binary);
  object.read(reinterpret_cast<char *>(header), sizeof(header));
  if (object.gcount() != static_cast<std::streamsize>(sizeof(header)) ||
      header[0] != 0x7f || header[1] != 'E' || header[2] != 'L' ||
      header[3] != 'F' || (header[5] != 1 && header[5] != 2)) {
    return false;
  }
  const std::uint16_t object_type =
      header[5] == 1 ? static_cast<std::uint16_t>(header[16]) |
                           (static_cast<std::uint16_t>(header[17]) << 8)
                     : (static_cast<std::uint16_t>(header[16]) << 8) |
                           static_cast<std::uint16_t>(header[17]);
  if (object_type != 3) {
    return false;
  }
  filesystem_error.clear();
  if (std::filesystem::equivalent(path, std::filesystem::path("/proc/self/exe"),
                                  filesystem_error)) {
    return false;
  }
  if (filesystem_error) {
    return false;
  }
  const std::size_t separator = origin.find_last_of('/');
  if (separator == std::string::npos || separator + 1 >= origin.size()) {
    return false;
  }
  const std::size_t name_offset = separator + 1;
  constexpr char stem[] = "libm.so";
  constexpr std::size_t stem_length = sizeof(stem) - 1;
  if (origin.compare(name_offset, stem_length, stem) != 0) {
    return false;
  }

  std::size_t offset = name_offset + stem_length;
  if (offset == origin.size()) {
    return true;
  }
  if (origin[offset] != '.' || ++offset == origin.size()) {
    return false;
  }

  bool component_has_digit = false;
  for (; offset < origin.size(); ++offset) {
    const unsigned char character = static_cast<unsigned char>(origin[offset]);
    if (std::isdigit(character)) {
      component_has_digit = true;
    } else if (character == '.' && component_has_digit) {
      component_has_digit = false;
    } else {
      return false;
    }
  }
  return component_has_digit;
}

bool resolve_glibc_provenance(GlibcProvenance *provenance, std::string *error) {
  const char *const version = compare_glibc_version();
  if (!version || !*version) {
    if (error)
      *error = "glibc provider returned no GNU libc version";
    return false;
  }
  provenance->version = version;

  std::size_t index = 0;
  for (std::uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
       ++operation) {
    for (const bool single : {true, false}) {
      const char *const value =
          compare_glibc_origin(operation, single ? 1u : 0u);
      if (!value || !*value) {
        if (error) {
          *error = "glibc provider returned no origin for " +
                   std::string(kOperationNames[operation]) + "/" +
                   format_name(single);
        }
        return false;
      }

      const std::string path(value);
      if (!is_libm_shared_object_origin(path)) {
        if (error) {
          *error = "glibc provider origin is not an absolute libm.so shared "
                   "object for " +
                   std::string(kOperationNames[operation]) + "/" +
                   format_name(single) + ": " + path;
        }
        return false;
      }

      GlibcOrigin &origin = provenance->origins[index++];
      origin.operation = operation;
      origin.single = single;
      origin.path = path;
    }
  }
  if (index != kGlibcOriginCount) {
    if (error)
      *error = "glibc provider origin matrix is incomplete";
    return false;
  }
  return true;
}

const char *distribution_name(comparative::Distribution distribution) {
  const auto index = static_cast<std::size_t>(distribution);
  return index < kDistributionCount ? kDistributionNames[index] : "invalid";
}

std::string benchmark_name(const ProviderDefinition &provider,
                           const Dataset &dataset) {
  std::ostringstream output;
  output << provider.name << "/" << kOperationNames[dataset.operation] << "/"
         << format_name(dataset.single) << "/"
         << distribution_name(dataset.distribution);
  return output.str();
}

bool parse_custom_arguments(int *argc, char ***argv, CommandOptions *options,
                            std::string *error) {
  if (!argc || !argv || !*argv || !options) {
    if (error)
      *error = "invalid argument vector";
    return false;
  }

  int write_index = 1;
  for (int read_index = 1; read_index < *argc; ++read_index) {
    const std::string argument((*argv)[read_index]);
    if (argument == "--audit_only") {
      if (options->audit_only) {
        if (error)
          *error = "duplicate --audit_only";
        return false;
      }
      options->audit_only = true;
      continue;
    }
    if (argument.rfind("--audit_only=", 0) == 0) {
      if (error)
        *error = "--audit_only does not accept a value";
      return false;
    }
    if (argument == "--accuracy_out") {
      if (error)
        *error = "--accuracy_out requires the form --accuracy_out=<path>";
      return false;
    }
    if (argument.rfind("--accuracy_out=", 0) == 0) {
      const std::string path =
          argument.substr(std::string("--accuracy_out=").size());
      if (path.empty()) {
        if (error)
          *error = "--accuracy_out path must not be empty";
        return false;
      }
      if (options->have_accuracy_out) {
        if (error)
          *error = "duplicate --accuracy_out";
        return false;
      }
      options->accuracy_out = path;
      options->have_accuracy_out = true;
      continue;
    }
    (*argv)[write_index++] = (*argv)[read_index];
  }
  (*argv)[write_index] = nullptr;
  *argc = write_index;
  return true;
}

std::vector<Dataset> make_datasets() {
  std::vector<Dataset> datasets;
  datasets.reserve(COMPARE_OPERATION_COUNT * kDistributionCount * 2);
  for (std::uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
       ++operation) {
    for (std::size_t distribution_index = 0;
         distribution_index < kDistributionCount; ++distribution_index) {
      const auto distribution =
          static_cast<comparative::Distribution>(distribution_index);
      for (const bool single : {true, false}) {
        Dataset dataset;
        dataset.operation = operation;
        dataset.distribution = distribution;
        dataset.single = single;
        dataset.inputs =
            comparative::make_inputs(operation, distribution, single);
        dataset.digest = comparative::input_hash(dataset.inputs, single);
        if (dataset.digest.empty()) {
          throw std::runtime_error("input_hash returned an empty digest");
        }
        for (std::size_t index = 0; index < kBatchSize; ++index) {
          dataset.x64[index] = dataset.inputs.x[index];
          dataset.y64[index] = dataset.inputs.y[index];
          dataset.x32[index] = comparative::input_f32(dataset.inputs.x[index]);
          dataset.y32[index] = comparative::input_f32(dataset.inputs.y[index]);
        }
        datasets.emplace_back(std::move(dataset));
      }
    }
  }
  return datasets;
}

std::vector<ProviderAvailability>
resolve_providers(std::string *error, bool report_unavailable = true) {
  std::vector<ProviderAvailability> providers;
  providers.reserve(kProviderCount);
  std::size_t required_provider_count = 0;

  for (const ProviderDefinition &definition : kProviders) {
    ProviderAvailability availability;
    availability.definition = &definition;
    for (std::uint32_t operation = 0; operation < COMPARE_OPERATION_COUNT;
         ++operation) {
      availability.f32[operation] = definition.get_f32(operation);
      availability.f64[operation] = definition.get_f64(operation);
      if (definition.allows_missing) {
        if (report_unavailable) {
          if (!availability.f32[operation]) {
            std::cout
                << "availability provider=" << definition.name
                << " operation=" << kOperationNames[operation]
                << " format=f32 status=UNSUPPORTED label=vendored_CORE-MATH\n";
          }
          if (!availability.f64[operation]) {
            std::cout
                << "availability provider=" << definition.name
                << " operation=" << kOperationNames[operation]
                << " format=f64 status=UNSUPPORTED label=vendored_CORE-MATH\n";
          }
        }
      } else if (!availability.f32[operation] || !availability.f64[operation]) {
        if (error) {
          std::ostringstream output;
          output << "required provider " << definition.name
                 << " lacks operation " << kOperationNames[operation]
                 << " getter(s)";
          *error = output.str();
        }
        return {};
      }
    }
    if (!definition.allows_missing) {
      ++required_provider_count;
    }
    providers.emplace_back(availability);
  }
  if (required_provider_count != 3 || providers.size() != kProviderCount) {
    if (error)
      *error = "no complete required providers are available";
    return {};
  }
  return providers;
}
bool run_accuracy_audit(const std::vector<Dataset> &datasets,
                        const std::vector<ProviderAvailability> &providers,
                        const FpuState &expected_fpu,
                        std::vector<AccuracyRecord> *records,
                        std::string *error) {
  records->clear();
  records->reserve(datasets.size() * providers.size());
  for (const Dataset &dataset : datasets) {
    for (const ProviderAvailability &provider : providers) {
      AccuracyRecord record;
      record.provider = provider.definition;
      record.dataset = &dataset;
      record.available = dataset.single
                             ? provider.f32[dataset.operation] != nullptr
                             : provider.f64[dataset.operation] != nullptr;
      if (record.available) {
        try {
          record.audit =
              dataset.single
                  ? comparative::audit(dataset.operation, dataset.inputs,
                                       provider.f32[dataset.operation])
                  : comparative::audit(dataset.operation, dataset.inputs,
                                       provider.f64[dataset.operation]);
          if (record.audit.samples != kBatchSize ||
              record.audit.finite_compared > record.audit.samples) {
            if (error) {
              *error = "accuracy audit returned incomplete counters for " +
                       benchmark_name(*provider.definition, dataset);
            }
            return false;
          }
        } catch (const std::exception &exception) {
          if (error) {
            *error = "accuracy audit failed for " +
                     benchmark_name(*provider.definition, dataset) + ": " +
                     exception.what();
          }
          return false;
        } catch (...) {
          if (error) {
            *error = "accuracy audit failed for " +
                     benchmark_name(*provider.definition, dataset) +
                     ": unknown exception";
          }
          return false;
        }
        const FpuState after_audit = capture_fpu_state();
        if (!fpu_controls_equal(expected_fpu, after_audit)) {
          if (error) {
            *error =
                "provider changed floating-point controls after audit for " +
                benchmark_name(*provider.definition, dataset) + " (expected " +
                fpu_state_text(expected_fpu) + ", observed " +
                fpu_state_text(after_audit) + ")";
          }
          return false;
        }
      }
      records->emplace_back(record);
    }
  }
  const FpuState after_all = capture_fpu_state();
  if (!fpu_controls_equal(expected_fpu, after_all)) {
    if (error)
      *error = "floating-point controls changed during accuracy audit";
    return false;
  }
  return true;
}

void write_audit_json(const std::string &path,
                      const std::vector<Dataset> &datasets,
                      const std::vector<ProviderAvailability> &providers,
                      const std::vector<AccuracyRecord> &records,
                      const GlibcProvenance &glibc, const FpuState &fpu) {
  std::ofstream output(path, std::ios::out | std::ios::trunc);
  if (!output) {
    throw std::runtime_error("cannot open accuracy output: " + path);
  }
  output
      << "{\n"
      << "  \"schema\": \"zmath-comparative-accuracy-v1\",\n"
      << "  \"reference\": {\"kind\": \"MPFR\", \"precision_bits\": 512, "
         "\"rounding\": \"RNE\", \"formal_correct_rounding_proof\": false},\n"
      << "  \"build\": {\"mode\": \"" << json_escape(COMPARATIVE_BUILD_MODE)
      << "\", \"target\": \"" << json_escape(COMPARATIVE_TARGET)
      << "\", \"compiler\": \"" << json_escape(COMPARATIVE_COMPILER)
      << "\", \"compiler_version\": \"" << json_escape(__VERSION__)
      << "\", \"cxx_flags\": \"" << json_escape(COMPARATIVE_CXX_FLAGS)
      << "\"},\n";
  output << "  \"glibc_provenance\": {\"version\": \""
         << json_escape(glibc.version) << "\", \"origins\": [\n";
  for (std::size_t index = 0; index < kGlibcOriginCount; ++index) {
    const GlibcOrigin &origin = glibc.origins[index];
    if (index)
      output << ",\n";
    output << "    {\"operation\": \"" << kOperationNames[origin.operation]
           << "\", \"format\": \"" << format_name(origin.single)
           << "\", \"path\": \"" << json_escape(origin.path) << "\"}";
  }
  output << "\n  ]},\n";
  output << "  \"sample_count\": " << kBatchSize << ",\n"
         << "  \"input_seed\": \"0x5a4d4154485f434f\",\n"
         << "  \"fpu\": {\"rounding\": " << fpu.rounding << ", \"mxcsr\": \"0x"
         << std::hex << fpu.mxcsr << std::dec << "\"},\n"
         << "  \"providers\": [";
  for (std::size_t index = 0; index < kProviderCount; ++index) {
    if (index)
      output << ", ";
    output << "\"" << json_escape(kProviders[index].name) << "\"";
  }
  output << "],\n  \"records\": [\n";

  for (std::size_t index = 0; index < records.size(); ++index) {
    const AccuracyRecord &record = records[index];
    const Dataset &dataset = *record.dataset;
    if (index)
      output << ",\n";
    output << "    {\"provider\": \"" << json_escape(record.provider->name)
           << "\", \"provider_label\": \""
           << json_escape(record.provider->display_name)
           << "\", \"operation\": \"" << kOperationNames[dataset.operation]
           << "\", \"format\": \"" << format_name(dataset.single)
           << "\", \"distribution\": \""
           << distribution_name(dataset.distribution)
           << "\", \"input_hash\": \"" << json_escape(dataset.digest)
           << "\", \"available\": " << (record.available ? "true" : "false")
           << ", \"status\": \""
           << (record.available ? "audited" : "unsupported") << "\"";
    if (record.available) {
      output << ", \"audit\": {\"samples\": " << record.audit.samples
             << ", \"finite_compared\": " << record.audit.finite_compared
             << ", \"max_ulp\": " << record.audit.max_ulp
             << ", \"nonfinite_mismatches\": "
             << record.audit.nonfinite_mismatches
             << ", \"signed_zero_mismatches\": "
             << record.audit.signed_zero_mismatches << "}";
    } else {
      output << ", \"audit\": null";
    }
    output << "}";
  }
  output << "\n  ]\n}\n";
  if (!output) {
    throw std::runtime_error("failed while writing accuracy output: " + path);
  }
  (void)datasets;
  (void)providers;
}

void benchmark_f32(benchmark::State &state, const BenchmarkBinding *binding) {
  state.SetLabel(binding->name.c_str());
  for (auto _ : state) {
    for (std::size_t index = 0; index < kBatchSize; ++index) {
      float result = binding->f32(binding->dataset->x32[index],
                                  binding->dataset->y32[index]);
      benchmark::DoNotOptimize(result);
    }
    state.PauseTiming();
    const FpuState after_iteration = capture_fpu_state();
    const bool stable =
        fpu_controls_equal(binding->expected_fpu, after_iteration);
    state.ResumeTiming();
    if (!stable) {
      state.SkipWithError(
          "provider changed floating-point controls during timing");
      return;
    }
  }
  state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                          static_cast<std::int64_t>(kBatchSize));
}

void benchmark_f64(benchmark::State &state, const BenchmarkBinding *binding) {
  state.SetLabel(binding->name.c_str());
  for (auto _ : state) {
    for (std::size_t index = 0; index < kBatchSize; ++index) {
      double result = binding->f64(binding->dataset->x64[index],
                                   binding->dataset->y64[index]);
      benchmark::DoNotOptimize(result);
    }
    state.PauseTiming();
    const FpuState after_iteration = capture_fpu_state();
    const bool stable =
        fpu_controls_equal(binding->expected_fpu, after_iteration);
    state.ResumeTiming();
    if (!stable) {
      state.SkipWithError(
          "provider changed floating-point controls during timing");
      return;
    }
  }
  state.SetItemsProcessed(static_cast<std::int64_t>(state.iterations()) *
                          static_cast<std::int64_t>(kBatchSize));
}

void register_benchmarks(const std::vector<Dataset> &datasets,
                         const std::vector<ProviderAvailability> &providers,
                         const FpuState &expected_fpu,
                         std::vector<BenchmarkBinding> *bindings) {
  bindings->reserve(datasets.size() * providers.size());
  for (const Dataset &dataset : datasets) {
    for (const ProviderAvailability &provider : providers) {
      const CompareF32 f32 =
          dataset.single ? provider.f32[dataset.operation] : nullptr;
      const CompareF64 f64 =
          dataset.single ? nullptr : provider.f64[dataset.operation];
      if (!f32 && !f64) {
        continue;
      }
      BenchmarkBinding binding;
      binding.dataset = &dataset;
      binding.provider = provider.definition;
      binding.f32 = f32;
      binding.f64 = f64;
      binding.expected_fpu = expected_fpu;
      binding.name = benchmark_name(*provider.definition, dataset);
      bindings->emplace_back(std::move(binding));
    }
  }
  for (BenchmarkBinding &binding : *bindings) {
    if (binding.dataset->single) {
      benchmark::RegisterBenchmark(binding.name.c_str(),
                                   [ptr = &binding](benchmark::State &state) {
                                     benchmark_f32(state, ptr);
                                   })
          ->Unit(benchmark::kNanosecond);
    } else {
      benchmark::RegisterBenchmark(binding.name.c_str(),
                                   [ptr = &binding](benchmark::State &state) {
                                     benchmark_f64(state, ptr);
                                   })
          ->Unit(benchmark::kNanosecond);
    }
  }
}

void add_context(const std::vector<Dataset> &datasets,
                 const GlibcProvenance &glibc, const FpuState &fpu) {
  benchmark::AddCustomContext("comparison.compiler", COMPARATIVE_COMPILER);
  benchmark::AddCustomContext("comparison.compiler_version", __VERSION__);
  benchmark::AddCustomContext("comparison.framework", "google-benchmark");
  benchmark::AddCustomContext("comparison.target", COMPARATIVE_TARGET);
  benchmark::AddCustomContext("comparison.mode", COMPARATIVE_BUILD_MODE);
  benchmark::AddCustomContext("comparison.cxx_flags", COMPARATIVE_CXX_FLAGS);
  benchmark::AddCustomContext("comparison.batch_size",
                              std::to_string(kBatchSize));
  benchmark::AddCustomContext("comparison.scalar_throughput_only", "true");
  benchmark::AddCustomContext("comparison.reference",
                              "MPFR-512-RNE-audit-not-formal-proof");
  benchmark::AddCustomContext("comparison.fpu_rounding",
                              std::to_string(fpu.rounding));
  benchmark::AddCustomContext("comparison.fpu_mxcsr", fpu_state_text(fpu));
  benchmark::AddCustomContext("comparison.glibc_version", glibc.version);

  std::ostringstream origins;
  for (std::size_t index = 0; index < kGlibcOriginCount; ++index) {
    const GlibcOrigin &origin = glibc.origins[index];
    if (index)
      origins << ";";
    origins << kOperationNames[origin.operation] << "/"
            << format_name(origin.single) << "=" << origin.path;
  }
  benchmark::AddCustomContext("comparison.glibc_origins", origins.str());

  std::ostringstream digests;
  bool first = true;
  for (const Dataset &dataset : datasets) {
    if (!first)
      digests << ";";
    first = false;
    digests << kOperationNames[dataset.operation] << "/"
            << format_name(dataset.single) << "/"
            << distribution_name(dataset.distribution) << "=" << dataset.digest;
  }
  benchmark::AddCustomContext("comparison.input_digests", digests.str());
  benchmark::AddCustomContext("comparison.labels",
                              "provider/op/format/distribution");
  benchmark::AddCustomContext("comparison.coremath_label",
                              "vendored CORE-MATH; unsupported rows omitted");
}

} // namespace

int main(int argc, char **argv) {
  const bool list_tests_requested = benchmark_list_tests_requested(argc, argv);

  CommandOptions options;
  std::string error;
  if (!parse_custom_arguments(&argc, &argv, &options, &error)) {
    std::cerr << "comparative: invalid option: " << error << "\n";
    return 2;
  }

  benchmark::Initialize(&argc, argv);
  if (benchmark::ReportUnrecognizedArguments(argc, argv)) {
    benchmark::Shutdown();
    return 2;
  }

  const FpuState expected_fpu = capture_fpu_state();
  if (!verify_initial_fpu(expected_fpu, &error)) {
    std::cerr << "comparative: " << error << "\n";
    benchmark::Shutdown();
    return 1;
  }
  GlibcProvenance glibc_provenance;
  if (!list_tests_requested &&
      !resolve_glibc_provenance(&glibc_provenance, &error)) {
    std::cerr << "comparative: " << error << "\n";
    benchmark::Shutdown();
    return 1;
  }

  if (!list_tests_requested && !comparative::self_check(&error)) {
    std::cerr << "comparative: workload self-check failed: " << error << "\n";
    benchmark::Shutdown();
    return 1;
  }

  std::vector<ProviderAvailability> providers =
      resolve_providers(&error, !list_tests_requested);
  if (providers.empty()) {
    std::cerr << "comparative: " << error << "\n";
    benchmark::Shutdown();
    return 1;
  }

  std::vector<Dataset> datasets;
  try {
    datasets = make_datasets();
  } catch (const std::exception &exception) {
    std::cerr << "comparative: dataset generation failed: " << exception.what()
              << "\n";
    benchmark::Shutdown();
    return 1;
  }
  if (datasets.size() != COMPARE_OPERATION_COUNT * kDistributionCount * 2) {
    std::cerr << "comparative: incomplete dataset matrix\n";
    benchmark::Shutdown();
    return 1;
  }

  if (!list_tests_requested) {
    std::vector<AccuracyRecord> accuracy_records;
    if (!run_accuracy_audit(datasets, providers, expected_fpu,
                            &accuracy_records, &error)) {
      std::cerr << "comparative: " << error << "\n";
      benchmark::Shutdown();
      return 1;
    }
    if (options.have_accuracy_out) {
      try {
        write_audit_json(options.accuracy_out, datasets, providers,
                         accuracy_records, glibc_provenance, expected_fpu);
      } catch (const std::exception &exception) {
        std::cerr << "comparative: " << exception.what() << "\n";
        benchmark::Shutdown();
        return 1;
      }
    }
    std::cout << "accuracy: audited " << accuracy_records.size()
              << " provider/dataset rows"
              << (options.have_accuracy_out ? "; output=" + options.accuracy_out
                                            : "")
              << "\n";

    if (options.audit_only) {
      std::cout << "audit_only: no timing benchmarks registered\n";
      benchmark::Shutdown();
      return 0;
    }
  }

  std::vector<BenchmarkBinding> bindings;
  register_benchmarks(datasets, providers, expected_fpu, &bindings);
  if (bindings.empty()) {
    std::cerr << "comparative: no provider benchmarks are available\n";
    benchmark::Shutdown();
    return 1;
  }

  if (list_tests_requested) {
    const std::size_t listed_count = benchmark::RunSpecifiedBenchmarks();
    benchmark::Shutdown();
    return listed_count == 0 ? 1 : 0;
  }

  add_context(datasets, glibc_provenance, expected_fpu);
  const std::size_t benchmark_count = benchmark::RunSpecifiedBenchmarks();
  benchmark::Shutdown();
  if (benchmark_count == 0) {
    std::cerr << "comparative: no benchmarks matched the framework request\n";
    return 1;
  }

  const FpuState final_fpu = capture_fpu_state();
  if (!fpu_controls_equal(expected_fpu, final_fpu)) {
    std::cerr << "comparative: floating-point controls changed after "
                 "benchmarks (expected "
              << fpu_state_text(expected_fpu) << ", observed "
              << fpu_state_text(final_fpu) << ")\n";
    return 1;
  }
  return 0;
}
