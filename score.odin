package score

import "base:runtime"
import "core:encoding/csv"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strconv"
import "core:strings"

BOULDERS_START_AT_NUMBER :: 1
TOP_N_BOULDERS :: 10

contains :: strings.contains
starts_with :: strings.starts_with
dist :: strings.levenshtein_distance

boulder_statistics: [BoulderTag]Boulder

// odinfmt: disable
BoulderTag :: enum {
	b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11, b12, b13, b14, b15,
	b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31,
	b32, b33, b34, b35, b36, b37, b38, b39, b40, b41, b42, b43, b44, b45, b46, b47,
	b48, b49, b50, b51, b52, b53, b54, b55, b56, b57, b58, b59, b60, b61, b62, b63,
}
// odinfmt: enable

Column :: int

Category :: enum {
	mens,
	womens,
}

Competitor :: struct #all_or_none {
	submission_time: i64,
	email:           string,
	first_name:      string,
	last_name:       string,
	top:             bit_set[BoulderTag],
	flash:           bit_set[BoulderTag],
	category:        Category,
	score:           f32,
}

Boulder :: struct {
	tops:    u32,
	flashes: u32,
}

main :: proc() {
	context.logger.procedure = logfn
	context.logger.lowest_level = .Info

	csv_data, csv_err := os.read_entire_file(os.stdin, context.allocator)
	assert(csv_err == nil)

	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 512 * 1024))
	context.allocator = mem.arena_allocator(&arena)
	defer fmt.eprintfln(
		"len={}\noffset={}\npeak_used={}\ntemp_count={}",
		len(arena.data),
		arena.offset,
		arena.peak_used,
		arena.temp_count,
	)

	// Parse csv :)
	competitors := make([dynamic]Competitor, 0, 256)
	parse_competitor_csv(&competitors, csv_data)

	// Remove duplicate entries
	remove_duplicate_competitors(&competitors)

	// Calculate the total number of tops and stuff for each boulder
	for c in competitors[:] {
		for b in c.flash {boulder_statistics[b].flashes += 1}
		for b in c.top {boulder_statistics[b].tops += 1}
	}

	// Calculate the player scores
	for &c in competitors[:] {c.score = competitor_score(c)}

	// Sort by man/women and by score
	sort.quick_sort_proc(competitors[:], proc(lhs, rhs: Competitor) -> int {
		if rhs.category == lhs.category {
			return int(rhs.score - lhs.score)
		} else {
			return int(rhs.category) - int(lhs.category)
		}
	})

	for c in competitors[:] {
		fmt.eprintfln(
			"{} %5.2f : {} {} | {}",
			c.category,
			c.score,
			c.first_name,
			c.last_name,
			c.email,
		)
	}

	// TODO: calculate the boulder scores
	// TODO: calculate the score of each competitor
}

decay :: proc(b: Boulder) -> f32 {
	k :: 0.01
	return math.exp(-k * f32(b.tops + b.flashes))
}

top_score :: proc(b: Boulder) -> f32 {
	return 10_000 * decay(b)
}

flash_score :: proc(b: Boulder) -> f32 {
	return 1.1 * top_score(b)
}

// Only adds the top_n boulders to the score
//
// odinfmt: disable
competitor_score :: proc(c: Competitor) -> f32 {
	scores: [len([BoulderTag]byte)]f32

	top := c.top
	flash := c.flash
	for b, tag in boulder_statistics {
		if tag in flash    { scores[tag] = flash_score(b) }
        else if tag in top { scores[tag] = top_score(b) }
        else               { scores[tag] = 0 }
	}
	assert(len(scores) == len(boulder_statistics))

    sort.quick_sort(scores[:])
    start := len(scores) - min(len(scores), int(TOP_N_BOULDERS))
    return math.sum(scores[start:])
}
// odinfmt: enable

// Returns max u32 if nothing is found
take_first_number :: proc(s: string) -> (ret: u32) {
	in_number := false

	for b in transmute([]byte)s {
		is_digit := '0' <= b && b <= '9'

		if is_digit {
			in_number = true
			ret = ret * 10 + u32(b - '0')
		} else if in_number {
			break
		}
	}

	if !in_number {
		ret = bits.U32_MAX
	}

	return
}

// parses a string into a competitor array
parse_competitor_csv :: proc(competitors: ^[dynamic]Competitor, data: []byte) {
	// Initialize the csv reader
	r: csv.Reader
	r.trim_leading_space = true
	r.reuse_record = true
	r.reuse_record_buffer = false

	csv.reader_init_with_string(&r, string(data))
	defer csv.reader_destroy(&r)

	// Extract the first line to define the indicies of the columns we care
	// about for scoring
	submission_time, category, email, first_name, last_name, boulder_csv_column :=
		csv_figure_out_where_shit_is(&r)

	// Iterate over the lines
	for entry in csv.iterator_next(&r) {
		submission_time: i64 = parse_submission_time(entry[submission_time])

		ctgy: Category
		if is_mens_column(entry[category]) {
			ctgy = .mens
		} else if is_womens_column(entry[category]) {
			ctgy = .womens
		} else {
			unreachable()
		}

		top, flash: bit_set[BoulderTag]
		for column, tag in boulder_csv_column {
			if is_flash_column(entry[column]) {
				flash |= {tag}
			} else if is_top_column(entry[column]) {
				top |= {tag}
			}
		}

		append(
			competitors,
			Competitor {
				email = strings.trim(entry[email], " "),
				first_name = strings.trim(entry[first_name], " "),
				last_name = strings.trim(entry[last_name], " "),
				category = ctgy,
				submission_time = submission_time,
				top = top,
				flash = flash,
				score = 0,
			},
		)
	}

	return
}

