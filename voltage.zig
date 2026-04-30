const std = @import("std");
const assert = std.debug.assert;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

const boulder_pattern = "boulder ";
const max_boulder_number = 50;

/// Used to compute the scale factor for the score of a boulder. Takes in the
/// number of tops of that boulder.
fn scaleFactor(num_tops: anytype) f32 {
    return 1.0 / @as(f32, @floatFromInt(@max(1, num_tops)));
}

const Tops = struct {
    flashes: u32 = 0,
    tops: u32 = 0,
    zones: u32 = 0,

    fn calculateScoreFor(
        self: Tops,
        scores: Args.Scores,
        result: BoulderResult,
    ) f32 {
        return switch (result) {
            .no_send => 0,
            .zone => scores.zone * scaleFactor(self.tops + self.flashes + self.zones),
            .top => scores.top * scaleFactor(self.tops + self.flashes),
            .flash => scores.flash * scaleFactor(self.tops + self.flashes),
        };
    }
};

const Category = enum {
    mens,
    womens,

    fn parse(string: []const u8) error{CategoryParseError}!Category {
        const parsed = std.meta.stringToEnum(Category, string);
        return parsed orelse error.CategoryParseError;
    }
};

const pattern = struct {
    pub fn isBoulderColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, boulder_pattern);
    }

    pub fn extractBoulderNumber(
        lowercase_boulder_column_name: []const u8,
    ) !u16 {
        return std.fmt.parseInt(u16, lowercase_boulder_column_name[boulder_pattern.len..], 10);
    }

    pub fn isEmailColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, "email");
    }

    pub fn isFirstNameColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, "first name");
    }

    pub fn isLastNameColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, "last name");
    }

    pub fn isCategoryColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, "category");
    }
};

