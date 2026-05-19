const std = @import("std");
const assert = std.debug.assert;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

const max_boulder_number = std.math.maxInt(u15);

/// Used to compute the scale factor for the score of a boulder. Takes in the
/// number of tops of that boulder.
fn scaleFactor(num_tops: u32) f32 {
    return 1.0 / @as(f32, @floatFromInt(@max(1, num_tops)));
}

pub fn main() !void {
    var timer = std.time.Timer.start() catch unreachable;
    defer std.log.info("Completed in {:.3}ms", .{@as(f32, @floatFromInt(timer.read())) / std.time.ns_per_ms});

    var sfa = std.heap.stackFallback(128 * 1024, std.heap.page_allocator);
    const gpa = sfa.get();

    var out = std.fs.File.stdout();
    var iobuf: [1024]u8 = undefined;
    var writer = out.writer(&iobuf);

    const args = parseArgs(gpa) catch |e| help(e);
    if (args.csv_params) |params| {
        var prng = std.Random.DefaultPrng.init(0);
        const rng = prng.random();
        const descr = try params.generateRandomDescriptors(gpa, rng);
        try writeTestCsv(&writer.interface, rng, descr, params);
        try writer.interface.flush();
        return;
    }

    const score_file = blk: {
        var tmpsfa = std.heap.stackFallback(128 * 1024, std.heap.page_allocator);
        const score_file = try ScoreFile.init(gpa, tmpsfa.get(), args.scores, args.csv_sub_path);
        break :blk score_file;
    };

    if (args.debug) {
        try writeStuffAsJson(&writer.interface, score_file, args.prettify_json);
        try writer.interface.writeAll("\n\n");
        try writer.interface.flush();
        return;
    }

    const summary = try Summary.init(gpa, args.scores, score_file);
    try writeStuffAsJson(&writer.interface, summary, args.prettify_json);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn writeStuffAsJson(
    writer: *std.Io.Writer,
    stuff: anytype,
    prettify: bool,
) std.Io.Writer.Error!void {
    try (std.json.Formatter(@TypeOf(stuff)){
        .value = stuff,
        .options = if (prettify) .{ .whitespace = .indent_2 } else .{},
    }).format(writer);
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

const boulder_starts_with = "boulder ";
const email_starts_with = "email";
const first_name_starts_with = "first name";
const last_name_starts_with = "last name";
const category_starts_with = "category";

const pattern = struct {
    pub fn isBoulderColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, boulder_starts_with);
    }

    pub fn extractBoulderNumber(
        lowercase_boulder_column_name: []const u8,
    ) !u15 {
        return std.fmt.parseInt(u15, lowercase_boulder_column_name[boulder_starts_with.len..], 10);
    }

    pub fn isEmailColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, email_starts_with);
    }

    pub fn isFirstNameColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, first_name_starts_with);
    }

    pub fn isLastNameColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, last_name_starts_with);
    }

    pub fn isCategoryColumn(
        lowercase_name: []const u8,
    ) bool {
        return std.mem.startsWith(u8, lowercase_name, category_starts_with);
    }
};

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

    fn init(
        gpa: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        scores: Args.Scores,
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

        for (competitors.items) |*competitor| {
            for (competitor.results, boulder_top_data) |result, top_data| {
                competitor.score += top_data.calculateScoreFor(scores, competitor.category, result);
            }
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

            pub fn initBoulder(boulder_number: u15) Descriptor {
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
    prettify_json: bool,
    debug: bool,
    csv_params: ?CsvOpts,

    const CsvOpts = struct {
        num_competitors: u16 = 1000,
        num_boulders: u15 = max_boulder_number,
        num_junk_columns: u32 = 1000,
        min_junk_line_len: u32 = 10,
        max_junk_line_len: u32 = 20,

        fn generateRandomDescriptors(
            self: CsvOpts,
            gpa: std.mem.Allocator,
            rng: std.Random,
        ) ![]ScoreFile.Header.Descriptor {
            var descriptors = std.ArrayList(ScoreFile.Header.Descriptor).empty;
            try descriptors.appendSlice(gpa, &.{ .category, .last_name, .email, .first_name });

            for (1..@as(u16, self.num_boulders) + 1) |b| {
                try descriptors.append(gpa, .initBoulder(@intCast(b)));
            }

            try descriptors.appendNTimes(gpa, .skip, self.num_junk_columns);

            // dont fuck with category
            rng.shuffle(ScoreFile.Header.Descriptor, descriptors.items[1..]);

            return descriptors.toOwnedSlice(gpa);
        }
    };

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

fn parseFlagArg(
    comptime long_name: []const u8,
    comptime short_name: []const u8,
    arg: [:0]const u8,
) bool {
    return eql(u8, arg, "-" ++ short_name) or eql(u8, arg, "--" ++ long_name);
}

fn help(e: ?anyerror) noreturn {
    const usage =
        \\USAGE
        \\      voltage [OPTIONS] <FILE>
        \\
        \\DESCRIPTION
        \\      Reads in a score sheet csv file and computes the score for each
        \\      competitor based on the internal scale factor function.
        \\
        \\FILE FORMAT
        \\      The program expects a csv with column names `First Name`, `Last Name`,
        \\      `Email`, `Category` and `Boulder n`. The case of the names doesn't matter.
        \\      The `n` in a boulder column counts up from 1 and can be at most 32767.
        \\      They need not be consecutive. Because I am lazy the `Category` column
        \\      must come before the `Boulder *` columns.
        \\
        \\SCORE CALCULATION
        \\      A `result` refers to either a `zone`, `top` or `flash`. The
        \\      `flash` result is treated as a special form of `top` so it's scale
        \\      factor is the same. The adjusted score for a specific result is
        \\      calculated as follows:
        \\
        \\      `starting_score_for_result * scaleFactor(num_competitors_with_same_result)`
        \\
        \\      The `scaleFactor` function outputs a number between 1 and 0
        \\      determined by `num_competitors_with_same_result`. The default scale
        \\      factor function is `1/n`.
        \\
        \\      By adding all the adjusted scores for all boulders you get the
        \\      final score for a competitor.
        \\
        \\OPTIONS
        \\      General remarks: Command-line options like '-l'/'--language'
        \\      that take values can be specified as either '--language value',
        \\      '--language=value', '-l value' or '-l=value'.
        \\
        \\      -h, --help
        \\
        \\              Print this menu and exit.
        \\
        \\      -p, --prettify
        \\
        \\              Prettify the json output,
        \\
        \\      -z, --zone-score <unsigned int>
        \\
        \\              The default score for getting a zone.
        \\
        \\      -t, --top-score <unsigned int>
        \\
        \\              The default score for getting a top.
        \\
        \\      -f, --flash-score <unsigned int>
        \\
        \\              The default score for getting a flash.
        \\
        \\      -o, --output-csv
        \\
        \\              Write a csv to stdout in the correct format for this
        \\              parser filled with junk values and exit. Mainly used for testing.
        \\
        \\      -j, --num-junk-columns <u32>
        \\
        \\              The number of columns in the csv which will be ignored.
        \\              Used to slow down parsing for testing.
        \\
        \\      -min, --min-junk-line-len <u32>
        \\
        \\              Minium characters in a row entry for a junk column. Used
        \\              to slow down parsing for testing.
        \\
        \\      -max, --max-junk-line-len <u32>
        \\
        \\              Maximum characters in a row entry for a junk column.
        \\              Used to slow down parsing for testing. Should be more than minimum
        \\              characters.
        \\
        \\      -c, --num-competitors <u16>
        \\
        \\              Number of competitors to generate. Used to slow down
        \\              parsing for testing.
        \\
        \\      -b, --num-boulders <u16>
        \\
        \\              Number of boulder entries to generate. Used to slow down
        \\              parsing for testing.
        \\
        \\      -d, --debug <u16>
        \\
        \\              Write the parsed file to stdout.
    ;

    if (e) |err| std.debug.print("error: {t}\n\n", .{err});
    std.debug.print("{s}\n", .{usage});
    std.process.exit(0);
}
fn parseArgs(_: std.mem.Allocator) !Args {
    var csv_sub_path: [:0]const u8 = &.{};
    var zone_score: i32 = Args.Scores.default_flash;
    var top_score: i32 = Args.Scores.default_flash;
    var flash_score: i32 = Args.Scores.default_flash;
    var debug: bool = false;
    var prettify: bool = false;
    var wants_csv: bool = false;
    var csv_params = Args.CsvOpts{};

    var it = std.process.args();

    if (!it.skip()) return error.ArgParseFailed;

    while (it.next()) |arg| {
        if (try parseIntArg(i32, "zone-score", "z", arg, &it)) |zonesc| {
            zone_score = zonesc;
        } else if (parseFlagArg("help", "h", arg)) {
            help(null);
        } else if (try parseIntArg(i32, "top-score", "t", arg, &it)) |topsc| {
            top_score = topsc;
        } else if (try parseIntArg(i32, "flash-score", "f", arg, &it)) |flashsc| {
            flash_score = flashsc;
        } else if (parseFlagArg("output-csv", "o", arg)) {
            wants_csv = true;
        } else if (parseFlagArg("prettify", "p", arg)) {
            prettify = true;
        } else if (try parseIntArg(u32, "num-junk-columns", "j", arg, &it)) |num_junk_columns| {
            wants_csv = true;
            csv_params.num_junk_columns = num_junk_columns;
        } else if (try parseIntArg(u32, "min-junk-line-len", "min", arg, &it)) |min_junk_line_len| {
            wants_csv = true;
            csv_params.min_junk_line_len = min_junk_line_len;
        } else if (try parseIntArg(u32, "max-junk-line-len", "max", arg, &it)) |max_junk_line_len| {
            wants_csv = true;
            csv_params.max_junk_line_len = max_junk_line_len;
        } else if (try parseIntArg(u16, "num-competitors", "c", arg, &it)) |num_competitors| {
            wants_csv = true;
            csv_params.num_competitors = num_competitors;
        } else if (try parseIntArg(u15, "num-boulders", "b", arg, &it)) |num_boulders| {
            wants_csv = true;
            csv_params.num_boulders = num_boulders;
        } else if (parseFlagArg("debug", "d", arg)) {
            debug = true;
        } else {
            csv_sub_path = arg;
        }
    }

    if (csv_sub_path.len == 0 and !debug and !wants_csv) return error.ExpectedCSVPath;

    return Args{
        .csv_sub_path = csv_sub_path,
        .scores = .{
            .zone = @floatFromInt(zone_score),
            .top = @floatFromInt(top_score),
            .flash = @floatFromInt(flash_score),
        },
        .csv_params = if (wants_csv) csv_params else null,
        .prettify_json = prettify,
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

fn writeTestCsv(
    writer: *std.Io.Writer,
    rng: std.Random,
    descriptors: []const ScoreFile.Header.Descriptor,
    opts: Args.CsvOpts,
) std.Io.Writer.Error!void {
    const special_chars = ",\"";
    const junk_letters: []const u8 = std.ascii.letters ++ " 0123456789'\\[]{}~!@#$%^&*()`" ++ special_chars;

    // write header
    for (0.., descriptors) |i, d| {
        try writer.writeByte('"');

        switch (d) {
            .skip => {
                const junk_size = rng.intRangeAtMost(usize, opts.min_junk_line_len, opts.max_junk_line_len);
                for (0..junk_size) |_| {
                    const junk_index = rng.intRangeLessThan(usize, 0, junk_letters.len);
                    const letter = junk_letters[junk_index];
                    if (std.mem.containsAtLeastScalar(u8, special_chars, 1, letter)) {
                        @branchHint(.unlikely);
                        try writer.writeByte('\\');
                    }
                    try writer.writeByte(letter);
                }
            },
            .email => try writer.writeAll(email_starts_with),
            .first_name => try writer.writeAll(first_name_starts_with),
            .last_name => try writer.writeAll(last_name_starts_with),
            .category => try writer.writeAll(category_starts_with),
            _ => {
                try writer.writeAll(boulder_starts_with);
                try writer.printInt(1 + d.asBoulderIndex().?, 10, .lower, .{});
            },
        }

        try writer.writeByte('"');
        if (i != descriptors.len - 1) {
            try writer.writeByte(',');
        }
    }

    // write competitors
    for (0..opts.num_competitors) |_| {
        try writer.writeByte('\n');
        for (0.., descriptors) |i, d| {
            try writer.writeByte('"');

            switch (d) {
                .skip => {
                    const junk_size = rng.intRangeAtMost(usize, opts.min_junk_line_len, opts.max_junk_line_len);
                    for (0..junk_size) |_| {
                        const junk_index = rng.intRangeLessThan(usize, 0, junk_letters.len);
                        const letter = junk_letters[junk_index];
                        if (std.mem.containsAtLeastScalar(u8, special_chars, 1, letter)) {
                            @branchHint(.unlikely);
                            try writer.writeByte('\\');
                        }
                        try writer.writeByte(letter);
                    }
                },
                .email, .first_name, .last_name => {
                    const size = rng.intRangeAtMost(usize, 10, 50);
                    for (0..size) |_| {
                        try writer.writeByte(std.ascii.letters[rng.intRangeLessThan(usize, 0, std.ascii.letters.len)]);
                    }
                },
                .category => try writer.writeAll(@tagName(rng.enumValue(Category))),
                _ => {
                    const result = rng.enumValue(BoulderResult);
                    if (result == .no_send and rng.boolean()) {
                        try writer.writeAll(&.{});
                    } else {
                        try writer.writeAll(@tagName(result));
                    }
                },
            }

            try writer.writeByte('"');
            if (i != descriptors.len - 1) {
                try writer.writeByte(',');
            }
        }
    }
}
