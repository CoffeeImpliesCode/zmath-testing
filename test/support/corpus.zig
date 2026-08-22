const std = @import("std");

pub const manifest_text = @embedFile("corpus/manifest.toml");

pub const ValidationError = error{
    ByteOrderMark,
    CarriageReturn,
    MissingFinalNewline,
    MalformedLine,
    UnknownRootKey,
    DuplicateRootKey,
    MissingRootKey,
    InvalidPinnedValue,
    UnknownSection,
    RootKeyAfterFunction,
    UnknownFunctionKey,
    DuplicateFunctionKey,
    MissingFunctionKey,
    DuplicateFunctionRow,
    UnsortedFunctionRow,
    MissingFunctionRow,
    UnknownOperation,
    ReservedFormat,
    RejectedFormat,
    UnknownFormat,
    UnsupportedFunctionStatus,
    InvalidHeader,
    BlankCorpusLine,
    WrongColumnCount,
    InvalidHexWidth,
    InvalidHexDigit,
    UppercaseHexDigit,
    UnknownOutputClass,
    OutputClassMismatch,
    InvalidMaxUlp,
    UnsortedCorpusRow,
    DuplicateCorpusRow,
};

const Operation = enum(u8) {
    exp,
    log,
    sin,
};

const Format = enum(u8) {
    h,
    f,
    d,

    fn hexadecimalDigits(format: Format) usize {
        return switch (format) {
            .h => 4,
            .f => 8,
            .d => 16,
        };
    }
};

const OutputClass = enum {
    normal,
    subnormal,
    zero,
    infinity,
    qnan,
    snan,
};

const RootKey = enum(u8) {
    schema_version,
    core_math_repository,
    core_math_revision,
    mpfr_precision_bits,
    arb_precision_bits,
    rounding,
    formats,
    reserved_formats,
    rejected_formats,
    columns,
    hexadecimal,
    uncertainty_policy,
};

const Function = struct {
    operation: ?Operation = null,
    format: ?Format = null,
    unsupported: bool = false,
    has_status: bool = false,
};

const SortKey = struct {
    operation: Operation,
    format: Format,
    input_bits: []const u8,
};

pub fn validateEmbeddedManifest() ValidationError!void {
    try validateManifest(manifest_text);
}

pub fn validateManifest(source: []const u8) ValidationError!void {
    try validateTextEnvelope(source, false);

    var root_seen = [_]bool{false} ** @typeInfo(RootKey).@"enum".fields.len;
    var function_seen = [_][3]bool{[_]bool{false} ** 3} ** 3;
    var function: ?Function = null;
    var function_count: usize = 0;
    var root_complete = false;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[[function]]")) {
            if (!root_complete) {
                try requireAllRootKeys(root_seen);
                root_complete = true;
            }
            if (function) |current| {
                try finishFunction(current, &function_seen, function_count);
                function_count += 1;
            }
            function = .{};
            continue;
        }
        if (line[0] == '[') return error.UnknownSection;

        const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse
            return error.MalformedLine;
        const key = std.mem.trim(u8, line[0..equal_index], " \t");
        const value = std.mem.trim(u8, line[equal_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.MalformedLine;

        if (function) |*current| {
            try validateFunctionField(current, key, value);
        } else {
            if (root_complete) return error.RootKeyAfterFunction;
            try validateRootField(&root_seen, key, value);
        }
    }

    if (!root_complete) try requireAllRootKeys(root_seen);
    if (function) |current| {
        try finishFunction(current, &function_seen, function_count);
        function_count += 1;
    }
    if (function_count != 9) return error.MissingFunctionRow;
}

