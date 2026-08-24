const std = @import("std");
const corpus = @import("corpus_support");

pub const max_arity: usize = corpus.max_argument_count;
pub const core_math_repository = "https://gitlab.inria.fr/core-math/core-math.git";
pub const core_math_revision = "3bafed75e3c22399531857d63a3fa0e24bfb42fa";

pub const CampaignClass = enum {
    unavailable,
    exhaustive_h_unary,
    bounded_h_integer_domain,
    explicit_special_tuple_grid,
    source_pinned_binary_ternary_hard_tuples,
    hard_corpus_f,
    hard_corpus_d,
    exact_bit_status,
};

pub const CoverageClaim = enum {
    fail_closed,
    exhaustive_h_unary,
    bounded_h_integer_domain,
    explicit_special_tuple_grid,
    source_pinned_binary_ternary_hard_tuples,
    hard_corpus_metadata,
    exact_bit_status,
};

pub const Availability = enum {
    unavailable,
    input_only,
    metadata_only,
    records_ready,
};

pub const TuplePolicy = enum {
    exhaustive_raw_bits,
    bounded_integer_inclusive,
    ordered_special_hard,
    deterministic_hard_corpus,
    exact_cases,
};

pub const EvidenceAvailability = enum {
    source_metadata_unavailable,
    generation_ready,
    records_ready,
};

pub const UnavailableReason = enum {
    manifest_status,
    source_metadata_unavailable,
    unsupported_shape,
    missing_evidence,
};

pub const SourcePin = struct {
    repository: []const u8,
    revision: []const u8,
    path: []const u8,
};
pub const UnavailableSpec = struct {
    planned_class: CampaignClass,
    reason: UnavailableReason,
    manifest_status: corpus.Status,
    source_metadata_available: bool,
    source: ?SourcePin = null,
    artifact: []const u8,
    deterministic_seed: u64 = 0,
    tuple_count: u64 = 0,
    tuple_policy: TuplePolicy = .exact_cases,
    integer_index: ?u8 = null,
    integer_type: ?corpus.IntegerType = null,
    bounds: ?IntegerBounds = null,
    special_axis_count: u8 = 0,
};

pub const InputTuple = struct {
    fields: [max_arity]corpus.CorpusField,
    count: u8,

    pub fn init(fields: []const corpus.CorpusField) CampaignError!InputTuple {
        if (fields.len == 0 or fields.len > max_arity) return error.TupleArityMismatch;
        var tuple = InputTuple{
            .fields = blankFields(),
            .count = @intCast(fields.len),
        };
        @memcpy(tuple.fields[0..fields.len], fields);
        return tuple;
    }

    pub fn slice(self: *const @This()) []const corpus.CorpusField {
        return self.fields[0..self.count];
    }
};

pub const HardTuple = struct {
    arguments: InputTuple,
    expected_results: []const corpus.CorpusField = &.{},
    expected_status: corpus.OracleStatus = .ok,
};

pub const TupleAxis = struct {
    values: []const corpus.CorpusField,
};

pub const IntegerBounds = union(enum) {
    signed: struct {
        lower: i64,
        upper: i64,
    },
    unsigned: struct {
        lower: u64,
        upper: u64,
    },
};

pub const UnaryExhaustiveSpec = struct {
    format: corpus.Format,
    source: ?SourcePin,
    artifact: []const u8,
    deterministic_seed: u64,
    evidence: EvidenceAvailability,
};

pub const BoundedHIntegerDomainSpec = struct {
    integer_index: u8,
    integer_type: corpus.IntegerType,
    bounds: IntegerBounds,
    base_arguments: InputTuple,
    half_index: ?u8 = null,
    exhaustive_half: bool = false,
    source: ?SourcePin = null,
    artifact: []const u8 = "test/corpus/ad-hoc/h-integer-domain.zcdr",
    deterministic_seed: u64 = 0,
    evidence: EvidenceAvailability = .source_metadata_unavailable,
};

pub const SpecialTupleGridSpec = struct {
    axes: []const TupleAxis,
    source: ?SourcePin = null,
    artifact: []const u8 = "test/corpus/ad-hoc/special-grid.zcdr",
    deterministic_seed: u64 = 0,
    evidence: EvidenceAvailability = .source_metadata_unavailable,
};

pub const SourcePinnedHardTupleSpec = struct {
    source: ?SourcePin,
    artifact: []const u8,
    deterministic_seed: u64,
    tuples: []const HardTuple,
    generated_tuple_count: u8,
    evidence: EvidenceAvailability,
};

pub const HardCorpusMetadata = struct {
    format: corpus.Format,
    source: ?SourcePin,
    artifact: []const u8,
    deterministic_seed: u64,
    record_count: u64,
    evidence_available: bool,
    evidence: EvidenceAvailability,
};

pub const ExactCase = struct {
    arguments: InputTuple,
    results: []const corpus.CorpusField,
    expected_status: corpus.OracleStatus,
    max_ulp: u64,
};

pub const ExactBitStatusSpec = struct {
    cases: []const ExactCase,
    source: ?SourcePin = null,
    artifact: []const u8 = "test/corpus/ad-hoc/exact-status.zcdr",
    deterministic_seed: u64 = 0,
    evidence: EvidenceAvailability = .records_ready,
};

pub const CampaignData = union(enum) {
    unavailable: UnavailableSpec,
    exhaustive_h_unary: UnaryExhaustiveSpec,
    bounded_h_integer_domain: BoundedHIntegerDomainSpec,
    explicit_special_tuple_grid: SpecialTupleGridSpec,
    source_pinned_binary_ternary_hard_tuples: SourcePinnedHardTupleSpec,
    hard_corpus_f: HardCorpusMetadata,
    hard_corpus_d: HardCorpusMetadata,
    exact_bit_status: ExactBitStatusSpec,
};

pub const CampaignDefinition = struct {
    function: corpus.Function,
    data: CampaignData,

    pub fn campaignClass(self: *const @This()) CampaignClass {
        return switch (self.data) {
            .unavailable => .unavailable,
            .exhaustive_h_unary => .exhaustive_h_unary,
            .bounded_h_integer_domain => .bounded_h_integer_domain,
            .explicit_special_tuple_grid => .explicit_special_tuple_grid,
            .source_pinned_binary_ternary_hard_tuples => .source_pinned_binary_ternary_hard_tuples,
            .hard_corpus_f => .hard_corpus_f,
            .hard_corpus_d => .hard_corpus_d,
            .exact_bit_status => .exact_bit_status,
        };
    }
    pub fn plannedCampaignClass(self: *const @This()) CampaignClass {
        return switch (self.data) {
            .unavailable => |spec| spec.planned_class,
            else => self.campaignClass(),
        };
    }

    pub fn sourceMetadataAvailable(self: *const @This()) bool {
        return switch (self.data) {
            .unavailable => |spec| spec.source_metadata_available,
            .exhaustive_h_unary => |spec| spec.source != null,
            .hard_corpus_f, .hard_corpus_d => |spec| spec.source != null,
            .bounded_h_integer_domain => |spec| spec.source != null,
            .explicit_special_tuple_grid => |spec| spec.source != null,
            .source_pinned_binary_ternary_hard_tuples => |spec| spec.source != null,
            .exact_bit_status => |spec| spec.source != null,
        };
    }

    pub fn unavailableState(self: *const @This()) ?UnavailableSpec {
        return switch (self.data) {
            .unavailable => |spec| spec,
            else => null,
        };
    }

    pub fn coverageClaim(self: *const @This()) CoverageClaim {
        return switch (self.data) {
            .unavailable => .fail_closed,
            .exhaustive_h_unary => .exhaustive_h_unary,
            .bounded_h_integer_domain => .bounded_h_integer_domain,
            .explicit_special_tuple_grid => .explicit_special_tuple_grid,
            .source_pinned_binary_ternary_hard_tuples => .source_pinned_binary_ternary_hard_tuples,
            .hard_corpus_f, .hard_corpus_d => .hard_corpus_metadata,
            .exact_bit_status => .exact_bit_status,
        };
    }

    pub fn availability(self: *const @This()) Availability {
        return switch (self.data) {
            .unavailable => .unavailable,
            .exhaustive_h_unary, .bounded_h_integer_domain, .explicit_special_tuple_grid => .input_only,
            .source_pinned_binary_ternary_hard_tuples => |spec| blk: {
                for (spec.tuples) |tuple| {
                    if (tuple.expected_results.len != 0) break :blk .records_ready;
                }
                break :blk .input_only;
            },
            .hard_corpus_f, .hard_corpus_d => |metadata| if (metadata.evidence_available and metadata.record_count != 0)
                .records_ready
            else
                .metadata_only,
            .exact_bit_status => .records_ready,
        };
    }

    pub fn cardinality(self: *const @This()) CampaignError!u64 {
        return switch (self.data) {
            .unavailable => error.CampaignUnavailable,
            .exhaustive_h_unary => 1 << 16,
            .bounded_h_integer_domain => |spec| integerDomainCardinality(spec.bounds),
            .explicit_special_tuple_grid => |spec| tupleGridCardinality(spec.axes),
            .source_pinned_binary_ternary_hard_tuples => |spec| @intCast(spec.tuples.len),
            .hard_corpus_f => |metadata| metadata.record_count,
            .hard_corpus_d => |metadata| metadata.record_count,
            .exact_bit_status => |spec| @intCast(spec.cases.len),
        };
    }

    pub fn claimsExhaustiveFullCartesian(self: *const @This()) bool {
        // Unary H enumeration is exhaustive over its one operand. No binary
        // or ternary campaign is allowed to claim exhaustive Cartesian space.
        if (self.function.arity != 1) return false;
        return switch (self.data) {
            .exhaustive_h_unary => true,
            else => false,
        };
    }

    pub fn isEvidenceReady(self: *const @This()) bool {
        return self.availability() == .records_ready;
    }

    pub fn iterator(self: *const @This()) InputIterator {
        return .{ .definition = self.* };
    }
};

pub const RecordVisit = struct {
    function: corpus.Function,
    arguments: InputTuple,
    expected_results: []const corpus.CorpusField,
    expected_status: corpus.OracleStatus,
    max_ulp: u64,
};

pub const CampaignError = error{
    CampaignUnavailable,
    MetadataOnly,
    TupleArityMismatch,
    TupleFieldMismatch,
    InvalidDefinition,
    InvalidBounds,
    CardinalityOverflow,
    EmptyAxis,
    UnsupportedArgument,
    ExpectedResultRequired,
    InvalidSourcePin,
} || corpus.CorpusRecordError;

pub const InputIterator = struct {
    definition: CampaignDefinition,
    index: u64 = 0,

    pub fn next(self: *@This()) CampaignError!?InputTuple {
        switch (self.definition.data) {
            .unavailable => return error.CampaignUnavailable,
            .hard_corpus_f, .hard_corpus_d => return error.MetadataOnly,
            else => {},
        }

        const count = try self.definition.cardinality();
        if (self.index == count) return null;
        if (self.index > count) return error.CardinalityOverflow;

        const tuple = switch (self.definition.data) {
            .exhaustive_h_unary => |spec| try exhaustiveUnaryTuple(spec, self.index),
            .bounded_h_integer_domain => |spec| try boundedIntegerTuple(
                self.definition.function,
                spec,
                self.index,
            ),
            .explicit_special_tuple_grid => |spec| try specialGridTuple(
                self.definition.function,
                spec,
                self.index,
            ),
            .source_pinned_binary_ternary_hard_tuples => |spec| blk: {
                const hard = spec.tuples[@intCast(self.index)];
                try validateTupleAgainstFunction(self.definition.function, hard.arguments);
                break :blk hard.arguments;
            },
            .exact_bit_status => |spec| blk: {
                const exact = spec.cases[@intCast(self.index)];
                try validateTupleAgainstFunction(self.definition.function, exact.arguments);
                break :blk exact.arguments;
            },
            .unavailable, .hard_corpus_f, .hard_corpus_d => unreachable,
        };
        self.index += 1;
        return tuple;
    }
};

pub const CampaignRule = struct {
    operation: []const u8,
    provenance: corpus.Provenance,
    status: corpus.Status,
    oracle: corpus.OracleCapability,
    special_policy: []const u8,
    max_ulp: u64,
    shape_code: u64,
    format: corpus.Format,
    campaign_class: CampaignClass,
    enabled: bool,
    source: SourcePin,
    artifact: []const u8,
    deterministic_seed: u64,
    tuple_count: u64,
    tuple_policy: TuplePolicy,
    integer_index: ?u8,
    integer_type: ?corpus.IntegerType,
    bounds: ?IntegerBounds,
    special_axis_count: u8,
    source_metadata_available: bool,
    evidence: EvidenceAvailability,
};

const CampaignRuleInput = struct {
    operation: []const u8,
    provenance: corpus.Provenance,
    status: corpus.Status = .unsupported,
    oracle: corpus.OracleCapability = .none,
    shape_code: u64,
    format: corpus.Format,
    campaign_class: CampaignClass,
    enabled: bool = false,
    source_path: []const u8,
    artifact: []const u8,
    deterministic_seed: u64,
    tuple_count: u64,
    integer_index: ?u8 = null,
    integer_type: ?corpus.IntegerType = null,
    bounds: ?IntegerBounds = null,
    special_axis_count: u8 = 0,
};
fn tuplePolicyFor(campaign_class: CampaignClass) TuplePolicy {
    return switch (campaign_class) {
        .exhaustive_h_unary => .exhaustive_raw_bits,
        .bounded_h_integer_domain => .bounded_integer_inclusive,
        .explicit_special_tuple_grid, .source_pinned_binary_ternary_hard_tuples => .ordered_special_hard,
        .hard_corpus_f, .hard_corpus_d => .deterministic_hard_corpus,
        .exact_bit_status, .unavailable => .exact_cases,
    };
}

