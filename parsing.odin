package score

import "core:encoding/csv"
import "core:math/bits"
import "core:strconv"
import "core:strings"

BOULDERS_START_AT_NUMBER :: 1

contains :: strings.contains
starts_with :: strings.starts_with

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
	category:        Category,

	flash:           bit_set[BoulderTag],
	top:             bit_set[BoulderTag],
	zone:            bit_set[BoulderTag],

    // Calculated after parsing
	score:           f32,
}

// parses a string into a competitor array
parse_competitor_csv :: proc(competitors: ^[dynamic]Competitor, data: []byte) {
	// Initialize the csv reader
	r: csv.Reader
	r.trim_leading_space = true
	r.reuse_record = true
	r.reuse_record_buffer = false

    is_mens_column ::   proc(str: string) -> bool { return starts_with(str, "Men") }
    is_womens_column :: proc(str: string) -> bool { return starts_with(str, "Women") }

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
		if is_mens_column(entry[category])        { ctgy = .mens }
        else if is_womens_column(entry[category]) { ctgy = .womens }
        else { unreachable() }

        flash, top, zone: bit_set[BoulderTag]
        for column, tag in boulder_csv_column {
            switch entry[column] {
            case "Flash": flash |= {tag}
            case "Top": top |= {tag}
            case "Zone": zone |= {tag}
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
				zone = zone,
				score = 0, // set later
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

    is_boulder_column ::         proc(str: string) -> bool { return contains(str, "Boulder") }
    is_email_column ::           proc(str: string) -> bool { return starts_with(str, "Username") || starts_with(str, "Email") }
    is_submission_time_column :: proc(str: string) -> bool { return starts_with(str, "Timestamp") }
    is_first_name_column ::      proc(str: string) -> bool { return contains(str, "First") && contains(str, "Name") }
    is_last_name_column ::       proc(str: string) -> bool { return contains(str, "Last") && contains(str, "Name") }
    is_category_column ::        proc(str: string) -> bool { return contains(str, "Category") }

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