pub fn validateTsv(source: []const u8) ValidationError!void {
    try validateTextEnvelope(source, true);

    const body = source[0 .. source.len - 1];
    var lines = std.mem.splitScalar(u8, body, '\n');
    const header = lines.next() orelse return error.InvalidHeader;
    if (!std.mem.eql(
        u8,
        header,
        "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp",
    )) return error.InvalidHeader;

    var previous: ?SortKey = null;
    while (lines.next()) |line| {
        if (line.len == 0) return error.BlankCorpusLine;

        var fields: [6][]const u8 = undefined;
        var field_count: usize = 0;
        var field_iterator = std.mem.splitScalar(u8, line, '\t');
        while (field_iterator.next()) |field| {
            if (field_count == fields.len) return error.WrongColumnCount;
            fields[field_count] = field;
            field_count += 1;
        }
        if (field_count != fields.len) return error.WrongColumnCount;

        const operation = try parseOperation(fields[0]);
        const format = try parseFormat(fields[1]);
        try validateHexBits(fields[2], format);
        try validateHexBits(fields[3], format);
        const declared_output_class = try parseOutputClass(fields[4]);
        const derived_output_class = try deriveOutputClass(fields[3], format);
        if (declared_output_class != derived_output_class) {
            return error.OutputClassMismatch;
        }
        try validateMaxUlp(fields[5]);
        if (isSpecial(derived_output_class) and !std.mem.eql(u8, fields[5], "0")) {
            return error.InvalidMaxUlp;
        }

        const current = SortKey{
            .operation = operation,
            .format = format,
            .input_bits = fields[2],
        };
        if (previous) |prior| try validateSorted(prior, current);
        previous = current;
    }
}

fn validateTextEnvelope(source: []const u8, require_final_newline: bool) ValidationError!void {
    if (std.mem.startsWith(u8, source, "\xef\xbb\xbf")) return error.ByteOrderMark;
    if (std.mem.indexOfScalar(u8, source, '\r') != null) return error.CarriageReturn;
    if (require_final_newline) {
        if (source.len == 0) return error.MissingFinalNewline;
        if (source[source.len - 1] != '\n') return error.MissingFinalNewline;
    }
}

fn validateRootField(
    root_seen: *[12]bool,
    name: []const u8,
    value: []const u8,
) ValidationError!void {
    const key = parseRootKey(name) orelse return error.UnknownRootKey;
    const key_index = @intFromEnum(key);
    if (root_seen[key_index]) return error.DuplicateRootKey;
    root_seen[key_index] = true;

    switch (key) {
        .schema_version => try expectUnsigned(value, 1),
        .core_math_repository => try expectString(
            value,
            "https://gitlab.inria.fr/core-math/core-math.git",
        ),
        .core_math_revision => {
            const revision = try parseString(value);
            if (!std.mem.eql(
                u8,
                revision,
                "3bafed75e3c22399531857d63a3fa0e24bfb42fa",
            )) return error.InvalidPinnedValue;
            if (revision.len != 40) return error.InvalidPinnedValue;
            for (revision) |digit| {
                if (!isLowerHexDigit(digit)) return error.InvalidPinnedValue;
            }
        },
        .mpfr_precision_bits, .arb_precision_bits => try expectUnsigned(value, 512),
        .rounding => try expectString(value, "nearest_even"),
        .formats => try expectFormatArray(value),
        .reserved_formats => try expectStringArray(value, &.{"q"}),
        .rejected_formats => try expectStringArray(value, &.{ "q", "bfloat16" }),
        .columns => try expectStringArray(value, &.{
            "op",
            "format",
            "input_bits",
            "output_bits",
            "output_class",
            "max_ulp",
        }),
        .hexadecimal => try expectString(value, "lowercase_fixed_width"),
        .uncertainty_policy => try expectString(value, "fail_closed"),
    }
}

fn validateFunctionField(
    function: *Function,
    key: []const u8,
    value: []const u8,
) ValidationError!void {
    if (std.mem.eql(u8, key, "op")) {
        if (function.operation != null) return error.DuplicateFunctionKey;
        function.operation = try parseOperation(try parseString(value));
    } else if (std.mem.eql(u8, key, "format")) {
        if (function.format != null) return error.DuplicateFunctionKey;
        function.format = try parseFormat(try parseString(value));
    } else if (std.mem.eql(u8, key, "status")) {
        if (function.has_status) return error.DuplicateFunctionKey;
        function.has_status = true;
        const status = try parseString(value);
        if (!std.mem.eql(u8, status, "unsupported")) {
            return error.UnsupportedFunctionStatus;
        }
        function.unsupported = true;
    } else {
        return error.UnknownFunctionKey;
    }
}