fn makeCampaignRule(input: CampaignRuleInput) CampaignRule {
    return .{
        .operation = input.operation,
        .provenance = input.provenance,
        .status = input.status,
        .oracle = input.oracle,
        .special_policy = "zmath_c23_v1",
        .max_ulp = 0,
        .shape_code = input.shape_code,
        .format = input.format,
        .campaign_class = input.campaign_class,
        .enabled = input.enabled,
        .source = .{
            .repository = core_math_repository,
            .revision = core_math_revision,
            .path = input.source_path,
        },
        .artifact = input.artifact,
        .deterministic_seed = input.deterministic_seed,
        .tuple_policy = tuplePolicyFor(input.campaign_class),
        .tuple_count = input.tuple_count,
        .integer_index = input.integer_index,
        .integer_type = input.integer_type,
        .bounds = input.bounds,
        .special_axis_count = input.special_axis_count,
        .source_metadata_available = input.enabled,
        .evidence = if (input.enabled) .generation_ready else .source_metadata_unavailable,
    };
}
pub const campaign_table = [_]CampaignRule{
    makeCampaignRule(.{ .operation = "abs", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/abs/absf16.c", .artifact = "test/corpus/campaigns/000-abs-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x9cc93c30e4723089, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "abs", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/abs/absf.c", .artifact = "test/corpus/campaigns/001-abs-f-hard_corpus_f.zcdr", .deterministic_seed = 0xb63bf9c8e80bf025, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "abs", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/abs/abs.c", .artifact = "test/corpus/campaigns/002-abs-d-hard_corpus_d.zcdr", .deterministic_seed = 0xc16f8e21d670fdf1, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "acos", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/acos/acosf16.c", .artifact = "test/corpus/campaigns/003-acos-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xf11f3b7dd12d1372, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "acos", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/acos/acosf.c", .artifact = "test/corpus/campaigns/004-acos-f-hard_corpus_f.zcdr", .deterministic_seed = 0xd0151bf7efc09f03, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "acos", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/acos/acos.c", .artifact = "test/corpus/campaigns/005-acos-d-hard_corpus_d.zcdr", .deterministic_seed = 0x22cbad836db2492c, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "acosh", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/acosh/acoshf16.c", .artifact = "test/corpus/campaigns/006-acosh-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xd6dd273c5a23920c, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "acosh", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/acosh/acoshf.c", .artifact = "test/corpus/campaigns/007-acosh-f-hard_corpus_f.zcdr", .deterministic_seed = 0xb2f527dacd1ce717, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "acosh", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/acosh/acosh.c", .artifact = "test/corpus/campaigns/008-acosh-d-hard_corpus_d.zcdr", .deterministic_seed = 0x3c779a25baca22d3, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "acospi", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/acospi/acospif16.c", .artifact = "test/corpus/campaigns/009-acospi-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x762078469fa56e6b, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "acospi", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/acospi/acospif.c", .artifact = "test/corpus/campaigns/010-acospi-f-hard_corpus_f.zcdr", .deterministic_seed = 0xc81ed7071063f01c, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "acospi", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/acospi/acospi.c", .artifact = "test/corpus/campaigns/011-acospi-d-hard_corpus_d.zcdr", .deterministic_seed = 0x5c4500ef22e3ab2e, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "asin", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/asin/asinf16.c", .artifact = "test/corpus/campaigns/012-asin-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x8e6df0c02bddfdb8, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "asin", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/asin/asinf.c", .artifact = "test/corpus/campaigns/013-asin-f-hard_corpus_f.zcdr", .deterministic_seed = 0x7191cd10649d1b49, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "asin", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/asin/asin.c", .artifact = "test/corpus/campaigns/014-asin-d-hard_corpus_d.zcdr", .deterministic_seed = 0x21aa412388ddeda4, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "asinh", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/asinh/asinhf16.c", .artifact = "test/corpus/campaigns/015-asinh-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x9840a702da12d796, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "asinh", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/asinh/asinhf.c", .artifact = "test/corpus/campaigns/016-asinh-f-hard_corpus_f.zcdr", .deterministic_seed = 0x587687393266a029, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "asinh", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/asinh/asinh.c", .artifact = "test/corpus/campaigns/017-asinh-d-hard_corpus_d.zcdr", .deterministic_seed = 0x276b00805ef26589, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "asinpi", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/asinpi/asinpif16.c", .artifact = "test/corpus/campaigns/018-asinpi-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x1e06c81d25d11a3b, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "asinpi", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/asinpi/asinpif.c", .artifact = "test/corpus/campaigns/019-asinpi-f-hard_corpus_f.zcdr", .deterministic_seed = 0xc6d17db6d489f2f1, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "asinpi", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/asinpi/asinpi.c", .artifact = "test/corpus/campaigns/020-asinpi-d-hard_corpus_d.zcdr", .deterministic_seed = 0x34b0ea9cb436e43b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "atan", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/atan/atanf16.c", .artifact = "test/corpus/campaigns/021-atan-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x4ae1feee866ecc74, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "atan", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/atan/atanf.c", .artifact = "test/corpus/campaigns/022-atan-f-hard_corpus_f.zcdr", .deterministic_seed = 0x0771050e78743a03, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "atan", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/atan/atan.c", .artifact = "test/corpus/campaigns/023-atan-d-hard_corpus_d.zcdr", .deterministic_seed = 0xdfbbbf07d3b86707, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "atan2", .provenance = .c23_7_12, .shape_code = 0x21129, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/atan2/atan2f16.c", .artifact = "test/corpus/campaigns/024-atan2-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x271049dcc86a7572, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "atan2", .provenance = .c23_7_12, .shape_code = 0x2222a, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/atan2/atan2f.c", .artifact = "test/corpus/campaigns/025-atan2-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xacf4c349be69709a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "atan2", .provenance = .c23_7_12, .shape_code = 0x2332b, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/atan2/atan2.c", .artifact = "test/corpus/campaigns/026-atan2-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xc2bacf8377b80a29, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "atan2pi", .provenance = .c23_7_12, .shape_code = 0x21129, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/atan2pi/atan2pif16.c", .artifact = "test/corpus/campaigns/027-atan2pi-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xf1664c4cb261e41f, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "atan2pi", .provenance = .c23_7_12, .shape_code = 0x2222a, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/atan2pi/atan2pif.c", .artifact = "test/corpus/campaigns/028-atan2pi-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xe175ad80dbfae69a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "atan2pi", .provenance = .c23_7_12, .shape_code = 0x2332b, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/atan2pi/atan2pi.c", .artifact = "test/corpus/campaigns/029-atan2pi-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x6b07a76354e2fa1a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "atanh", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/atanh/atanhf16.c", .artifact = "test/corpus/campaigns/030-atanh-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x1be0ee882066fc77, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "atanh", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/atanh/atanhf.c", .artifact = "test/corpus/campaigns/031-atanh-f-hard_corpus_f.zcdr", .deterministic_seed = 0xc5133a9b4a4a0567, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "atanh", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/atanh/atanh.c", .artifact = "test/corpus/campaigns/032-atanh-d-hard_corpus_d.zcdr", .deterministic_seed = 0x180db7d468f985b7, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "atanpi", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/atanpi/atanpif16.c", .artifact = "test/corpus/campaigns/033-atanpi-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xa9fe1937f619ae37, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "atanpi", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/atanpi/atanpif.c", .artifact = "test/corpus/campaigns/034-atanpi-f-hard_corpus_f.zcdr", .deterministic_seed = 0xead73865943c74b0, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "atanpi", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/atanpi/atanpi.c", .artifact = "test/corpus/campaigns/035-atanpi-d-hard_corpus_d.zcdr", .deterministic_seed = 0x313af4fdeeefd8ee, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cbrt", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/cbrt/cbrtf16.c", .artifact = "test/corpus/campaigns/036-cbrt-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xec9ea8e0be5bb665, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "cbrt", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/cbrt/cbrtf.c", .artifact = "test/corpus/campaigns/037-cbrt-f-hard_corpus_f.zcdr", .deterministic_seed = 0x77d528a24a1df12d, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cbrt", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/cbrt/cbrt.c", .artifact = "test/corpus/campaigns/038-cbrt-d-hard_corpus_d.zcdr", .deterministic_seed = 0xfe41117fe39a947f, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "ceil", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/ceil/ceilf16.c", .artifact = "test/corpus/campaigns/039-ceil-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x9000d7f0be6ba86a, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "ceil", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/ceil/ceilf.c", .artifact = "test/corpus/campaigns/040-ceil-f-hard_corpus_f.zcdr", .deterministic_seed = 0x943e9a8238ead36c, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "ceil", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/ceil/ceil.c", .artifact = "test/corpus/campaigns/041-ceil-d-hard_corpus_d.zcdr", .deterministic_seed = 0xd79344a89305be72, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "compoundn", .provenance = .c23_7_12, .shape_code = 0x2182d, .format = .h, .campaign_class = .bounded_h_integer_domain, .source_path = "src/binary16/compoundn/compoundnf16.c", .artifact = "test/corpus/campaigns/042-compoundn-h-bounded_h_integer_domain.zcdr", .deterministic_seed = 0xcb320f2e0ad8ff37, .tuple_count = 129, .integer_index = 1, .integer_type = .i64, .bounds = .{ .signed = .{ .lower = -64, .upper = 64 } } }),
    makeCampaignRule(.{ .operation = "compoundn", .provenance = .c23_7_12, .shape_code = 0x2282e, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/compoundn/compoundnf.c", .artifact = "test/corpus/campaigns/043-compoundn-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x01b085734e6591b9, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "compoundn", .provenance = .c23_7_12, .shape_code = 0x2382f, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/compoundn/compoundn.c", .artifact = "test/corpus/campaigns/044-compoundn-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x83d3891e193b813f, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "cos", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/cos/cosf16.c", .artifact = "test/corpus/campaigns/045-cos-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x409fe11cb729512e, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "cos", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/cos/cosf.c", .artifact = "test/corpus/campaigns/046-cos-f-hard_corpus_f.zcdr", .deterministic_seed = 0xd4c4b444576041c6, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cos", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/cos/cos.c", .artifact = "test/corpus/campaigns/047-cos-d-hard_corpus_d.zcdr", .deterministic_seed = 0x37baed518faad314, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cosh", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/cosh/coshf16.c", .artifact = "test/corpus/campaigns/048-cosh-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x4638625ed6a17dd4, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "cosh", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/cosh/coshf.c", .artifact = "test/corpus/campaigns/049-cosh-f-hard_corpus_f.zcdr", .deterministic_seed = 0x316af8fa2dcdddfe, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cosh", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/cosh/cosh.c", .artifact = "test/corpus/campaigns/050-cosh-d-hard_corpus_d.zcdr", .deterministic_seed = 0xaf73a3b2932ad711, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cospi", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/cospi/cospif16.c", .artifact = "test/corpus/campaigns/051-cospi-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x8a94608f135ab32e, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "cospi", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/cospi/cospif.c", .artifact = "test/corpus/campaigns/052-cospi-f-hard_corpus_f.zcdr", .deterministic_seed = 0x91b8ec5509a65cf6, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "cospi", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/cospi/cospi.c", .artifact = "test/corpus/campaigns/053-cospi-d-hard_corpus_d.zcdr", .deterministic_seed = 0xd1d6383cf6db3850, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "erf", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/erf/erff16.c", .artifact = "test/corpus/campaigns/054-erf-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x835be8a891a3b9e3, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "erf", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/erf/erff.c", .artifact = "test/corpus/campaigns/055-erf-f-hard_corpus_f.zcdr", .deterministic_seed = 0x7eec8e41f1e508f6, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "erf", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/erf/erf.c", .artifact = "test/corpus/campaigns/056-erf-d-hard_corpus_d.zcdr", .deterministic_seed = 0x7f1ed3f48a7b8a38, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "erfc", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/erfc/erfcf16.c", .artifact = "test/corpus/campaigns/057-erfc-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x1e3037505cef176d, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "erfc", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/erfc/erfcf.c", .artifact = "test/corpus/campaigns/058-erfc-f-hard_corpus_f.zcdr", .deterministic_seed = 0x789077545e0998ca, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "erfc", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/erfc/erfc.c", .artifact = "test/corpus/campaigns/059-erfc-d-hard_corpus_d.zcdr", .deterministic_seed = 0xc9fc9717363e1119, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/exp/expf16.c", .artifact = "core-math-exp-h-exhaustive", .deterministic_seed = 0xaf682dd66990c086, .tuple_count = 65536, .status = .correct, .oracle = .mpfr_arb, .enabled = true }),
    makeCampaignRule(.{ .operation = "exp", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/exp/expf.c", .artifact = "core-math-exp-f-hard", .deterministic_seed = 0xc5a121bf3015c608, .tuple_count = 256, .status = .correct, .oracle = .mpfr_arb, .enabled = true }),
    makeCampaignRule(.{ .operation = "exp", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/exp/exp.c", .artifact = "core-math-exp-d-hard", .deterministic_seed = 0xf9b3ebcb07eb597b, .tuple_count = 256, .status = .correct, .oracle = .mpfr_arb, .enabled = true }),
    makeCampaignRule(.{ .operation = "exp10", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/exp10/exp10f16.c", .artifact = "test/corpus/campaigns/063-exp10-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x53e18ef91cb1e3ff, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "exp10", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/exp10/exp10f.c", .artifact = "test/corpus/campaigns/064-exp10-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa721555aa5a26fc8, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp10", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/exp10/exp10.c", .artifact = "test/corpus/campaigns/065-exp10-d-hard_corpus_d.zcdr", .deterministic_seed = 0x7838ee7619027f66, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp10m1", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/exp10m1/exp10m1f16.c", .artifact = "test/corpus/campaigns/066-exp10m1-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xde346b6ea3734a89, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "exp10m1", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/exp10m1/exp10m1f.c", .artifact = "test/corpus/campaigns/067-exp10m1-f-hard_corpus_f.zcdr", .deterministic_seed = 0x79f61c5a6a82ae2b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp10m1", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/exp10m1/exp10m1.c", .artifact = "test/corpus/campaigns/068-exp10m1-d-hard_corpus_d.zcdr", .deterministic_seed = 0xdd6b28aa2bdb9fd8, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp2", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/exp2/exp2f16.c", .artifact = "test/corpus/campaigns/069-exp2-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x4b0e0787e6a50c77, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "exp2", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/exp2/exp2f.c", .artifact = "test/corpus/campaigns/070-exp2-f-hard_corpus_f.zcdr", .deterministic_seed = 0x950fba5d36b16a7d, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp2", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/exp2/exp2.c", .artifact = "test/corpus/campaigns/071-exp2-d-hard_corpus_d.zcdr", .deterministic_seed = 0x97901e3a21e2929f, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp2m1", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/exp2m1/exp2m1f16.c", .artifact = "test/corpus/campaigns/072-exp2m1-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xa9c13c5b7803b51f, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "exp2m1", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/exp2m1/exp2m1f.c", .artifact = "test/corpus/campaigns/073-exp2m1-f-hard_corpus_f.zcdr", .deterministic_seed = 0xd60449d243717f6b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "exp2m1", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/exp2m1/exp2m1.c", .artifact = "test/corpus/campaigns/074-exp2m1-d-hard_corpus_d.zcdr", .deterministic_seed = 0xe09ea4d31ea1175c, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "expm1", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/expm1/expm1f16.c", .artifact = "test/corpus/campaigns/075-expm1-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xc7c3636469c099e2, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "expm1", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/expm1/expm1f.c", .artifact = "test/corpus/campaigns/076-expm1-f-hard_corpus_f.zcdr", .deterministic_seed = 0xd4ae4fc39ae2e49b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "expm1", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/expm1/expm1.c", .artifact = "test/corpus/campaigns/077-expm1-d-hard_corpus_d.zcdr", .deterministic_seed = 0x30658e78834a3f2d, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "fadd", .provenance = .c23_7_12, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fadd/fadd.c", .artifact = "test/corpus/campaigns/078-fadd-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xad74f381c05c7b81, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fdim", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fdim/fdimf16.c", .artifact = "test/corpus/campaigns/079-fdim-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x6ef48ef2ce1ebf7e, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fdim", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fdim/fdimf.c", .artifact = "test/corpus/campaigns/080-fdim-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xc89fd63fe88dfaf1, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fdim", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fdim/fdim.c", .artifact = "test/corpus/campaigns/081-fdim-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2f8f90c80405e045, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fdiv", .provenance = .c23_7_12, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fdiv/fdiv.c", .artifact = "test/corpus/campaigns/082-fdiv-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x821b28e7cc2f29df, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "ffma", .provenance = .c23_7_12, .shape_code = 0x333302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/ffma/ffma.c", .artifact = "test/corpus/campaigns/083-ffma-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x1a9be82bb43183b7, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "floor", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/floor/floorf16.c", .artifact = "test/corpus/campaigns/084-floor-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x50e083e505d0186e, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "floor", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/floor/floorf.c", .artifact = "test/corpus/campaigns/085-floor-f-hard_corpus_f.zcdr", .deterministic_seed = 0x531c512163b96542, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "floor", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/floor/floor.c", .artifact = "test/corpus/campaigns/086-floor-d-hard_corpus_d.zcdr", .deterministic_seed = 0x7b6fbdb0e630c5d0, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "fma", .provenance = .c23_7_12, .shape_code = 0x311101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fma/fmaf16.c", .artifact = "test/corpus/campaigns/087-fma-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x19836a75877fbbc2, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fma", .provenance = .c23_7_12, .shape_code = 0x322202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fma/fmaf.c", .artifact = "test/corpus/campaigns/088-fma-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2ea9b2c74478346c, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fma", .provenance = .c23_7_12, .shape_code = 0x333303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fma/fma.c", .artifact = "test/corpus/campaigns/089-fma-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xbb75fec3832c1532, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fmax", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmax/fmaxf16.c", .artifact = "test/corpus/campaigns/090-fmax-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x295b0d5d3c64573b, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmax", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmax/fmaxf.c", .artifact = "test/corpus/campaigns/091-fmax-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xa1184cfba7f3b886, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmax", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmax/fmax.c", .artifact = "test/corpus/campaigns/092-fmax-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xe93d54dd86c270c4, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmaximum/fmaximumf16.c", .artifact = "test/corpus/campaigns/093-fmaximum-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x9cd869444cc214fa, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmaximum/fmaximumf.c", .artifact = "test/corpus/campaigns/094-fmaximum-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xada08280c2906a8b, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmaximum/fmaximum.c", .artifact = "test/corpus/campaigns/095-fmaximum-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x81b25dad69ca19f1, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_mag", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmaximum_mag/fmaximum_magf16.c", .artifact = "test/corpus/campaigns/096-fmaximum_mag-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x67f1dce3c00e7179, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_mag", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmaximum_mag/fmaximum_magf.c", .artifact = "test/corpus/campaigns/097-fmaximum_mag-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x4cf9cba63d1c0603, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_mag", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmaximum_mag/fmaximum_mag.c", .artifact = "test/corpus/campaigns/098-fmaximum_mag-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x81c48164cf439bac, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_mag_num", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmaximum_mag_num/fmaximum_mag_numf16.c", .artifact = "test/corpus/campaigns/099-fmaximum_mag_num-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xb885fd5453fb21c5, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_mag_num", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmaximum_mag_num/fmaximum_mag_numf.c", .artifact = "test/corpus/campaigns/100-fmaximum_mag_num-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xc73f1837eb687c4a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_mag_num", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmaximum_mag_num/fmaximum_mag_num.c", .artifact = "test/corpus/campaigns/101-fmaximum_mag_num-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x923fafee616d8b50, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_num", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmaximum_num/fmaximum_numf16.c", .artifact = "test/corpus/campaigns/102-fmaximum_num-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x28584cdaae039eaf, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_num", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmaximum_num/fmaximum_numf.c", .artifact = "test/corpus/campaigns/103-fmaximum_num-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x924e7ad57b3a39df, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmaximum_num", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmaximum_num/fmaximum_num.c", .artifact = "test/corpus/campaigns/104-fmaximum_num-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xa7d1d164b360a3b2, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmin", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmin/fminf16.c", .artifact = "test/corpus/campaigns/105-fmin-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2387b0c5ff0c6c72, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmin", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmin/fminf.c", .artifact = "test/corpus/campaigns/106-fmin-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xfcecf2a1d6310b51, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmin", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmin/fmin.c", .artifact = "test/corpus/campaigns/107-fmin-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x4a85f798ef87e939, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fminimum/fminimumf16.c", .artifact = "test/corpus/campaigns/108-fminimum-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xeae945e8cc13b470, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fminimum/fminimumf.c", .artifact = "test/corpus/campaigns/109-fminimum-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x9079fa17f7e8622f, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fminimum/fminimum.c", .artifact = "test/corpus/campaigns/110-fminimum-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x0c6614adc62132f1, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_mag", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fminimum_mag/fminimum_magf16.c", .artifact = "test/corpus/campaigns/111-fminimum_mag-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x9584781e40b7322e, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_mag", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fminimum_mag/fminimum_magf.c", .artifact = "test/corpus/campaigns/112-fminimum_mag-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xce77f12188537676, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_mag", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fminimum_mag/fminimum_mag.c", .artifact = "test/corpus/campaigns/113-fminimum_mag-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x68838d13ba3e6083, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_mag_num", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fminimum_mag_num/fminimum_mag_numf16.c", .artifact = "test/corpus/campaigns/114-fminimum_mag_num-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x0abacdc0b76d6d33, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_mag_num", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fminimum_mag_num/fminimum_mag_numf.c", .artifact = "test/corpus/campaigns/115-fminimum_mag_num-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x3738c1a45c0ce502, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_mag_num", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fminimum_mag_num/fminimum_mag_num.c", .artifact = "test/corpus/campaigns/116-fminimum_mag_num-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xea99155fd03cebb7, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_num", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fminimum_num/fminimum_numf16.c", .artifact = "test/corpus/campaigns/117-fminimum_num-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x8768e21f7a352e9f, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_num", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fminimum_num/fminimum_numf.c", .artifact = "test/corpus/campaigns/118-fminimum_num-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xf9b153d334f6a96b, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fminimum_num", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fminimum_num/fminimum_num.c", .artifact = "test/corpus/campaigns/119-fminimum_num-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x068db97f5a2ae4a3, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmod", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fmod/fmodf16.c", .artifact = "test/corpus/campaigns/120-fmod-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xcdb8a3c35ed48868, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmod", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fmod/fmodf.c", .artifact = "test/corpus/campaigns/121-fmod-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xf95030306b2033f2, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmod", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmod/fmod.c", .artifact = "test/corpus/campaigns/122-fmod-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xee9d3e916e3f372e, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "fmul", .provenance = .c23_7_12, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fmul/fmul.c", .artifact = "test/corpus/campaigns/123-fmul-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xc8a0546b5c8b6099, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "frexp", .provenance = .c23_7_12, .shape_code = 0x1115, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/frexp/frexpf16.c", .artifact = "test/corpus/campaigns/124-frexp-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x8182e896c5c6e5f2, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "frexp", .provenance = .c23_7_12, .shape_code = 0x1216, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/frexp/frexpf.c", .artifact = "test/corpus/campaigns/125-frexp-f-hard_corpus_f.zcdr", .deterministic_seed = 0xe1047f0d9ab67771, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "frexp", .provenance = .c23_7_12, .shape_code = 0x1317, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/frexp/frexp.c", .artifact = "test/corpus/campaigns/126-frexp-d-hard_corpus_d.zcdr", .deterministic_seed = 0x88a331dfaddbd24e, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "fromfp", .provenance = .c23_7_12, .shape_code = 0x31eb01, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fromfp/fromfpf16.c", .artifact = "test/corpus/campaigns/127-fromfp-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x7aa3792611c73851, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fromfp", .provenance = .c23_7_12, .shape_code = 0x32eb02, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fromfp/fromfpf.c", .artifact = "test/corpus/campaigns/128-fromfp-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2695ad433aeb6147, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fromfp", .provenance = .c23_7_12, .shape_code = 0x33eb03, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fromfp/fromfp.c", .artifact = "test/corpus/campaigns/129-fromfp-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xd7da7dd67206261b, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fromfpx", .provenance = .c23_7_12, .shape_code = 0x31eb01, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/fromfpx/fromfpxf16.c", .artifact = "test/corpus/campaigns/130-fromfpx-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xbb131263703ec154, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fromfpx", .provenance = .c23_7_12, .shape_code = 0x32eb02, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/fromfpx/fromfpxf.c", .artifact = "test/corpus/campaigns/131-fromfpx-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2c0a8fc534e3103e, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fromfpx", .provenance = .c23_7_12, .shape_code = 0x33eb03, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fromfpx/fromfpx.c", .artifact = "test/corpus/campaigns/132-fromfpx-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x12ac219d1684fcda, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "fsqrt", .provenance = .c23_7_12, .shape_code = 0x1302, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/fsqrt/fsqrt.c", .artifact = "test/corpus/campaigns/133-fsqrt-d-hard_corpus_d.zcdr", .deterministic_seed = 0x5a856f9c038bcadf, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "fsub", .provenance = .c23_7_12, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/fsub/fsub.c", .artifact = "test/corpus/campaigns/134-fsub-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x0df3d7e4935f12dc, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "hypot", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/hypot/hypotf16.c", .artifact = "test/corpus/campaigns/135-hypot-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x403c500e51d2da5d, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "hypot", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/hypot/hypotf.c", .artifact = "test/corpus/campaigns/136-hypot-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xf5c97fef5b702ac3, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "hypot", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/hypot/hypot.c", .artifact = "test/corpus/campaigns/137-hypot-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x60fbf1237352afc4, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "ilogb", .provenance = .c23_7_12, .shape_code = 0x1107, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/ilogb/ilogbf16.c", .artifact = "test/corpus/campaigns/138-ilogb-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x0938c0fd01c19c0c, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "ilogb", .provenance = .c23_7_12, .shape_code = 0x1207, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/ilogb/ilogbf.c", .artifact = "test/corpus/campaigns/139-ilogb-f-hard_corpus_f.zcdr", .deterministic_seed = 0x1e9d5b47e5f74060, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "ilogb", .provenance = .c23_7_12, .shape_code = 0x1307, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/ilogb/ilogb.c", .artifact = "test/corpus/campaigns/140-ilogb-d-hard_corpus_d.zcdr", .deterministic_seed = 0xe1c881f34421d654, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "ldexp", .provenance = .c23_7_12, .shape_code = 0x21701, .format = .h, .campaign_class = .bounded_h_integer_domain, .source_path = "src/binary16/ldexp/ldexpf16.c", .artifact = "test/corpus/campaigns/141-ldexp-h-bounded_h_integer_domain.zcdr", .deterministic_seed = 0xbd5b8595dff13ea1, .tuple_count = 129, .integer_index = 1, .integer_type = .i32, .bounds = .{ .signed = .{ .lower = -64, .upper = 64 } } }),
    makeCampaignRule(.{ .operation = "ldexp", .provenance = .c23_7_12, .shape_code = 0x22702, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/ldexp/ldexpf.c", .artifact = "test/corpus/campaigns/142-ldexp-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xb624b4b877284938, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "ldexp", .provenance = .c23_7_12, .shape_code = 0x23703, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/ldexp/ldexp.c", .artifact = "test/corpus/campaigns/143-ldexp-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x57f59ef5774a9688, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "lgamma", .provenance = .c23_7_12, .shape_code = 0x1121, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/lgamma/lgammaf16.c", .artifact = "test/corpus/campaigns/144-lgamma-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x2bc3a3888d1ad154, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "lgamma", .provenance = .c23_7_12, .shape_code = 0x1222, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/lgamma/lgammaf.c", .artifact = "test/corpus/campaigns/145-lgamma-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa308b189ec89a9d5, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "lgamma", .provenance = .c23_7_12, .shape_code = 0x1323, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/lgamma/lgamma.c", .artifact = "test/corpus/campaigns/146-lgamma-d-hard_corpus_d.zcdr", .deterministic_seed = 0xbc55a646c0e9c4ea, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "llogb", .provenance = .c23_7_12, .shape_code = 0x1108, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/llogb/llogbf16.c", .artifact = "test/corpus/campaigns/147-llogb-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xe7a99ad0e1ef9bb8, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "llogb", .provenance = .c23_7_12, .shape_code = 0x1208, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/llogb/llogbf.c", .artifact = "test/corpus/campaigns/148-llogb-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa9aa489f9884fccc, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "llogb", .provenance = .c23_7_12, .shape_code = 0x1308, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/llogb/llogb.c", .artifact = "test/corpus/campaigns/149-llogb-d-hard_corpus_d.zcdr", .deterministic_seed = 0xe7089cce82c6423b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "llrint", .provenance = .c23_7_12, .shape_code = 0x1131, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/llrint/llrintf16.c", .artifact = "test/corpus/campaigns/150-llrint-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xfcd61f5b990d6918, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "llrint", .provenance = .c23_7_12, .shape_code = 0x1232, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/llrint/llrintf.c", .artifact = "test/corpus/campaigns/151-llrint-f-hard_corpus_f.zcdr", .deterministic_seed = 0x98217e702b112706, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "llrint", .provenance = .c23_7_12, .shape_code = 0x1333, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/llrint/llrint.c", .artifact = "test/corpus/campaigns/152-llrint-d-hard_corpus_d.zcdr", .deterministic_seed = 0x528fc7b796751688, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "llround", .provenance = .c23_7_12, .shape_code = 0x1131, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/llround/llroundf16.c", .artifact = "test/corpus/campaigns/153-llround-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xc5b49bd0af67cb72, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "llround", .provenance = .c23_7_12, .shape_code = 0x1232, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/llround/llroundf.c", .artifact = "test/corpus/campaigns/154-llround-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa79f64d669754961, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "llround", .provenance = .c23_7_12, .shape_code = 0x1333, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/llround/llround.c", .artifact = "test/corpus/campaigns/155-llround-d-hard_corpus_d.zcdr", .deterministic_seed = 0x7a107a722b99fc67, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/log/logf16.c", .artifact = "core-math-log-h-exhaustive", .deterministic_seed = 0x5e6d7f315b292aa9, .tuple_count = 65536, .status = .correct, .oracle = .mpfr_arb, .enabled = true }),
    makeCampaignRule(.{ .operation = "log", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/log/logf.c", .artifact = "test/corpus/campaigns/157-log-f-hard_corpus_f.zcdr", .deterministic_seed = 0x3cae8ed5a9487840, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/log/log.c", .artifact = "test/corpus/campaigns/158-log-d-hard_corpus_d.zcdr", .deterministic_seed = 0x00db6fcf9cfff19d, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log10", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/log10/log10f16.c", .artifact = "test/corpus/campaigns/159-log10-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xf578efcac898c6f8, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "log10", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/log10/log10f.c", .artifact = "test/corpus/campaigns/160-log10-f-hard_corpus_f.zcdr", .deterministic_seed = 0x317acc1296e87a90, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log10", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/log10/log10.c", .artifact = "test/corpus/campaigns/161-log10-d-hard_corpus_d.zcdr", .deterministic_seed = 0x6a5ac32ec733a169, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log10p1", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/log10p1/log10p1f16.c", .artifact = "test/corpus/campaigns/162-log10p1-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x2a5b302d9c346f30, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "log10p1", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/log10p1/log10p1f.c", .artifact = "test/corpus/campaigns/163-log10p1-f-hard_corpus_f.zcdr", .deterministic_seed = 0xac26d295dc173270, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log10p1", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/log10p1/log10p1.c", .artifact = "test/corpus/campaigns/164-log10p1-d-hard_corpus_d.zcdr", .deterministic_seed = 0x2d13a598ea9ce291, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log1p", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/log1p/log1pf16.c", .artifact = "test/corpus/campaigns/165-log1p-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xace62f1bcc8d8144, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "log1p", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/log1p/log1pf.c", .artifact = "test/corpus/campaigns/166-log1p-f-hard_corpus_f.zcdr", .deterministic_seed = 0xc09ebaa19173fb97, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log1p", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/log1p/log1p.c", .artifact = "test/corpus/campaigns/167-log1p-d-hard_corpus_d.zcdr", .deterministic_seed = 0x429fa8746a1a1576, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log2", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/log2/log2f16.c", .artifact = "test/corpus/campaigns/168-log2-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xe991bd432b1fc25f, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "log2", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/log2/log2f.c", .artifact = "test/corpus/campaigns/169-log2-f-hard_corpus_f.zcdr", .deterministic_seed = 0x5a34495f5cb4e466, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log2", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/log2/log2.c", .artifact = "test/corpus/campaigns/170-log2-d-hard_corpus_d.zcdr", .deterministic_seed = 0xe1bd795fe8c5fdd1, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log2p1", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/log2p1/log2p1f16.c", .artifact = "test/corpus/campaigns/171-log2p1-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xba891a6503f5f30c, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "log2p1", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/log2p1/log2p1f.c", .artifact = "test/corpus/campaigns/172-log2p1-f-hard_corpus_f.zcdr", .deterministic_seed = 0x55208114b29b7666, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "log2p1", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/log2p1/log2p1.c", .artifact = "test/corpus/campaigns/173-log2p1-d-hard_corpus_d.zcdr", .deterministic_seed = 0xb8ad720a0d434515, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "logb", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/logb/logbf16.c", .artifact = "test/corpus/campaigns/174-logb-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xfb9550e50a2a902d, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "logb", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/logb/logbf.c", .artifact = "test/corpus/campaigns/175-logb-f-hard_corpus_f.zcdr", .deterministic_seed = 0x8080f53eb5cbf53f, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "logb", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/logb/logb.c", .artifact = "test/corpus/campaigns/176-logb-d-hard_corpus_d.zcdr", .deterministic_seed = 0x55e3fa1a3e64ea9d, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "logp1", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/logp1/logp1f16.c", .artifact = "test/corpus/campaigns/177-logp1-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x26c0d87e70cc0059, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "logp1", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/logp1/logp1f.c", .artifact = "test/corpus/campaigns/178-logp1-f-hard_corpus_f.zcdr", .deterministic_seed = 0x7bd7c0fe7d9fd3f3, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "logp1", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/logp1/logp1.c", .artifact = "test/corpus/campaigns/179-logp1-d-hard_corpus_d.zcdr", .deterministic_seed = 0x47842108fea8ce95, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "lrint", .provenance = .c23_7_12, .shape_code = 0x1131, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/lrint/lrintf16.c", .artifact = "test/corpus/campaigns/180-lrint-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xbefec6abbdfd9190, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "lrint", .provenance = .c23_7_12, .shape_code = 0x1232, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/lrint/lrintf.c", .artifact = "test/corpus/campaigns/181-lrint-f-hard_corpus_f.zcdr", .deterministic_seed = 0xc03734123248105d, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "lrint", .provenance = .c23_7_12, .shape_code = 0x1333, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/lrint/lrint.c", .artifact = "test/corpus/campaigns/182-lrint-d-hard_corpus_d.zcdr", .deterministic_seed = 0x18b6580056da1783, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "lround", .provenance = .c23_7_12, .shape_code = 0x1131, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/lround/lroundf16.c", .artifact = "test/corpus/campaigns/183-lround-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x115f9f768812fcc3, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "lround", .provenance = .c23_7_12, .shape_code = 0x1232, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/lround/lroundf.c", .artifact = "test/corpus/campaigns/184-lround-f-hard_corpus_f.zcdr", .deterministic_seed = 0x7fe3cd1e5e989783, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "lround", .provenance = .c23_7_12, .shape_code = 0x1333, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/lround/lround.c", .artifact = "test/corpus/campaigns/185-lround-d-hard_corpus_d.zcdr", .deterministic_seed = 0x5d0a0ba5127726c2, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "modf", .provenance = .c23_7_12, .shape_code = 0x1119, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/modf/modff16.c", .artifact = "test/corpus/campaigns/186-modf-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xdcb4ce2c8f8c1d45, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "modf", .provenance = .c23_7_12, .shape_code = 0x121a, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/modf/modff.c", .artifact = "test/corpus/campaigns/187-modf-f-hard_corpus_f.zcdr", .deterministic_seed = 0xb559bbf376a4e9ca, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "modf", .provenance = .c23_7_12, .shape_code = 0x131b, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/modf/modf.c", .artifact = "test/corpus/campaigns/188-modf-d-hard_corpus_d.zcdr", .deterministic_seed = 0xc8b727f54601bccb, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "nearbyint", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/nearbyint/nearbyintf16.c", .artifact = "test/corpus/campaigns/189-nearbyint-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x0968cc7751cd8125, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "nearbyint", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/nearbyint/nearbyintf.c", .artifact = "test/corpus/campaigns/190-nearbyint-f-hard_corpus_f.zcdr", .deterministic_seed = 0x5415843cbfafa4f1, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "nearbyint", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/nearbyint/nearbyint.c", .artifact = "test/corpus/campaigns/191-nearbyint-d-hard_corpus_d.zcdr", .deterministic_seed = 0x4fe7851b36a0ea22, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "pow", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/pow/powf16.c", .artifact = "test/corpus/campaigns/192-pow-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x08e0103284dcbebe, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "pow", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/pow/powf.c", .artifact = "test/corpus/campaigns/193-pow-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x6c7d1813523f437a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "pow", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/pow/pow.c", .artifact = "test/corpus/campaigns/194-pow-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x285ede40bc81a355, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "pown", .provenance = .c23_7_12, .shape_code = 0x2182d, .format = .h, .campaign_class = .bounded_h_integer_domain, .source_path = "src/binary16/pown/pownf16.c", .artifact = "test/corpus/campaigns/195-pown-h-bounded_h_integer_domain.zcdr", .deterministic_seed = 0xb67ff5381d0498b5, .tuple_count = 129, .integer_index = 1, .integer_type = .i64, .bounds = .{ .signed = .{ .lower = -64, .upper = 64 } } }),
    makeCampaignRule(.{ .operation = "pown", .provenance = .c23_7_12, .shape_code = 0x2282e, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/pown/pownf.c", .artifact = "test/corpus/campaigns/196-pown-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xb7a469abc31b51d5, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "pown", .provenance = .c23_7_12, .shape_code = 0x2382f, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/pown/pown.c", .artifact = "test/corpus/campaigns/197-pown-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xd3acb859586e2515, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "powr", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/powr/powrf16.c", .artifact = "test/corpus/campaigns/198-powr-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xcb06f61c91d86756, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "powr", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/powr/powrf.c", .artifact = "test/corpus/campaigns/199-powr-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x5de328f8407b7645, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "powr", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/powr/powr.c", .artifact = "test/corpus/campaigns/200-powr-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x1856685eff4bf1c4, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "remainder", .provenance = .c23_7_12, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/remainder/remainderf16.c", .artifact = "test/corpus/campaigns/201-remainder-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x1f00b76d25101aec, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "remainder", .provenance = .c23_7_12, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/remainder/remainderf.c", .artifact = "test/corpus/campaigns/202-remainder-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2ba9888040434124, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "remainder", .provenance = .c23_7_12, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/remainder/remainder.c", .artifact = "test/corpus/campaigns/203-remainder-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x3bd5fcb0acdf911d, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "remquo", .provenance = .c23_7_12, .shape_code = 0x2111d, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/remquo/remquof16.c", .artifact = "test/corpus/campaigns/204-remquo-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xde52148eee79e9e2, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "remquo", .provenance = .c23_7_12, .shape_code = 0x2221e, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/remquo/remquof.c", .artifact = "test/corpus/campaigns/205-remquo-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xac48d6c2137407b1, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "remquo", .provenance = .c23_7_12, .shape_code = 0x2331f, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/remquo/remquo.c", .artifact = "test/corpus/campaigns/206-remquo-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x11d345b45e8a3cdf, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "rint", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/rint/rintf16.c", .artifact = "test/corpus/campaigns/207-rint-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x717eb3eb55161ab6, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "rint", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/rint/rintf.c", .artifact = "test/corpus/campaigns/208-rint-f-hard_corpus_f.zcdr", .deterministic_seed = 0x47b0ffdebb0a0d00, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "rint", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/rint/rint.c", .artifact = "test/corpus/campaigns/209-rint-d-hard_corpus_d.zcdr", .deterministic_seed = 0x9a735b2f377a9c86, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "rootn", .provenance = .c23_7_12, .shape_code = 0x2182d, .format = .h, .campaign_class = .bounded_h_integer_domain, .source_path = "src/binary16/rootn/rootnf16.c", .artifact = "test/corpus/campaigns/210-rootn-h-bounded_h_integer_domain.zcdr", .deterministic_seed = 0x9300653685ec5dcd, .tuple_count = 129, .integer_index = 1, .integer_type = .i64, .bounds = .{ .signed = .{ .lower = -64, .upper = 64 } } }),
    makeCampaignRule(.{ .operation = "rootn", .provenance = .c23_7_12, .shape_code = 0x2282e, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/rootn/rootnf.c", .artifact = "test/corpus/campaigns/211-rootn-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x66f9ce2c6ed9b70a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "rootn", .provenance = .c23_7_12, .shape_code = 0x2382f, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/rootn/rootn.c", .artifact = "test/corpus/campaigns/212-rootn-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x8d6e6685cd5e1e44, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "round", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/round/roundf16.c", .artifact = "test/corpus/campaigns/213-round-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x63b112c69410abfc, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "round", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/round/roundf.c", .artifact = "test/corpus/campaigns/214-round-f-hard_corpus_f.zcdr", .deterministic_seed = 0x650d503996baf5ba, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "round", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/round/round.c", .artifact = "test/corpus/campaigns/215-round-d-hard_corpus_d.zcdr", .deterministic_seed = 0x602ef9120a66a5d0, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "roundeven", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/roundeven/roundevenf16.c", .artifact = "test/corpus/campaigns/216-roundeven-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x116a357784fa150f, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "roundeven", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/roundeven/roundevenf.c", .artifact = "test/corpus/campaigns/217-roundeven-f-hard_corpus_f.zcdr", .deterministic_seed = 0xc4e96b87b7ffbba7, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "roundeven", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/roundeven/roundeven.c", .artifact = "test/corpus/campaigns/218-roundeven-d-hard_corpus_d.zcdr", .deterministic_seed = 0x2d55828d9bc9ce68, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "rsqrt", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/rsqrt/rsqrtf16.c", .artifact = "test/corpus/campaigns/219-rsqrt-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xe8ed34c404d309be, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "rsqrt", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/rsqrt/rsqrtf.c", .artifact = "test/corpus/campaigns/220-rsqrt-f-hard_corpus_f.zcdr", .deterministic_seed = 0x6fe2e4b98d42b8a9, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "rsqrt", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/rsqrt/rsqrt.c", .artifact = "test/corpus/campaigns/221-rsqrt-d-hard_corpus_d.zcdr", .deterministic_seed = 0x0e83674a2580358b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "scalbln", .provenance = .c23_7_12, .shape_code = 0x21801, .format = .h, .campaign_class = .bounded_h_integer_domain, .source_path = "src/binary16/scalbln/scalblnf16.c", .artifact = "test/corpus/campaigns/222-scalbln-h-bounded_h_integer_domain.zcdr", .deterministic_seed = 0x760a615990527b17, .tuple_count = 129, .integer_index = 1, .integer_type = .i64, .bounds = .{ .signed = .{ .lower = -64, .upper = 64 } } }),
    makeCampaignRule(.{ .operation = "scalbln", .provenance = .c23_7_12, .shape_code = 0x22802, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/scalbln/scalblnf.c", .artifact = "test/corpus/campaigns/223-scalbln-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x873da4110781ff16, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "scalbln", .provenance = .c23_7_12, .shape_code = 0x23803, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/scalbln/scalbln.c", .artifact = "test/corpus/campaigns/224-scalbln-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x11fb71967f1a7a0c, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "scalbn", .provenance = .c23_7_12, .shape_code = 0x21701, .format = .h, .campaign_class = .bounded_h_integer_domain, .source_path = "src/binary16/scalbn/scalbnf16.c", .artifact = "test/corpus/campaigns/225-scalbn-h-bounded_h_integer_domain.zcdr", .deterministic_seed = 0x3fad060b803ee14a, .tuple_count = 129, .integer_index = 1, .integer_type = .i32, .bounds = .{ .signed = .{ .lower = -64, .upper = 64 } } }),
    makeCampaignRule(.{ .operation = "scalbn", .provenance = .c23_7_12, .shape_code = 0x22702, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/scalbn/scalbnf.c", .artifact = "test/corpus/campaigns/226-scalbn-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x386b5016ef937bdf, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "scalbn", .provenance = .c23_7_12, .shape_code = 0x23703, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/scalbn/scalbn.c", .artifact = "test/corpus/campaigns/227-scalbn-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x8505b18eaa792f50, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "sin", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/sin/sinf16.c", .artifact = "core-math-sin-h-exhaustive", .deterministic_seed = 0xfdf1593c4843d73e, .tuple_count = 65536, .status = .correct, .oracle = .mpfr_arb, .enabled = true }),
    makeCampaignRule(.{ .operation = "sin", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/sin/sinf.c", .artifact = "test/corpus/campaigns/229-sin-f-hard_corpus_f.zcdr", .deterministic_seed = 0x01d918c0edd13d39, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sin", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/sin/sin.c", .artifact = "test/corpus/campaigns/230-sin-d-hard_corpus_d.zcdr", .deterministic_seed = 0x3748f53d4c12e7ee, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sinh", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/sinh/sinhf16.c", .artifact = "test/corpus/campaigns/231-sinh-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x191323b4ad74a7fb, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "sinh", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/sinh/sinhf.c", .artifact = "test/corpus/campaigns/232-sinh-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa3653b0f01b2de2a, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sinh", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/sinh/sinh.c", .artifact = "test/corpus/campaigns/233-sinh-d-hard_corpus_d.zcdr", .deterministic_seed = 0x595880ba26615242, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sinpi", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/sinpi/sinpif16.c", .artifact = "test/corpus/campaigns/234-sinpi-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x2c006328c7cf4603, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "sinpi", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/sinpi/sinpif.c", .artifact = "test/corpus/campaigns/235-sinpi-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa55ace1e23e84e9e, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sinpi", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/sinpi/sinpi.c", .artifact = "test/corpus/campaigns/236-sinpi-d-hard_corpus_d.zcdr", .deterministic_seed = 0x21a85888294ff3ae, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sqrt", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/sqrt/sqrtf16.c", .artifact = "test/corpus/campaigns/237-sqrt-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x06037e4a99c4799c, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "sqrt", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/sqrt/sqrtf.c", .artifact = "test/corpus/campaigns/238-sqrt-f-hard_corpus_f.zcdr", .deterministic_seed = 0x5ea27a71a8b96ac6, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "sqrt", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/sqrt/sqrt.c", .artifact = "test/corpus/campaigns/239-sqrt-d-hard_corpus_d.zcdr", .deterministic_seed = 0x5ca04da97d0f4ddd, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tan", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/tan/tanf16.c", .artifact = "test/corpus/campaigns/240-tan-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xeb0f4652bfd77ca5, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "tan", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/tan/tanf.c", .artifact = "test/corpus/campaigns/241-tan-f-hard_corpus_f.zcdr", .deterministic_seed = 0x71637fcf734595a8, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tan", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/tan/tan.c", .artifact = "test/corpus/campaigns/242-tan-d-hard_corpus_d.zcdr", .deterministic_seed = 0xa8140fbb6bc67055, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tanh", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/tanh/tanhf16.c", .artifact = "test/corpus/campaigns/243-tanh-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xc0ff611ffd1a9c07, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "tanh", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/tanh/tanhf.c", .artifact = "test/corpus/campaigns/244-tanh-f-hard_corpus_f.zcdr", .deterministic_seed = 0x7a9480fb4183b940, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tanh", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/tanh/tanh.c", .artifact = "test/corpus/campaigns/245-tanh-d-hard_corpus_d.zcdr", .deterministic_seed = 0xeae4a271e22786f5, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tanpi", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/tanpi/tanpif16.c", .artifact = "test/corpus/campaigns/246-tanpi-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0xf708940310e4a11b, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "tanpi", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/tanpi/tanpif.c", .artifact = "test/corpus/campaigns/247-tanpi-f-hard_corpus_f.zcdr", .deterministic_seed = 0xf3969e74627cefe1, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tanpi", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/tanpi/tanpi.c", .artifact = "test/corpus/campaigns/248-tanpi-d-hard_corpus_d.zcdr", .deterministic_seed = 0x530c16fa490b75c8, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tgamma", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/tgamma/tgammaf16.c", .artifact = "test/corpus/campaigns/249-tgamma-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x6cd2750afe7f5f25, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "tgamma", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/tgamma/tgammaf.c", .artifact = "test/corpus/campaigns/250-tgamma-f-hard_corpus_f.zcdr", .deterministic_seed = 0x0f5beb3088c49ba7, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "tgamma", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/tgamma/tgamma.c", .artifact = "test/corpus/campaigns/251-tgamma-d-hard_corpus_d.zcdr", .deterministic_seed = 0xfe1d2053ce12a60a, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "trunc", .provenance = .c23_7_12, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/binary16/trunc/truncf16.c", .artifact = "test/corpus/campaigns/252-trunc-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x9e775825f1d5e93a, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "trunc", .provenance = .c23_7_12, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/binary32/trunc/truncf.c", .artifact = "test/corpus/campaigns/253-trunc-f-hard_corpus_f.zcdr", .deterministic_seed = 0x096fb8646e2e1c27, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "trunc", .provenance = .c23_7_12, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/binary64/trunc/trunc.c", .artifact = "test/corpus/campaigns/254-trunc-d-hard_corpus_d.zcdr", .deterministic_seed = 0xfd7d33a76d29cb96, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "ufromfp", .provenance = .c23_7_12, .shape_code = 0x31eb01, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/ufromfp/ufromfpf16.c", .artifact = "test/corpus/campaigns/255-ufromfp-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xe13e4f72e4f37788, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "ufromfp", .provenance = .c23_7_12, .shape_code = 0x32eb02, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/ufromfp/ufromfpf.c", .artifact = "test/corpus/campaigns/256-ufromfp-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xd085761fc8917af5, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "ufromfp", .provenance = .c23_7_12, .shape_code = 0x33eb03, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/ufromfp/ufromfp.c", .artifact = "test/corpus/campaigns/257-ufromfp-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xf6cec7222397a8ef, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "ufromfpx", .provenance = .c23_7_12, .shape_code = 0x31eb01, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary16/ufromfpx/ufromfpxf16.c", .artifact = "test/corpus/campaigns/258-ufromfpx-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x9db8f269a9bc7613, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "ufromfpx", .provenance = .c23_7_12, .shape_code = 0x32eb02, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary32/ufromfpx/ufromfpxf.c", .artifact = "test/corpus/campaigns/259-ufromfpx-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xae9d626739bca517, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "ufromfpx", .provenance = .c23_7_12, .shape_code = 0x33eb03, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/binary64/ufromfpx/ufromfpx.c", .artifact = "test/corpus/campaigns/260-ufromfpx-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x52b17c01fe27e04f, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "canonicalize", .provenance = .c23_ieee, .shape_code = 0x1111, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/c23-ieee/canonicalize/canonicalize-h.c", .artifact = "test/corpus/campaigns/261-canonicalize-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x72c6bb2e40a0e7eb, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "canonicalize", .provenance = .c23_ieee, .shape_code = 0x1212, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/c23-ieee/canonicalize/canonicalize-f.c", .artifact = "test/corpus/campaigns/262-canonicalize-f-hard_corpus_f.zcdr", .deterministic_seed = 0x250687667560d9f1, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "canonicalize", .provenance = .c23_ieee, .shape_code = 0x1313, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/c23-ieee/canonicalize/canonicalize-d.c", .artifact = "test/corpus/campaigns/263-canonicalize-d-hard_corpus_d.zcdr", .deterministic_seed = 0x3330fa62c51af0cb, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "copySign", .provenance = .c23_ieee, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/copySign/copySign-h.c", .artifact = "test/corpus/campaigns/264-copySign-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x5257b77725f973a1, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "copySign", .provenance = .c23_ieee, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/copySign/copySign-f.c", .artifact = "test/corpus/campaigns/265-copySign-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x04b4414abbe492a6, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "copySign", .provenance = .c23_ieee, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/copySign/copySign-d.c", .artifact = "test/corpus/campaigns/266-copySign-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xfbefc4a9d233031b, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nan", .provenance = .c23_ieee, .shape_code = 0x1d01, .format = .h, .campaign_class = .explicit_special_tuple_grid, .source_path = "src/c23-ieee/nan/nan-h.c", .artifact = "test/corpus/campaigns/267-nan-h-explicit_special_tuple_grid.zcdr", .deterministic_seed = 0xb05586573c0b617c, .tuple_count = 8, .special_axis_count = 1 }),
    makeCampaignRule(.{ .operation = "nan", .provenance = .c23_ieee, .shape_code = 0x1d02, .format = .f, .campaign_class = .explicit_special_tuple_grid, .source_path = "src/c23-ieee/nan/nan-f.c", .artifact = "test/corpus/campaigns/268-nan-f-explicit_special_tuple_grid.zcdr", .deterministic_seed = 0xc4e9e7ce731bce19, .tuple_count = 8, .special_axis_count = 1 }),
    makeCampaignRule(.{ .operation = "nan", .provenance = .c23_ieee, .shape_code = 0x1d03, .format = .d, .campaign_class = .explicit_special_tuple_grid, .source_path = "src/c23-ieee/nan/nan-d.c", .artifact = "test/corpus/campaigns/269-nan-d-explicit_special_tuple_grid.zcdr", .deterministic_seed = 0x56f9a42c3c4c49a2, .tuple_count = 8, .special_axis_count = 1 }),
    makeCampaignRule(.{ .operation = "nextAfter", .provenance = .c23_ieee, .shape_code = 0x21101, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/nextAfter/nextAfter-h.c", .artifact = "test/corpus/campaigns/270-nextAfter-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x95b057970c21f2e5, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nextAfter", .provenance = .c23_ieee, .shape_code = 0x22202, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/nextAfter/nextAfter-f.c", .artifact = "test/corpus/campaigns/271-nextAfter-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xfdec79f219195d1b, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nextAfter", .provenance = .c23_ieee, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/nextAfter/nextAfter-d.c", .artifact = "test/corpus/campaigns/272-nextAfter-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xba6e1b48ac434e4e, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nextDown", .provenance = .c23_ieee, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/c23-ieee/nextDown/nextDown-h.c", .artifact = "test/corpus/campaigns/273-nextDown-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x5e450e12baa25e9d, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "nextDown", .provenance = .c23_ieee, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/c23-ieee/nextDown/nextDown-f.c", .artifact = "test/corpus/campaigns/274-nextDown-f-hard_corpus_f.zcdr", .deterministic_seed = 0xa5ab043e039407ad, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "nextDown", .provenance = .c23_ieee, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/c23-ieee/nextDown/nextDown-d.c", .artifact = "test/corpus/campaigns/275-nextDown-d-hard_corpus_d.zcdr", .deterministic_seed = 0xfdad2d38c1ab4ce2, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "nextToward", .provenance = .c23_ieee, .shape_code = 0x21301, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/nextToward/nextToward-h.c", .artifact = "test/corpus/campaigns/276-nextToward-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xbdcc6aa38949124b, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nextToward", .provenance = .c23_ieee, .shape_code = 0x22302, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/nextToward/nextToward-f.c", .artifact = "test/corpus/campaigns/277-nextToward-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xef734ebc59320d33, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nextToward", .provenance = .c23_ieee, .shape_code = 0x23303, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/c23-ieee/nextToward/nextToward-d.c", .artifact = "test/corpus/campaigns/278-nextToward-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x9788497a0a4da00e, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "nextUp", .provenance = .c23_ieee, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/c23-ieee/nextUp/nextUp-h.c", .artifact = "test/corpus/campaigns/279-nextUp-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x7698363ac9db07b2, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "nextUp", .provenance = .c23_ieee, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/c23-ieee/nextUp/nextUp-f.c", .artifact = "test/corpus/campaigns/280-nextUp-f-hard_corpus_f.zcdr", .deterministic_seed = 0xcd67b9b0104655c9, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "nextUp", .provenance = .c23_ieee, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/c23-ieee/nextUp/nextUp-d.c", .artifact = "test/corpus/campaigns/281-nextUp-d-hard_corpus_d.zcdr", .deterministic_seed = 0x29a158ce29b6b9ed, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "getPayload", .provenance = .annex_f, .shape_code = 0x1101, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/annex-f/getPayload/getPayload-h.c", .artifact = "test/corpus/campaigns/282-getPayload-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x43e2c68eb05a76d2, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "getPayload", .provenance = .annex_f, .shape_code = 0x1202, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/annex-f/getPayload/getPayload-f.c", .artifact = "test/corpus/campaigns/283-getPayload-f-hard_corpus_f.zcdr", .deterministic_seed = 0x908efddb609bafd4, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "getPayload", .provenance = .annex_f, .shape_code = 0x1303, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/annex-f/getPayload/getPayload-d.c", .artifact = "test/corpus/campaigns/284-getPayload-d-hard_corpus_d.zcdr", .deterministic_seed = 0xc2a22a8fa5047279, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "setPayload", .provenance = .annex_f, .shape_code = 0x1125, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/annex-f/setPayload/setPayload-h.c", .artifact = "test/corpus/campaigns/285-setPayload-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x2e591311257ca25f, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "setPayload", .provenance = .annex_f, .shape_code = 0x1226, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/annex-f/setPayload/setPayload-f.c", .artifact = "test/corpus/campaigns/286-setPayload-f-hard_corpus_f.zcdr", .deterministic_seed = 0x0ebddb7a483a3353, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "setPayload", .provenance = .annex_f, .shape_code = 0x1327, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/annex-f/setPayload/setPayload-d.c", .artifact = "test/corpus/campaigns/287-setPayload-d-hard_corpus_d.zcdr", .deterministic_seed = 0xd5f3ba63e4916cc6, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "setPayloadSig", .provenance = .annex_f, .shape_code = 0x1125, .format = .h, .campaign_class = .exhaustive_h_unary, .source_path = "src/annex-f/setPayloadSig/setPayloadSig-h.c", .artifact = "test/corpus/campaigns/288-setPayloadSig-h-exhaustive_h_unary.zcdr", .deterministic_seed = 0x428043f05e34e3af, .tuple_count = 65536 }),
    makeCampaignRule(.{ .operation = "setPayloadSig", .provenance = .annex_f, .shape_code = 0x1226, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/annex-f/setPayloadSig/setPayloadSig-f.c", .artifact = "test/corpus/campaigns/289-setPayloadSig-f-hard_corpus_f.zcdr", .deterministic_seed = 0xafe7c3517f02c352, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "setPayloadSig", .provenance = .annex_f, .shape_code = 0x1327, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/annex-f/setPayloadSig/setPayloadSig-d.c", .artifact = "test/corpus/campaigns/290-setPayloadSig-d-hard_corpus_d.zcdr", .deterministic_seed = 0x75213ab773ca20ea, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "totalOrder", .provenance = .annex_f, .shape_code = 0x2110d, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-f/totalOrder/totalOrder-h.c", .artifact = "test/corpus/campaigns/291-totalOrder-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xcb9a741a88037322, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "totalOrder", .provenance = .annex_f, .shape_code = 0x2220d, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-f/totalOrder/totalOrder-f.c", .artifact = "test/corpus/campaigns/292-totalOrder-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x55fd27053b0e424d, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "totalOrder", .provenance = .annex_f, .shape_code = 0x2330d, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-f/totalOrder/totalOrder-d.c", .artifact = "test/corpus/campaigns/293-totalOrder-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x653e120fede5b373, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "totalOrderMag", .provenance = .annex_f, .shape_code = 0x2110d, .format = .h, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-f/totalOrderMag/totalOrderMag-h.c", .artifact = "test/corpus/campaigns/294-totalOrderMag-h-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x94292ede0c4165d1, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "totalOrderMag", .provenance = .annex_f, .shape_code = 0x2220d, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-f/totalOrderMag/totalOrderMag-f.c", .artifact = "test/corpus/campaigns/295-totalOrderMag-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x521e199cb6fba1c6, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "totalOrderMag", .provenance = .annex_f, .shape_code = 0x2330d, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-f/totalOrderMag/totalOrderMag-d.c", .artifact = "test/corpus/campaigns/296-totalOrderMag-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xd5fa248bc3d36870, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16addf32", .provenance = .annex_h, .shape_code = 0x22201, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16addf32/f16addf32-f.c", .artifact = "test/corpus/campaigns/297-f16addf32-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2b9d3fba80bb7410, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16addf64", .provenance = .annex_h, .shape_code = 0x23301, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16addf64/f16addf64-d.c", .artifact = "test/corpus/campaigns/298-f16addf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x208ce9748233d99f, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16divf32", .provenance = .annex_h, .shape_code = 0x22201, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16divf32/f16divf32-f.c", .artifact = "test/corpus/campaigns/299-f16divf32-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x89b463ea2690d963, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16divf64", .provenance = .annex_h, .shape_code = 0x23301, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16divf64/f16divf64-d.c", .artifact = "test/corpus/campaigns/300-f16divf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xbd62959fb08b337f, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16fmaf32", .provenance = .annex_h, .shape_code = 0x322201, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16fmaf32/f16fmaf32-f.c", .artifact = "test/corpus/campaigns/301-f16fmaf32-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xf87bc6bef51c442a, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "f16fmaf64", .provenance = .annex_h, .shape_code = 0x333301, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16fmaf64/f16fmaf64-d.c", .artifact = "test/corpus/campaigns/302-f16fmaf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x5cb5631e6ad30c15, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "f16mulf32", .provenance = .annex_h, .shape_code = 0x22201, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16mulf32/f16mulf32-f.c", .artifact = "test/corpus/campaigns/303-f16mulf32-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x6bb65b5642b7720a, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16mulf64", .provenance = .annex_h, .shape_code = 0x23301, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16mulf64/f16mulf64-d.c", .artifact = "test/corpus/campaigns/304-f16mulf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x2d28e8eb8171d50d, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16sqrtf32", .provenance = .annex_h, .shape_code = 0x1201, .format = .f, .campaign_class = .hard_corpus_f, .source_path = "src/annex-h/f16sqrtf32/f16sqrtf32-f.c", .artifact = "test/corpus/campaigns/305-f16sqrtf32-f-hard_corpus_f.zcdr", .deterministic_seed = 0x7b5a32659d800420, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "f16sqrtf64", .provenance = .annex_h, .shape_code = 0x1301, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/annex-h/f16sqrtf64/f16sqrtf64-d.c", .artifact = "test/corpus/campaigns/306-f16sqrtf64-d-hard_corpus_d.zcdr", .deterministic_seed = 0x771be0c5ff4ce1ce, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "f16subf32", .provenance = .annex_h, .shape_code = 0x22201, .format = .f, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16subf32/f16subf32-f.c", .artifact = "test/corpus/campaigns/307-f16subf32-f-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x426c9024eaf21023, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f16subf64", .provenance = .annex_h, .shape_code = 0x23301, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f16subf64/f16subf64-d.c", .artifact = "test/corpus/campaigns/308-f16subf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x02243eeb6ebca311, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f32addf64", .provenance = .annex_h, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f32addf64/f32addf64-d.c", .artifact = "test/corpus/campaigns/309-f32addf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xcace121ca5de0274, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f32divf64", .provenance = .annex_h, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f32divf64/f32divf64-d.c", .artifact = "test/corpus/campaigns/310-f32divf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x098b9b6faaca72c6, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f32fmaf64", .provenance = .annex_h, .shape_code = 0x333302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f32fmaf64/f32fmaf64-d.c", .artifact = "test/corpus/campaigns/311-f32fmaf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0xdcce38aa374e9fe4, .tuple_count = 48 }),
    makeCampaignRule(.{ .operation = "f32mulf64", .provenance = .annex_h, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f32mulf64/f32mulf64-d.c", .artifact = "test/corpus/campaigns/312-f32mulf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x5fceed3903352187, .tuple_count = 32 }),
    makeCampaignRule(.{ .operation = "f32sqrtf64", .provenance = .annex_h, .shape_code = 0x1302, .format = .d, .campaign_class = .hard_corpus_d, .source_path = "src/annex-h/f32sqrtf64/f32sqrtf64-d.c", .artifact = "test/corpus/campaigns/313-f32sqrtf64-d-hard_corpus_d.zcdr", .deterministic_seed = 0xd597915da4f3e70b, .tuple_count = 256 }),
    makeCampaignRule(.{ .operation = "f32subf64", .provenance = .annex_h, .shape_code = 0x23302, .format = .d, .campaign_class = .source_pinned_binary_ternary_hard_tuples, .source_path = "src/annex-h/f32subf64/f32subf64-d.c", .artifact = "test/corpus/campaigns/314-f32subf64-d-source_pinned_binary_ternary_hard_tuples.zcdr", .deterministic_seed = 0x18b891e4d8509c9c, .tuple_count = 32 }),
};
pub const manifest_campaign_count: usize = 315;
pub const unavailable_artifact = "test/corpus/unavailable/source-metadata-unavailable.zcdr";

pub const CampaignMatrixError = error{
    ManifestCountMismatch,
};

pub const CampaignMatrix = struct {
    definitions: [manifest_campaign_count]CampaignDefinition,
    count: usize,

    pub fn at(self: *const @This(), index: usize) ?*const CampaignDefinition {
        if (index >= self.count) return null;
        return &self.definitions[index];
    }
};

pub fn matchingRuleCount(function: corpus.Function) usize {
    var count: usize = 0;
    for (campaign_table) |rule| {
        if (ruleMatches(rule, function)) count += 1;
    }
    return count;
}

pub fn classifyManifest(manifest: *const corpus.Manifest) CampaignMatrixError!CampaignMatrix {
    if (manifest.function_count != manifest_campaign_count) {
        return error.ManifestCountMismatch;
    }
    var matrix = CampaignMatrix{
        .definitions = undefined,
        .count = manifest.function_count,
    };
    for (manifest.function_values[0..manifest.function_count], 0..) |function, index| {
        matrix.definitions[index] = classify(function);
    }
    return matrix;
}

pub fn classify(function: corpus.Function) CampaignDefinition {
    for (campaign_table) |rule| {
        if (!ruleMatches(rule, function)) continue;
        return definitionFromRule(rule, function);
    }

    const reason: UnavailableReason = if (function.status != .correct)
        .source_metadata_unavailable
    else
        .unsupported_shape;
    return .{
        .function = function,
        .data = .{ .unavailable = .{
            .planned_class = plannedClassFor(function),
            .reason = reason,
            .manifest_status = function.status,
            .source_metadata_available = false,
            .source = null,
            .artifact = unavailable_artifact,
        } },
    };
}

fn plannedClassFor(function: corpus.Function) CampaignClass {
    const arguments = function.arguments();
    if (function.arity == 1 and arguments.len == 1) {
        return switch (arguments[0]) {
            .float => |format| switch (format) {
                .h => .exhaustive_h_unary,
                .f => .hard_corpus_f,
                .d => .hard_corpus_d,
            },
            .tag => .explicit_special_tuple_grid,
            else => .exact_bit_status,
        };
    }
    if ((function.arity == 2 or function.arity == 3) and arguments.len == function.arity) {
        var has_signed_integer = false;
        var has_half = false;
        for (arguments) |argument| {
            switch (argument) {
                .integer => |integer_type| switch (integer_type) {
                    .i2, .i8, .i16, .i32, .i64 => has_signed_integer = true,
                    .u8, .u16, .u32, .u64 => {},
                },
                .float => |format| {
                    if (format == .h) has_half = true;
                },
                else => {},
            }
        }
        if (has_signed_integer and has_half) return .bounded_h_integer_domain;
        return .source_pinned_binary_ternary_hard_tuples;
    }
    return .exact_bit_status;
}

pub fn campaignClass(function: corpus.Function) CampaignClass {
    const definition = classify(function);
    return definition.campaignClass();
}

pub fn plannedCampaignClass(function: corpus.Function) CampaignClass {
    const definition = classify(function);
    return definition.plannedCampaignClass();
}

pub fn makeBoundedHIntegerDomain(
    function: corpus.Function,
    integer_index: u8,
    bounds: IntegerBounds,
    base_arguments: InputTuple,
) CampaignError!CampaignDefinition {
    try validateFunctionShape(function);
    const arguments = function.arguments();
    if (integer_index >= arguments.len) return error.InvalidDefinition;
    const integer_type = switch (arguments[integer_index]) {
        .integer => |value| value,
        else => return error.InvalidDefinition,
    };
    if (!hasHalfArgument(arguments)) return error.InvalidDefinition;
    try validateIntegerBounds(bounds, integer_type);
    _ = try integerDomainCardinality(bounds);
    try validateTupleAgainstFunction(function, base_arguments);
    return .{
        .function = function,
        .data = .{ .bounded_h_integer_domain = .{
            .integer_index = integer_index,
            .integer_type = integer_type,
            .bounds = bounds,
            .base_arguments = base_arguments,
        } },
    };
}

pub fn makeSpecialTupleGrid(
    function: corpus.Function,
    axes: []const TupleAxis,
) CampaignError!CampaignDefinition {
    try validateFunctionShape(function);
    if (axes.len != function.arguments().len or axes.len == 0) return error.TupleArityMismatch;
    for (axes, 0..) |axis, index| {
        if (axis.values.len == 0) return error.EmptyAxis;
        for (axis.values) |field| {
            try validateArgumentField(function.arguments()[index], field);
        }
    }
    _ = try tupleGridCardinality(axes);
    return .{
        .function = function,
        .data = .{ .explicit_special_tuple_grid = .{ .axes = axes } },
    };
}

pub fn makeSourcePinnedHardTuples(
    function: corpus.Function,
    source: SourcePin,
    tuples: []const HardTuple,
) CampaignError!CampaignDefinition {
    try validateSourcePin(source);
    try validateFunctionShape(function);
    if (function.arity != 2 and function.arity != 3) return error.InvalidDefinition;
    if (tuples.len == 0) return error.InvalidDefinition;
    var has_expected: ?bool = null;
    for (tuples) |tuple| {
        try validateTupleAgainstFunction(function, tuple.arguments);
        const tuple_has_expected = tuple.expected_results.len != 0;
        if (has_expected) |prior| {
            if (prior != tuple_has_expected) return error.InvalidDefinition;
        } else {
            has_expected = tuple_has_expected;
        }
        if (tuple_has_expected) {
            _ = try buildRecordFromFields(
                function,
                tuple.arguments.slice(),
                tuple.expected_results,
            );
        }
    }
    return .{
        .function = function,
        .data = .{ .source_pinned_binary_ternary_hard_tuples = .{
            .source = source,
            .artifact = "test/corpus/ad-hoc/source-pinned-tuples.zcdr",
            .deterministic_seed = 1,
            .tuples = tuples,
            .generated_tuple_count = @intCast(tuples.len),
            .evidence = if (has_expected orelse false)
                .records_ready
            else
                .generation_ready,
        } },
    };
}

pub fn makeHardCorpusMetadata(
    function: corpus.Function,
    format: corpus.Format,
    source: SourcePin,
    artifact: []const u8,
    record_count: u64,
    evidence_available: bool,
) CampaignError!CampaignDefinition {
    try validateSourcePin(source);
    try validateFunctionShape(function);
    if (function.arity != 1 or artifact.len == 0) return error.InvalidDefinition;
    const input_format = switch (function.arguments()[0]) {
        .float => |value| value,
        else => return error.InvalidDefinition,
    };
    const output_format = switch (function.result) {
        .float => |value| value,
        else => return error.InvalidDefinition,
    };
    if (input_format != format or output_format != format) return error.InvalidDefinition;
    var data: CampaignData = undefined;
    if (format == .f) {
        data = .{ .hard_corpus_f = .{
            .format = format,
            .source = source,
            .artifact = artifact,
            .deterministic_seed = 1,
            .record_count = record_count,
            .evidence_available = evidence_available,
            .evidence = if (evidence_available) .records_ready else .generation_ready,
        } };
    } else if (format == .d) {
        data = .{ .hard_corpus_d = .{
            .format = format,
            .source = source,
            .artifact = artifact,
            .deterministic_seed = 1,
            .record_count = record_count,
            .evidence_available = evidence_available,
            .evidence = if (evidence_available) .records_ready else .generation_ready,
        } };
    } else {
        return error.InvalidDefinition;
    }
    return .{
        .function = function,
        .data = data,
    };
}

pub fn makeExactBitStatus(
    function: corpus.Function,
    cases: []const ExactCase,
) CampaignError!CampaignDefinition {
    try validateFunctionShape(function);
    if (cases.len == 0) return error.InvalidDefinition;
    for (cases) |case| {
        try validateTupleAgainstFunction(function, case.arguments);
        if (case.results.len != function.result.oracleFieldCount()) {
            return error.ResultFieldMismatch;
        }
        for (case.results, 0..) |field, index| {
            const descriptor = function.result.oracleFieldDescriptor(index) orelse
                return error.InvalidResultDescriptor;
            try validateResultField(field, descriptor);
        }
        _ = try buildRecordFromFieldsWithUlp(
            function,
            case.arguments.slice(),
            case.results,
            case.max_ulp,
        );
    }
    return .{
        .function = function,
        .data = .{ .exact_bit_status = .{ .cases = cases } },
    };
}

pub fn visitRecords(function: corpus.Function, context: anytype, callback: anytype) anyerror!void {
    var definition = classify(function);
    try visitDefinitionRecords(&definition, context, callback);
}

pub fn visitDefinitionRecords(
    definition: *const CampaignDefinition,
    context: anytype,
    callback: anytype,
) anyerror!void {
    if (definition.campaignClass() == .unavailable) return error.CampaignUnavailable;
    switch (definition.data) {
        .hard_corpus_f, .hard_corpus_d => return error.MetadataOnly,
        else => {},
    }

    var iterator = definition.iterator();
    while (try iterator.next()) |arguments| {
        var visit = RecordVisit{
            .function = definition.function,
            .arguments = arguments,
            .expected_results = &.{},
            .expected_status = .ok,
            .max_ulp = definition.function.max_ulp,
        };
        switch (definition.data) {
            .source_pinned_binary_ternary_hard_tuples => |spec| {
                const tuple = spec.tuples[@intCast(iterator.index - 1)];
                visit.expected_results = tuple.expected_results;
                visit.expected_status = tuple.expected_status;
            },
            .exact_bit_status => |spec| {
                const case = spec.cases[@intCast(iterator.index - 1)];
                visit.expected_results = case.results;
                visit.expected_status = case.expected_status;
                visit.max_ulp = case.max_ulp;
            },
            else => {},
        }
        try callback(context, &visit);
    }
}

pub fn buildRecordFromFields(
    function: corpus.Function,
    arguments: []const corpus.CorpusField,
    results: []const corpus.CorpusField,
) CampaignError!corpus.CorpusRecord {
    return buildRecordFromFieldsWithUlp(function, arguments, results, function.max_ulp);
}

pub fn buildRecordFromFieldsWithUlp(
    function: corpus.Function,
    arguments: []const corpus.CorpusField,
    results: []const corpus.CorpusField,
    max_ulp: u64,
) CampaignError!corpus.CorpusRecord {
    try validateFunctionShape(function);
    try validateInputFields(function, arguments);
    const provenance = function.provenance.slice();
    return corpus.CorpusRecord.init(.{
        .operation = function.op,
        .provenance = provenance,
        .arguments = arguments,
        .result_descriptor = function.result,
        .results = results,
        .max_ulp = max_ulp,
    });
}

pub fn buildRecordFromTuple(
    function: corpus.Function,
    arguments: InputTuple,
    results: []const corpus.CorpusField,
) CampaignError!corpus.CorpusRecord {
    return buildRecordFromFields(function, arguments.slice(), results);
}

pub fn buildRecordForVisit(visit: *const RecordVisit) CampaignError!corpus.CorpusRecord {
    if (visit.expected_results.len == 0) return error.ExpectedResultRequired;
    return buildRecordFromFieldsWithUlp(
        visit.function,
        visit.arguments.slice(),
        visit.expected_results,
        visit.max_ulp,
    );
}

pub fn encodeRecordFromFields(
    function: corpus.Function,
    arguments: []const corpus.CorpusField,
    results: []const corpus.CorpusField,
    target: []u8,
) CampaignError![]u8 {
    var record = try buildRecordFromFields(function, arguments, results);
    return corpus.encodeCorpusRecord(&record, target);
}

pub fn encodeRecordForVisit(
    visit: *const RecordVisit,
    target: []u8,
) CampaignError![]u8 {
    var record = try buildRecordForVisit(visit);
    return corpus.encodeCorpusRecord(&record, target);
}

pub const ExpectedRecord = struct {
    record: corpus.CorpusRecord,
    expected_status: corpus.OracleStatus,
};

pub fn exactRecord(definition: *const CampaignDefinition, index: usize) CampaignError!ExpectedRecord {
    switch (definition.data) {
        .exact_bit_status => |spec| {
            if (index >= spec.cases.len) return error.InvalidDefinition;
            const case = spec.cases[index];
            const record = try buildRecordFromFieldsWithUlp(
                definition.function,
                case.arguments.slice(),
                case.results,
                case.max_ulp,
            );
            return .{ .record = record, .expected_status = case.expected_status };
        },
        else => return error.ExpectedResultRequired,
    }
}
fn formatShapeCode(format: corpus.Format) u64 {
    return @as(u64, @intFromEnum(format)) + 1;
}

fn argumentShapeCode(argument: corpus.ArgumentDescriptor) u64 {
    return switch (argument) {
        .float => |format| formatShapeCode(format),
        .integer => |integer_type| 4 + @as(u64, @intFromEnum(integer_type)),
        .tag => 13,
        .fromfp_round => 14,
    };
}

fn resultShapeCode(result: corpus.ResultDescriptor) u64 {
    return switch (result) {
        .float => |format| formatShapeCode(format),
        .integer => |integer_type| 4 + @as(u64, @intFromEnum(integer_type)),
        .boolean => 13,
        .structure => |structure| 16 + @as(u64, @intFromEnum(structure.kind)) * 4 +
            formatShapeCode(structure.format),
    };
}

fn functionShapeCode(function: corpus.Function) u64 {
    var code: u64 = function.arity;
    for (function.arguments()) |argument| {
        code = (code << 4) | argumentShapeCode(argument);
    }
    return (code << 8) | resultShapeCode(function.result);
}

fn ruleMatches(rule: CampaignRule, function: corpus.Function) bool {
    if (!std.mem.eql(u8, function.op, rule.operation)) return false;
    if (function.provenance.count != 1 or function.provenance.values[0] != rule.provenance) {
        return false;
    }
    if (function.status != rule.status or function.oracle != rule.oracle) return false;
    if (!std.mem.eql(u8, function.special_policy, rule.special_policy)) return false;
    if (function.max_ulp != rule.max_ulp) return false;
    return functionShapeCode(function) == rule.shape_code;
}

fn definitionFromRule(rule: CampaignRule, function: corpus.Function) CampaignDefinition {
    if (!rule.enabled) {
        return .{
            .function = function,
            .data = .{ .unavailable = .{
                .planned_class = rule.campaign_class,
                .reason = .source_metadata_unavailable,
                .manifest_status = function.status,
                .source_metadata_available = rule.source_metadata_available,
                .source = rule.source,
                .artifact = rule.artifact,
                .deterministic_seed = rule.deterministic_seed,
                .tuple_count = rule.tuple_count,
                .tuple_policy = rule.tuple_policy,
                .integer_index = rule.integer_index,
                .integer_type = rule.integer_type,
                .bounds = rule.bounds,
                .special_axis_count = rule.special_axis_count,
            } },
        };
    }

    return switch (rule.campaign_class) {
        .exhaustive_h_unary => .{
            .function = function,
            .data = .{ .exhaustive_h_unary = .{
                .format = rule.format,
                .source = rule.source,
                .artifact = rule.artifact,
                .deterministic_seed = rule.deterministic_seed,
                .evidence = rule.evidence,
            } },
        },
        .bounded_h_integer_domain => .{
            .function = function,
            .data = .{ .bounded_h_integer_domain = .{
                .integer_index = rule.integer_index.?,
                .integer_type = rule.integer_type.?,
                .bounds = rule.bounds.?,
                .base_arguments = baseArgumentsFor(function),
                .half_index = halfArgumentIndex(function.arguments()),
                .exhaustive_half = true,
                .source = rule.source,
                .artifact = rule.artifact,
                .deterministic_seed = rule.deterministic_seed,
                .evidence = rule.evidence,
            } },
        },
        .explicit_special_tuple_grid => .{
            .function = function,
            .data = .{ .explicit_special_tuple_grid = .{
                .axes = specialTagAxes(),
                .source = rule.source,
                .artifact = rule.artifact,
                .deterministic_seed = rule.deterministic_seed,
                .evidence = rule.evidence,
            } },
        },
        .source_pinned_binary_ternary_hard_tuples => unreachable,
        .hard_corpus_f => .{
            .function = function,
            .data = .{ .hard_corpus_f = .{
                .format = rule.format,
                .source = rule.source,
                .artifact = rule.artifact,
                .deterministic_seed = rule.deterministic_seed,
                .record_count = 0,
                .evidence_available = false,
                .evidence = rule.evidence,
            } },
        },
        .hard_corpus_d => .{
            .function = function,
            .data = .{ .hard_corpus_d = .{
                .format = rule.format,
                .source = rule.source,
                .artifact = rule.artifact,
                .deterministic_seed = rule.deterministic_seed,
                .record_count = 0,
                .evidence_available = false,
                .evidence = rule.evidence,
            } },
        },
        .exact_bit_status => unreachable,
        .unavailable => unreachable,
    };
}

fn halfArgumentIndex(arguments: []const corpus.ArgumentDescriptor) ?u8 {
    for (arguments, 0..) |argument, index| {
        switch (argument) {
            .float => |format| if (format == .h) return @intCast(index),
            else => {},
        }
    }
    return null;
}

fn baseArgumentsFor(function: corpus.Function) InputTuple {
    var fields = blankFields();
    for (function.arguments(), 0..) |argument, index| {
        fields[index] = switch (argument) {
            .float => |format| .{ .float = .{
                .format = format,
                .bits = 0,
                .class = .none,
            } },
            .integer => |integer_type| switch (integer_type) {
                .i2, .i8, .i16, .i32, .i64 => .{ .signed_integer = .{
                    .integer_type = integer_type,
                    .value = 0,
                } },
                .u8, .u16, .u32, .u64 => .{ .unsigned_integer = .{
                    .integer_type = integer_type,
                    .value = 0,
                } },
            },
            .tag => .{ .tag = "" },
            .fromfp_round => .{ .rounding = .nearest_even },
        };
    }
    return InputTuple.init(fields[0..function.arguments().len]) catch unreachable;
}

const special_tag_values = [_]corpus.CorpusField{
    .{ .tag = "0" },
    .{ .tag = "1" },
    .{ .tag = "7fff" },
    .{ .tag = "8000" },
    .{ .tag = "ffffffff" },
    .{ .tag = "FFFFFFFF" },
    .{ .tag = "invalid" },
    .{ .tag = "" },
};
const special_tag_axes = [_]TupleAxis{
    .{ .values = special_tag_values[0..] },
};

fn specialTagAxes() []const TupleAxis {
    return special_tag_axes[0..];
}

fn blankFields() [max_arity]corpus.CorpusField {
    var fields: [max_arity]corpus.CorpusField = undefined;
    for (&fields) |*field| field.* = .{ .boolean = false };
    return fields;
}

fn validateFunctionShape(function: corpus.Function) CampaignError!void {
    if (function.op.len == 0 or function.arity == 0 or function.arity > max_arity) {
        return error.InvalidDefinition;
    }
    if (function.status == .unsupported) return error.CampaignUnavailable;
    if (function.arguments().len != function.arity) return error.InvalidDefinition;
    if (function.provenance.count == 0) return error.InvalidDefinition;
}

fn validateSourcePin(source: SourcePin) CampaignError!void {
    if (!std.mem.eql(u8, source.repository, core_math_repository)) {
        return error.InvalidSourcePin;
    }
    if (!std.mem.eql(u8, source.revision, core_math_revision)) {
        return error.InvalidSourcePin;
    }
    if (source.path.len == 0) return error.InvalidSourcePin;
}

fn hasHalfArgument(arguments: []const corpus.ArgumentDescriptor) bool {
    for (arguments) |argument| {
        switch (argument) {
            .float => |format| if (format == .h) return true,
            else => {},
        }
    }
    return false;
}

fn boundsMatchType(bounds: IntegerBounds, integer_type: corpus.IntegerType) bool {
    const signed = switch (integer_type) {
        .i2, .i8, .i16, .i32, .i64 => true,
        .u8, .u16, .u32, .u64 => false,
    };
    return switch (bounds) {
        .signed => signed,
        .unsigned => !signed,
    };
}

fn validateIntegerBounds(bounds: IntegerBounds, integer_type: corpus.IntegerType) CampaignError!void {
    switch (integer_type) {
        .i2 => switch (bounds) {
            .signed => |value| if (value.lower < -2 or value.upper > 1) return error.InvalidBounds,
            .unsigned => return error.InvalidBounds,
        },
        .i8 => switch (bounds) {
            .signed => |value| if (value.lower < -128 or value.upper > 127) return error.InvalidBounds,
            .unsigned => return error.InvalidBounds,
        },
        .i16 => switch (bounds) {
            .signed => |value| if (value.lower < -32_768 or value.upper > 32_767) return error.InvalidBounds,
            .unsigned => return error.InvalidBounds,
        },
        .i32 => switch (bounds) {
            .signed => |value| if (value.lower < -2_147_483_648 or value.upper > 2_147_483_647) {
                return error.InvalidBounds;
            },
            .unsigned => return error.InvalidBounds,
        },
        .i64 => switch (bounds) {
            .signed => {},
            .unsigned => return error.InvalidBounds,
        },
        .u8 => switch (bounds) {
            .signed => return error.InvalidBounds,
            .unsigned => |value| if (value.upper > 255) return error.InvalidBounds,
        },
        .u16 => switch (bounds) {
            .signed => return error.InvalidBounds,
            .unsigned => |value| if (value.upper > 65_535) return error.InvalidBounds,
        },
        .u32 => switch (bounds) {
            .signed => return error.InvalidBounds,
            .unsigned => |value| if (value.upper > 4_294_967_295) return error.InvalidBounds,
        },
        .u64 => switch (bounds) {
            .signed => return error.InvalidBounds,
            .unsigned => {},
        },
    }
}

fn integerDomainCardinality(bounds: IntegerBounds) CampaignError!u64 {
    return switch (bounds) {
        .signed => |value| blk: {
            if (value.lower > value.upper) return error.InvalidBounds;
            const span = @as(i128, value.upper) - @as(i128, value.lower) + 1;
            if (span <= 0 or span > @as(i128, std.math.maxInt(u64))) {
                return error.CardinalityOverflow;
            }
            break :blk @intCast(span);
        },
        .unsigned => |value| blk: {
            if (value.lower > value.upper) return error.InvalidBounds;
            const span = value.upper - value.lower;
            if (span == std.math.maxInt(u64)) return error.CardinalityOverflow;
            break :blk span + 1;
        },
    };
}

fn tupleGridCardinality(axes: []const TupleAxis) CampaignError!u64 {
    if (axes.len == 0 or axes.len > max_arity) return error.TupleArityMismatch;
    var result: u64 = 1;
    for (axes) |axis| {
        if (axis.values.len == 0) return error.EmptyAxis;
        const count: u64 = @intCast(axis.values.len);
        if (result > std.math.maxInt(u64) / count) return error.CardinalityOverflow;
        result *= count;
    }
    return result;
}

fn exhaustiveUnaryTuple(spec: UnaryExhaustiveSpec, index: u64) CampaignError!InputTuple {
    if (index >= (1 << 16)) return error.CardinalityOverflow;
    const bits: corpus.CorpusField = .{ .float = .{
        .format = spec.format,
        .bits = index,
        .class = .none,
    } };
    return InputTuple.init(&.{bits});
}

fn boundedIntegerTuple(
    function: corpus.Function,
    spec: BoundedHIntegerDomainSpec,
    index: u64,
) CampaignError!InputTuple {
    var tuple = spec.base_arguments;
    const value: u64 = switch (spec.bounds) {
        .signed => |bounds| blk: {
            const candidate = @as(i128, bounds.lower) + @as(i128, index);
            if (candidate > @as(i128, bounds.upper)) return error.CardinalityOverflow;
            const signed_value: i64 = @intCast(candidate);
            break :blk @bitCast(signed_value);
        },
        .unsigned => |bounds| bounds.lower + index,
    };
    tuple.fields[spec.integer_index] = switch (spec.integer_type) {
        .i2, .i8, .i16, .i32, .i64 => .{ .signed_integer = .{
            .integer_type = spec.integer_type,
            .value = @bitCast(value),
        } },
        .u8, .u16, .u32, .u64 => .{ .unsigned_integer = .{
            .integer_type = spec.integer_type,
            .value = value,
        } },
    };
    try validateTupleAgainstFunction(function, tuple);
    return tuple;
}

fn specialGridTuple(
    function: corpus.Function,
    spec: SpecialTupleGridSpec,
    index: u64,
) CampaignError!InputTuple {
    var tuple = InputTuple{ .fields = blankFields(), .count = @intCast(spec.axes.len) };
    var remainder = index;
    var axis_index = spec.axes.len;
    while (axis_index != 0) {
        axis_index -= 1;
        const axis = spec.axes[axis_index];
        const axis_len: u64 = @intCast(axis.values.len);
        const coordinate = remainder % axis_len;
        remainder /= axis_len;
        tuple.fields[axis_index] = axis.values[@intCast(coordinate)];
    }
    try validateTupleAgainstFunction(function, tuple);
    return tuple;
}

fn validateTupleAgainstFunction(function: corpus.Function, tuple: InputTuple) CampaignError!void {
    const arguments = function.arguments();
    if (tuple.count != arguments.len) return error.TupleArityMismatch;
    for (arguments, tuple.slice()) |argument, field| {
        try validateArgumentField(argument, field);
    }
}

fn validateInputFields(function: corpus.Function, fields: []const corpus.CorpusField) CampaignError!void {
    const arguments = function.arguments();
    if (fields.len != arguments.len) return error.TupleArityMismatch;
    for (arguments, fields) |argument, field| try validateArgumentField(argument, field);
}

fn validateArgumentField(
    argument: corpus.ArgumentDescriptor,
    field: corpus.CorpusField,
) CampaignError!void {
    switch (argument) {
        .float => |format| switch (field) {
            .float => |value| {
                if (value.format != format or value.class != .none) return error.TupleFieldMismatch;
                _ = try corpus.oracleLiteralInput(argument, value.bits);
            },
            else => return error.TupleFieldMismatch,
        },
        .integer => |integer_type| switch (field) {
            .signed_integer => |value| {
                if (value.integer_type != integer_type) return error.TupleFieldMismatch;
                _ = try corpus.encodeSignedInteger(value.value, integer_type.oracleValueBits());
            },
            .unsigned_integer => |value| {
                if (value.integer_type != integer_type) return error.TupleFieldMismatch;
                _ = try corpus.oracleLiteralInput(argument, value.value);
            },
            else => return error.TupleFieldMismatch,
        },
        .tag => switch (field) {
            .tag => {},
            else => return error.TupleFieldMismatch,
        },
        .fromfp_round => switch (field) {
            .rounding => {},
            else => return error.TupleFieldMismatch,
        },
    }
}

fn validateResultField(
    field: corpus.CorpusField,
    descriptor: corpus.OracleFieldDescriptor,
) CampaignError!void {
    switch (descriptor.kind) {
        .float => switch (field) {
            .float => |value| {
                const format = formatFromOracle(descriptor) orelse return error.InvalidResultDescriptor;
                if (value.format != format) return error.ResultFieldMismatch;
            },
            else => return error.ResultFieldMismatch,
        },
        .signed_integer => switch (field) {
            .signed_integer => |value| {
                if (value.integer_type.oracleValueBits() != descriptor.value_bits) {
                    return error.ResultFieldMismatch;
                }
            },
            else => return error.ResultFieldMismatch,
        },
        .unsigned_integer => switch (field) {
            .unsigned_integer => |value| {
                if (value.integer_type.oracleValueBits() != descriptor.value_bits) {
                    return error.ResultFieldMismatch;
                }
            },
            else => return error.ResultFieldMismatch,
        },
        .boolean => switch (field) {
            .boolean => {},
            else => return error.ResultFieldMismatch,
        },
        else => return error.ResultFieldMismatch,
    }
}

fn formatFromOracle(descriptor: corpus.OracleFieldDescriptor) ?corpus.Format {
    return switch (descriptor.format.code) {
        .h => .h,
        .f => .f,
        .d => .d,
        else => null,
    };
}