// 2025/08/16 10:53:39 am
// 2025/08/16 5:09:55 pm
parse_submission_time :: proc(str: string) -> (kinda_timestamp: i64) {
	hour, minute, second: i64

	space0 := strings.index_byte(str, ' ')
	colon0 := strings.index_byte(str[space0 + 1:], ':') + space0 + 1
	colon1 := strings.index_byte(str[colon0 + 1:], ':') + colon0 + 1
	space1 := strings.index_byte(str[colon1 + 1:], ' ') + colon1 + 1

	ok: bool

	hour, ok = strconv.parse_i64(str[space0 + 1:colon0]); assert(ok)
	minute, ok = strconv.parse_i64(str[colon0 + 1:colon1]); assert(ok)
	second, ok = strconv.parse_i64(str[colon1 + 1:space1]); assert(ok)


	if strings.ends_with(str, "pm") {
		hour += 12
	}

	kinda_timestamp = hour * 60 * 60 + minute * 60 + second
	return
}

// odinfmt: disable
csv_figure_out_where_shit_is :: proc(
	reader: ^csv.Reader,
) -> (
    submission_time, category, email, first_name, last_name: int,
	boulder_csv_column: [BoulderTag]Column,
) {
    submission_time = -1
    category = -1
    email = -1
    first_name = -1
    last_name = -1

	record, _, _, _ := csv.iterator_next(reader)
	for str, col in record {
		if is_email_column(str)                { email = col }
        else if is_submission_time_column(str) { submission_time = col }
        else if is_first_name_column(str)      { first_name = col }
        else if is_last_name_column(str)       { last_name = col }
        else if is_category_column(str)        { category = col }
        else if is_boulder_column(str) {
			boulder_number := take_first_number(str)
			if boulder_number == bits.U32_MAX {continue}

			assert(boulder_number >= BOULDERS_START_AT_NUMBER)
            tag:=BoulderTag(boulder_number - BOULDERS_START_AT_NUMBER)
			boulder_csv_column[tag] = col
		}
	}

    assert(submission_time >= 0)
    assert(category >= 0)
    assert(email >= 0)
    assert(first_name >= 0)
    assert(last_name >= 0)

    return
}
// odinfmt: enable

is_boulder_column :: proc(str: string) -> bool {
	return contains(str, "Boulder")
}
is_email_column :: proc(str: string) -> bool {
	return starts_with(str, "Username") || starts_with(str, "Email")
}
is_submission_time_column :: proc(str: string) -> bool {
	return starts_with(str, "Timestamp")
}
is_first_name_column :: proc(str: string) -> bool {
	return contains(str, "First") && contains(str, "Name")
}
is_last_name_column :: proc(str: string) -> bool {
	return contains(str, "Last") && contains(str, "Name")
}
is_category_column :: proc(str: string) -> bool {
	return contains(str, "Category")
}
is_mens_column :: proc(str: string) -> bool {
	return starts_with(str, "Men")
}
is_womens_column :: proc(str: string) -> bool {
	return starts_with(str, "Women")
}
is_flash_column :: proc(str: string) -> bool {
	return str == "Flash"
}
is_top_column :: proc(str: string) -> bool {
	return str == "Top"
}

competitors_are_maybe_the_same :: proc(a, b: Competitor, tolerance := 3) -> bool {
	if a.category != b.category {return false}

	return(
		dist(a.email, b.email) < tolerance &&
		dist(a.first_name, b.first_name) < tolerance &&
		dist(a.last_name, b.last_name) < tolerance \
	)
}

logfn :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	_: runtime.Logger_Options,
	location := #caller_location,
) {
	if level > .Warning {
		fmt.eprintfln("{} {}: {}", level, location, text)
	} else {
		fmt.eprintfln("{}: {}", level, text)
	}
}

remove_duplicate_competitors :: proc(competitors: ^[dynamic]Competitor) {
	i, j: int
	outer: for i < len(competitors) {
		j = i + 1
		inner: for j < len(competitors) {
			if competitors_are_maybe_the_same(competitors[i], competitors[j]) {

				earlier, later: int
				if competitors[i].submission_time > competitors[j].submission_time {
					earlier = j; later = i
				} else {
					earlier = i; later = j
				}

				log.warnf(
					"Removing earlier submission %#v; later submission %#v will be kept\n",
					competitors[earlier],
					competitors[later],
				)

				unordered_remove(competitors, earlier)
				if earlier == j {continue inner}
				if earlier == i {continue outer}
			}

			j += 1
		}

		i += 1
	}
}