fn finishFunction(
    function: Function,
    function_seen: *[3][3]bool,
    function_count: usize,
) ValidationError!void {
    const operation = function.operation orelse return error.MissingFunctionKey;
    const format = function.format orelse return error.MissingFunctionKey;
    if (!function.has_status or !function.unsupported) return error.MissingFunctionKey;

    const operation_index = @intFromEnum(operation);
    const format_index = @intFromEnum(format);
    if (function_seen[operation_index][format_index]) return error.DuplicateFunctionRow;
    if (operation_index * 3 + format_index != function_count) {
        return error.UnsortedFunctionRow;
    }
    function_seen[operation_index][format_index] = true;
}

fn requireAllRootKeys(root_seen: [12]bool) ValidationError!void {
    for (root_seen) |seen| {
        if (!seen) return error.MissingRootKey;
    }
}

fn parseRootKey(name: []const u8) ?RootKey {
    inline for (@typeInfo(RootKey).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseOperation(text: []const u8) ValidationError!Operation {
    if (std.mem.eql(u8, text, "exp")) return .exp;
    if (std.mem.eql(u8, text, "log")) return .log;
    if (std.mem.eql(u8, text, "sin")) return .sin;
    return error.UnknownOperation;
}

fn parseFormat(text: []const u8) ValidationError!Format {
    if (std.mem.eql(u8, text, "h")) return .h;
    if (std.mem.eql(u8, text, "f")) return .f;
    if (std.mem.eql(u8, text, "d")) return .d;
    if (std.mem.eql(u8, text, "q")) return error.ReservedFormat;
    if (std.mem.eql(u8, text, "bfloat16")) return error.RejectedFormat;
    return error.UnknownFormat;
}

fn parseOutputClass(text: []const u8) ValidationError!OutputClass {
    if (std.mem.eql(u8, text, "normal")) return .normal;
    if (std.mem.eql(u8, text, "subnormal")) return .subnormal;
    if (std.mem.eql(u8, text, "zero")) return .zero;
    if (std.mem.eql(u8, text, "infinity")) return .infinity;
    if (std.mem.eql(u8, text, "qnan")) return .qnan;
    return error.UnknownOutputClass;
}

fn parseString(value: []const u8) ValidationError![]const u8 {
    if (value.len < 2) return error.InvalidPinnedValue;
    if (value[0] != '"' or value[value.len - 1] != '"') {
        return error.InvalidPinnedValue;
    }
    const text = value[1 .. value.len - 1];
    if (std.mem.indexOfAny(u8, text, "\\\"") != null) return error.InvalidPinnedValue;
    return text;
}

fn expectString(value: []const u8, expected: []const u8) ValidationError!void {
    const actual = try parseString(value);
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidPinnedValue;
}

fn expectUnsigned(value: []const u8, expected: u16) ValidationError!void {
    const actual = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidPinnedValue;
    if (actual != expected) return error.InvalidPinnedValue;
}

fn expectStringArray(
    value: []const u8,
    expected: []const []const u8,
) ValidationError!void {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidPinnedValue;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (expected.len == 0) {
        if (elements.len != 0) return error.InvalidPinnedValue;
        return;
    }

    var iterator = std.mem.splitScalar(u8, elements, ',');
    var index: usize = 0;
    while (iterator.next()) |element| {
        if (index == expected.len) return error.InvalidPinnedValue;
        const actual = try parseString(std.mem.trim(u8, element, " \t"));
        if (!std.mem.eql(u8, actual, expected[index])) return error.InvalidPinnedValue;
        index += 1;
    }
    if (index != expected.len) return error.InvalidPinnedValue;
}

fn expectFormatArray(value: []const u8) ValidationError!void {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') {
        return error.InvalidPinnedValue;
    }
    const elements = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    const expected = [_]Format{ .h, .f, .d };
    var iterator = std.mem.splitScalar(u8, elements, ',');
    var index: usize = 0;
    while (iterator.next()) |element| {
        if (index == expected.len) return error.InvalidPinnedValue;
        const actual = try parseFormat(try parseString(std.mem.trim(u8, element, " \t")));
        if (actual != expected[index]) return error.InvalidPinnedValue;
        index += 1;
    }
    if (index != expected.len) return error.InvalidPinnedValue;
}

fn validateHexBits(text: []const u8, format: Format) ValidationError!void {
    if (text.len != format.hexadecimalDigits()) return error.InvalidHexWidth;
    for (text) |digit| {
        if (digit >= 'A' and digit <= 'F') return error.UppercaseHexDigit;
        if (!isLowerHexDigit(digit)) return error.InvalidHexDigit;
    }
}

fn isLowerHexDigit(digit: u8) bool {
    return (digit >= '0' and digit <= '9') or (digit >= 'a' and digit <= 'f');
}

fn validateMaxUlp(text: []const u8) ValidationError!void {
    if (text.len == 0) return error.InvalidMaxUlp;
    if (text.len > 1 and text[0] == '0') return error.InvalidMaxUlp;
    for (text) |digit| {
        if (digit < '0' or digit > '9') return error.InvalidMaxUlp;
    }
}

fn deriveOutputClass(text: []const u8, format: Format) ValidationError!OutputClass {
    const bits = std.fmt.parseUnsigned(u64, text, 16) catch return error.InvalidHexDigit;
    const exponent_mask: u64 = switch (format) {
        .h => 0x7c00,
        .f => 0x7f80_0000,
        .d => 0x7ff0_0000_0000_0000,
    };
    const fraction_mask: u64 = switch (format) {
        .h => 0x03ff,
        .f => 0x007f_ffff,
        .d => 0x000f_ffff_ffff_ffff,
    };
    const quiet_nan_mask: u64 = switch (format) {
        .h => 0x0200,
        .f => 0x0040_0000,
        .d => 0x0008_0000_0000_0000,
    };
    const exponent = bits & exponent_mask;
    const fraction = bits & fraction_mask;

    if (exponent == 0) {
        if (fraction == 0) return .zero;
        return .subnormal;
    }
    if (exponent != exponent_mask) return .normal;
    if (fraction == 0) return .infinity;
    if ((fraction & quiet_nan_mask) != 0) return .qnan;
    return .snan;
}

fn isSpecial(output_class: OutputClass) bool {
    return switch (output_class) {
        .normal, .subnormal => false,
        .zero, .infinity, .qnan, .snan => true,
    };
}

fn validateSorted(previous: SortKey, current: SortKey) ValidationError!void {
    const previous_operation = @intFromEnum(previous.operation);
    const current_operation = @intFromEnum(current.operation);
    if (current_operation < previous_operation) return error.UnsortedCorpusRow;
    if (current_operation > previous_operation) return;

    const previous_format = @intFromEnum(previous.format);
    const current_format = @intFromEnum(current.format);
    if (current_format < previous_format) return error.UnsortedCorpusRow;
    if (current_format > previous_format) return;

    switch (std.mem.order(u8, previous.input_bits, current.input_bits)) {
        .lt => {},
        .eq => return error.DuplicateCorpusRow,
        .gt => return error.UnsortedCorpusRow,
    }
}

test "embedded manifest has the pinned unsupported matrix" {
    try validateEmbeddedManifest();
}

test "manifest function status must remain unsupported" {
    var source: [manifest_text.len]u8 = undefined;
    @memcpy(&source, manifest_text);
    const status_index = std.mem.indexOf(u8, &source, "unsupported") orelse unreachable;
    source[status_index] = 'x';
    try std.testing.expectError(error.UnsupportedFunctionStatus, validateManifest(&source));
}

test "TSV rejects unknown operations and output classes" {
    try std.testing.expectError(
        error.UnknownOperation,
        validateTsv(
            "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
                "cos\th\t0000\t0000\tzero\t0\n",
        ),
    );
    try std.testing.expectError(
        error.UnknownOutputClass,
        validateTsv(
            "op\tformat\tinput_bits\toutput_bits\toutput_class\tmax_ulp\n" ++
                "exp\th\t0000\t0000\tsnan\t0\n",
        ),
    );
}
