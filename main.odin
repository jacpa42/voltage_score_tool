package score

import "core:math/bits"
import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:sort"
import "core:strings"

Opts :: struct {
	csv:             ^os.File `args:"pos=0,required,file=r" usage:"Input csv data."`,
	top_n:           int `usage:"Include only top n boulders. Zero means use all boulders."`,
	verbosity:       int `usage:"0: position score name. 1: position score name email. 2: everything"`,
	same_pool:       bool `usage:"Don't separate the men and women when calculating scores."`,
	num_competitors: int `usage:"Print only this many competitors from each category. 0 means print all."`,
}

main :: proc() {
	context.logger.procedure = logfn
	context.logger.lowest_level = .Info

	arena: mem.Arena
	mem.arena_init(&arena, make([]byte, 512 * 1024))
	context.allocator = mem.arena_allocator(&arena)

	// Parse command line options
	opts: Opts
	style: flags.Parsing_Style = .Unix
	flags.parse_or_exit(&opts, os.args, style)

    if opts.num_competitors < 1 { opts.num_competitors = bits.INT_MAX }

    opts.verbosity = clamp(opts.verbosity, 0, 2)
    print_c: #type proc(c: Competitor, pos: int)
    switch opts.verbosity {
    case 0: print_c = verbose0
    case 1: print_c = verbose1
    case 2: print_c = verbose2
    case: unreachable()
    }

	// Load the file data into memory
	csv_data, csv_err := os.read_entire_file(opts.csv, context.allocator)
	assert(csv_err == nil)
	os.close(opts.csv)

	// Parse csv :)
	competitors := make([dynamic]Competitor, 0, 256)
	parse_competitor_csv(&competitors, csv_data)

	// Remove duplicate entries
	remove_duplicate_competitors(&competitors)

	// Calculate the total number of tops and stuff for each boulder
	max_boulder_logged: BoulderTag
	combined: [BoulderTag]Boulder
	stats: [Category][BoulderTag]Boulder
	for c in competitors[:] {
		for b in c.flash {
			stats[c.category][b].flashes += 1
			combined[b].flashes += 1
		}
		for b in c.top {
			stats[c.category][b].tops += 1
			combined[b].tops += 1
		}
		for b in c.zone {
			stats[c.category][b].zones += 1
			combined[b].zones += 1
		}

        max_boulder_logged = max(
            max_boulder_logged,
            max_boulder_in(c.zone),
            max_boulder_in(c.top),
            max_boulder_in(c.flash),
        )
    }

	// Calculate the player scores
	if opts.same_pool {
		for &c in competitors[:] {
			c.score = competitor_score(c, combined, opts.top_n)
		}
	} else {
		for &c in competitors[:] {
			c.score = competitor_score(c, stats[c.category], opts.top_n)
		}
	}

	// Sort by man/women and by score
	sort.quick_sort_proc(competitors[:], proc(lhs, rhs: Competitor) -> int {
		if rhs.category == lhs.category {
            if rhs.score > lhs.score {
                return 1
            } else if rhs.score == lhs.score {
                return 0
            } else {
                return -1
            }
		} else {
			return int(rhs.category) - int(lhs.category)
		}
	})

	// print the boulder scores
	if opts.same_pool {
		for t in BoulderTag.b01..=max_boulder_logged {
			fmt.printfln("{} : {} points", t, top_score(combined[t]))
		}
        fmt.printfln("")
	} else {
		for c in Category {
            for t in BoulderTag.b01..=max_boulder_logged {
				fmt.printfln("{} {} : {} points", c, t, top_score(stats[c][t]))
			}
			fmt.printfln("")
		}
	}

	w, m: int
	for c in competitors[:] {

		i: int
		switch c.category {
		case .mens:
			m += 1
			i = m
		case .womens:
			w += 1
			i = w
		}

        if i == 1 {
			fmt.printfln("")
        }

		if i <= opts.num_competitors {
            print_c(c, i)
		}
	}
}

verbose0 :: proc(c: Competitor, pos: int) {
    fmt.printfln(
        "%3d %5.2f {} {}",
        pos,
        c.score,
        c.first_name,
        c.last_name,
    )
}

verbose1 :: proc(c: Competitor, pos: int) {
    fmt.printfln(
        "%3d {} %5.2f : {} {} | {}",
        pos,
        c.category,
        c.score,
        c.first_name,
        c.last_name,
        c.email,
    )
}


verbose2 :: proc(c: Competitor, pos: int) {
    fmt.printfln("%3d %#v", pos, c)
}

competitors_are_maybe_the_same :: proc(a, b: Competitor, tolerance := 3) -> bool {
	if a.category != b.category {return false}

	// fmt.eprintfln("|{} - {}| = {}", a.first_name, b.first_name, dist(a.first_name, b.first_name))
	// fmt.eprintfln("|{} - {}| = {}", a.email, b.email, dist(a.email, b.email))
	// fmt.eprintfln("|{} - {}| = {}\n", a.last_name, b.last_name, dist(a.last_name, b.last_name))

	return(
		dist(a.first_name, b.first_name) < tolerance &&
		dist(a.email, b.email) < tolerance &&
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

dist :: proc(a, b: string) -> int {
	la, lb: string
	la = strings.to_lower(a)
	lb = strings.to_lower(b)
	return strings.levenshtein_distance(la, lb)
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
