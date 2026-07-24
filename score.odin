package score

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"

dist :: strings.levenshtein_distance

main :: proc() {
	context.logger.procedure = logfn
	context.logger.lowest_level = .Info

	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 512 * 1024))
	context.allocator = mem.arena_allocator(&arena)

	csv_data, csv_err := os.read_entire_file(os.stdin, context.allocator)
	assert(csv_err == nil)

	// Parse csv :)
	competitors := make([dynamic]Competitor, 0, 256)
	parse_competitor_csv(&competitors, csv_data)

	// Remove duplicate entries
	remove_duplicate_competitors(&competitors)

	// Calculate the total number of tops and stuff for each boulder
    stats: [BoulderTag]Boulder
    for c in competitors[:] {
		for b in c.flash { stats[b].flashes += 1 }
		for b in c.top   { stats[b].tops += 1    }
		for b in c.zone  { stats[b].zones += 1   }
	}

	// Calculate the player scores
	for &c in competitors[:] {
        c.score = competitor_score(c, stats)
    }

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
}

competitors_are_maybe_the_same :: proc(a, b: Competitor, tolerance := 3) -> bool {
	if a.category != b.category {return false}

	return(
		dist(a.email, b.email) < tolerance &&
		dist(a.first_name, b.first_name) < tolerance &&
		dist(a.last_name, b.last_name) < tolerance \
	)
}

remove_duplicate_competitors :: proc(competitors: ^[dynamic]Competitor) {
	i, j: int
	i_loop: for i < len(competitors) {
		j = i + 1
		j_loop: for j < len(competitors) {
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
				if earlier == j {continue j_loop}
				if earlier == i {continue i_loop}
			}

			j += 1
		}

		i += 1
	}
}

logfn :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	_: runtime.Logger_Options,
	loc := #caller_location,
) {
	if level > .Warning {
		fmt.eprintfln("{} {}: {}", level, loc, text)
	} else {
		fmt.eprintfln("{}: {}", level, text)
	}
}