pub fn main() !void {
    var sfa = std.heap.stackFallback(128 * 1024, std.heap.page_allocator);
    const gpa = sfa.get();
    defer std.log.info("fba end index at {}/{} = {:.2}%", .{
        sfa.fixed_buffer_allocator.end_index,
        sfa.fixed_buffer_allocator.buffer.len,
        100 * @as(f32, @floatFromInt(sfa.fixed_buffer_allocator.end_index)) / @as(f32, @floatFromInt(sfa.fixed_buffer_allocator.buffer.len)),
    });

    const args = try parseArgs(gpa);
    const score_file = try ScoreFile.parse(gpa, std.heap.page_allocator, args.csv_sub_path);

    for (score_file.competitors) |*competitor| {
        for (competitor.results, score_file.boulders) |result, top_data| {
            competitor.score += top_data.calculateScoreFor(args.scores, competitor.category, result);
        }
    }

    var out = std.fs.File.stdout();
    var iobuf: [1024]u8 = undefined;
    var writer = out.writer(&iobuf);

    if (args.debug) {
        try (std.json.Formatter(ScoreFile){
            .value = score_file,
            .options = .{ .whitespace = .indent_2 },
        }).format(&writer.interface);
        try writer.interface.writeAll("\n\n");
    }

    const summary = try Summary.init(gpa, args.scores, score_file);

    try (std.json.Formatter(Summary){
        .value = summary,
        .options = .{ .whitespace = .indent_2 },
    }).format(&writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

const Summary = struct {
    /// keyed by the category. Each competitor list should be sorted by score
    competitor_by_category: std.json.ArrayHashMap([]Competitor),
    boulders: []Boulder,

    const Boulder = struct {
        boulder: u16 = undefined,
        men_points: struct { flash: f32, top: f32, zone: f32 } = undefined,
        women_points: struct { flash: f32, top: f32, zone: f32 } = undefined,
    };

    const Competitor = struct {
        first_name: []const u8,
        last_name: []const u8,
        email: []const u8,
        score: f32,

        const sortctx = struct {
            fn lt(_: @This(), lhs: Competitor, rhs: Competitor) bool {
                return lhs.score > rhs.score;
            }
        };
    };

    pub fn init(
        gpa: std.mem.Allocator,
        scores: Args.Scores,
        score_file: ScoreFile,
    ) !Summary {
        var competitor_by_category = std.StringArrayHashMapUnmanaged([]Competitor).empty;
        const categories = @typeInfo(Category).@"enum".fields;
        try competitor_by_category.ensureUnusedCapacity(gpa, categories.len);

        inline for (categories) |category| {
            var competitors = try std.ArrayList(Competitor).initCapacity(gpa, score_file.competitors.len);
            for (score_file.competitors) |competitor| {
                if (@intFromEnum(competitor.category) == category.value) {
                    competitors.appendAssumeCapacity(.{
                        .first_name = competitor.first_name,
                        .last_name = competitor.last_name,
                        .email = competitor.email,
                        .score = competitor.score,
                    });
                }
            }

            std.mem.sortUnstable(Competitor, competitors.items, Competitor.sortctx{}, Competitor.sortctx.lt);

            competitor_by_category.putAssumeCapacityNoClobber(category.name, try competitors.toOwnedSlice(gpa));
        }

        const boulders = try gpa.alloc(Boulder, score_file.header.num_boulders);
        @memset(boulders, .{});
        for (score_file.header.column_descriptors) |descriptor| {
            if (descriptor.asBoulderIndex()) |bidx| {
                const data = score_file.boulders[bidx];
                boulders[bidx] = Boulder{
                    .boulder = bidx,
                    .men_points = .{
                        .flash = data.calculateScoreFor(scores, .mens, .flash),
                        .top = data.calculateScoreFor(scores, .mens, .top),
                        .zone = data.calculateScoreFor(scores, .mens, .zone),
                    },
                    .women_points = .{
                        .flash = data.calculateScoreFor(scores, .womens, .flash),
                        .top = data.calculateScoreFor(scores, .womens, .top),
                        .zone = data.calculateScoreFor(scores, .womens, .zone),
                    },
                };
            }
        }

        return Summary{
            .competitor_by_category = .{ .map = competitor_by_category },
            .boulders = boulders,
        };
    }
};

const BoulderData = struct {
    mens: Tops = .{},
    womens: Tops = .{},

    fn calculateScoreFor(
        self: BoulderData,
        scores: Args.Scores,
        category: Category,
        result: BoulderResult,
    ) f32 {
        return switch (category) {
            .mens => self.mens.calculateScoreFor(scores, result),
            .womens => self.womens.calculateScoreFor(scores, result),
        };
    }

    fn processResult(
        self: *BoulderData,
        category: Category,
        result: BoulderResult,
    ) void {
        switch (category) {
            .mens => switch (result) {
                .no_send => {},
                .zone => self.mens.zones += 1,
                .top => self.mens.tops += 1,
                .flash => self.mens.flashes += 1,
            },
            .womens => switch (result) {
                .no_send => {},
                .zone => self.womens.zones += 1,
                .top => self.womens.tops += 1,
                .flash => self.womens.flashes += 1,
            },
        }
    }
};

const BoulderResult = enum {
    no_send,
    zone,
    top,
    flash,

    pub fn parse(string: []const u8) error{FailedToParseBoulderResult}!BoulderResult {
        if (string.len == 0) return .no_send;
        const parsed = std.meta.stringToEnum(BoulderResult, string);
        return parsed orelse error.FailedToParseBoulderResult;
    }
};

const ScoreFile = struct {
    header: Header,
    boulders: []BoulderData,
    competitors: []Competitor,

    const Competitor = struct {
        first_name: []const u8,
        last_name: []const u8,
        email: []const u8,
        category: Category,
        results: []BoulderResult,
        score: f32,
    };

    fn parse(
        gpa: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        sub_path: [:0]const u8,
    ) !ScoreFile {
        var file_data_list = blk: {
            const file = try std.fs.cwd().openFile(sub_path, .{});
            defer file.close();

            var iobuf: [1024]u8 = undefined;
            var reader = file.reader(&iobuf);

            var list = std.ArrayList(u8).empty;
            try reader.interface.appendRemaining(temp_allocator, &list, .unlimited);
            break :blk list;
        };
        defer file_data_list.deinit(temp_allocator);

        const raw_file_data = file_data_list.items;

        var lines = std.mem.splitScalar(u8, raw_file_data, '\n');
        const header_line = lines.next() orelse return error.NotEnoughLinesInFile;
        const file_header = try Header.parse(gpa, header_line);

        assert(file_header.num_boulders > 0);
        const boulder_top_data = try gpa.alloc(BoulderData, file_header.num_boulders);
        @memset(boulder_top_data, .{});

        // a bit hopeful :)
        var competitors = try std.ArrayList(Competitor).initCapacity(gpa, 500);
        errdefer competitors.deinit(gpa);

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const competitor = try parseCompetitorLine(gpa, file_header, boulder_top_data, line);
            try competitors.append(gpa, competitor);
        }

        return ScoreFile{
            .header = file_header,
            .boulders = boulder_top_data,
            .competitors = try competitors.toOwnedSlice(gpa),
        };
    }

    const Header = struct {
        num_boulders: usize,
        column_descriptors: []Descriptor,

        /// Every descriptor which is not one of the named ones below is a
        /// boulder number
        const Descriptor = enum(u16) {
            skip = std.math.maxInt(u16),

            email = max_boulder_number + 1,
            first_name = max_boulder_number + 2,
            last_name = max_boulder_number + 3,
            category = max_boulder_number + 4,

            // must be a boulder number otherwise
            _,

            pub fn initBoulder(boulder_number: u16) Descriptor {
                assert(boulder_number > 0);
                assert(boulder_number <= max_boulder_number);
                return @enumFromInt(boulder_number - 1);
            }

            pub fn asBoulderIndex(self: Descriptor) ?u16 {
                const boulder_number = @intFromEnum(self);
                if (boulder_number > max_boulder_number) return null;
                return boulder_number;
            }
        };

        pub fn parse(
            gpa: std.mem.Allocator,
            header_line: []const u8,
        ) !Header {
            var index_descriptor_list = std.ArrayList(Descriptor).empty;
            errdefer index_descriptor_list.deinit(gpa);

            var num_boulders: usize = 0;

            var it = std.mem.splitSequence(u8, header_line, "\",\"");
            while (it.next()) |column| {
                const descriptor = try index_descriptor_list.addOne(gpa);
                const col = lower(trim(column));

                if (pattern.isBoulderColumn(col)) {
                    const bnum = try pattern.extractBoulderNumber(col);
                    num_boulders += 1;
                    descriptor.* = .initBoulder(bnum);
                } else if (pattern.isFirstNameColumn(col)) {
                    descriptor.* = .first_name;
                } else if (pattern.isLastNameColumn(col)) {
                    descriptor.* = .last_name;
                } else if (pattern.isEmailColumn(col)) {
                    descriptor.* = .email;
                } else if (pattern.isCategoryColumn(col)) {
                    descriptor.* = .category;
                } else {
                    descriptor.* = .skip;
                }
            }

            return Header{
                .num_boulders = num_boulders,
                .column_descriptors = try index_descriptor_list.toOwnedSlice(gpa),
            };
        }
    };

    fn parseCompetitorLine(
        gpa: std.mem.Allocator,
        header: Header,
        boulder_top_data: []BoulderData,
        competitor_line: []const u8,
    ) !Competitor {
        var first_name: ?[]const u8 = null;
        var last_name: ?[]const u8 = null;
        var email: ?[]const u8 = null;
        var category: ?Category = null;
        const results: []BoulderResult = try gpa.alloc(BoulderResult, header.num_boulders);
        @memset(results, BoulderResult.no_send);

        assert(boulder_top_data.len == results.len);

        var it = std.mem.splitSequence(u8, competitor_line, "\",\"");
        for (header.column_descriptors) |descriptor| {
            const entry = it.next() orelse return error.ExpectedAnotherEntry;
            switch (descriptor) {
                .skip => {},
                .email => email = try gpa.dupe(u8, trim(entry)),
                .first_name => first_name = try gpa.dupe(u8, trim(entry)),
                .last_name => last_name = try gpa.dupe(u8, trim(entry)),
                .category => category = try Category.parse(lower(trim(entry))),
                _ => {
                    const cat = category orelse return error.CategoryColumnMustBeBeforeBoulderColumns;
                    const result = try BoulderResult.parse(lower(trim(entry)));

                    const index = descriptor.asBoulderIndex() orelse unreachable;
                    results[index] = result;
                    boulder_top_data[index].processResult(cat, result);
                },
            }
        }

        return Competitor{
            .first_name = first_name orelse return error.ExpectedFirstName,
            .last_name = last_name orelse return error.ExpectedLastName,
            .category = category orelse return error.ExpectedCategory,
            .email = email orelse return error.ExpectedEmail,
            .results = results,
            .score = 0,
        };
    }
};

const Args = struct {
    csv_sub_path: [:0]const u8,
    scores: Scores,
    debug: bool,

    const Scores = struct {
        flash: f32 = default_flash,
        top: f32 = default_top,
        zone: f32 = default_zone,

        const default_flash = 1100;
        const default_top = 1000;
        const default_zone = 500;
    };

    pub fn deinit(_: *Args, _: std.mem.Allocator) void {}
};

fn parseIntArg(
    comptime I: type,
    comptime long_name: []const u8,
    comptime short_name: []const u8,
    arg: [:0]const u8,
    it: *std.process.ArgIterator,
) !?I {
    if (eql(u8, arg, "-" ++ short_name) or eql(u8, arg, "--" ++ long_name)) {
        const buf = it.next() orelse return error.MoreArgsRequired;
        return try std.fmt.parseInt(I, trim(buf), 10);
    }

    if (startsWith(u8, arg, "-" ++ short_name ++ "=")) {
        return try std.fmt.parseInt(I, trim(arg[short_name.len + 2 ..]), 10);
    }

    if (startsWith(u8, arg, "--" ++ long_name ++ "=")) {
        return try std.fmt.parseInt(I, trim(arg[long_name.len + 3 ..]), 10);
    }

    return null;
}

fn parseStringArg(
    comptime long_name: []const u8,
    comptime short_name: []const u8,
    arg: [:0]const u8,
    it: *std.process.ArgIterator,
) !?[:0]const u8 {
    if (eql(u8, arg, "-" ++ short_name) or eql(u8, arg, "--" ++ long_name)) {
        return it.next() orelse return error.MoreArgsRequired;
    }

    if (startsWith(u8, arg, "-" ++ short_name ++ "=")) {
        return arg[short_name.len + 2 ..];
    }

    if (startsWith(u8, arg, "--" ++ long_name ++ "=")) {
        return arg[long_name.len + 3 ..];
    }

    return null;
}

fn parseFlagArg(
    comptime long_name: []const u8,
    comptime short_name: []const u8,
    arg: [:0]const u8,
) !?bool {
    if (eql(u8, arg, "-" ++ short_name) or eql(u8, arg, "--" ++ long_name)) {
        return true;
    }

    return null;
}

fn parseArgs(_: std.mem.Allocator) !Args {
    var csv_sub_path: [:0]const u8 = "/home/jacob/Downloads/Resistance Qualifiers.csv";
    var zone_score: i32 = Args.Scores.default_flash;
    var top_score: i32 = Args.Scores.default_flash;
    var flash_score: i32 = Args.Scores.default_flash;
    var debug: bool = false;

    var it = std.process.args();

    if (!it.skip()) return error.ArgParseFailed;

    while (it.next()) |arg| {
        if (try parseStringArg("csv-sub-path", "p", arg, &it)) |sub_path| {
            csv_sub_path = sub_path;
        } else if (try parseIntArg(i32, "zone-score", "z", arg, &it)) |zonesc| {
            zone_score = zonesc;
        } else if (try parseIntArg(i32, "top-score", "t", arg, &it)) |topsc| {
            top_score = topsc;
        } else if (try parseIntArg(i32, "flash-score", "f", arg, &it)) |flashsc| {
            flash_score = flashsc;
        } else if (try parseFlagArg("debug", "d", arg)) |flag| {
            debug = flag;
        }
    }

    return Args{
        .csv_sub_path = csv_sub_path,
        .scores = .{
            .zone = @floatFromInt(zone_score),
            .top = @floatFromInt(top_score),
            .flash = @floatFromInt(flash_score),
        },
        .debug = debug,
    };
}

// in-place lowercase-ify
fn lower(in: []const u8) []const u8 {
    for (@constCast(in)) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
    }
    return in;
}

fn trim(in: []const u8) []const u8 {
    const trimchars: []const u8 = std.ascii.whitespace ++ "\",\\";
    return std.mem.trim(u8, in, trimchars);
}
