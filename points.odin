package score

import "core:math"
import "core:sort"

FLASH_SCORE :: 110
TOP_SCORE :: 100
ZONE_SCORE :: 50

Boulder :: struct {
	tops:    u32,
	flashes: u32,
	zones:   u32,
}

BoulderTag :: enum {
	b00, b01, b02, b03, b04, b05, b06, b07, b08, b09, b10, b11, b12, b13, b14, b15,
	b16, b17, b18, b19, b20, b21, b22, b23, b24, b25, b26, b27, b28, b29, b30, b31,
	b32, b33, b34, b35, b36, b37, b38, b39, b40, b41, b42, b43, b44, b45, b46, b47,
	b48, b49, b50, b51, b52, b53, b54, b55, b56, b57, b58, b59, b60, b61, b62, b63,
}

decay :: proc "contextless" (b: Boulder, k: f32 = 0.01) -> f32 {
    return math.exp(-k * f32(b.tops + b.flashes))
}

flash_score :: proc "contextless" (b: Boulder) -> f32 { return FLASH_SCORE * decay(b) }
top_score :: proc "contextless" (b: Boulder) -> f32 { return TOP_SCORE * decay(b) }
zone_score :: proc "contextless" (b: Boulder) -> f32 { return ZONE_SCORE * decay(b) }

competitor_score :: proc(c: Competitor, stats: [BoulderTag]Boulder, topn: int) -> f32 {
	scores: [len([BoulderTag]byte)]f32

	for b, tag in stats {
		if tag in c.flash     { scores[tag] = flash_score(b) }
        else if tag in c.top  { scores[tag] = top_score(b)   }
        else if tag in c.zone { scores[tag] = zone_score(b)  }
        else                  { scores[tag] = 0 }
	}

    sort.quick_sort(scores[:])

    if topn == 0 {
        return math.sum(scores[:])
    } else {
        start := len(scores) - min(len(scores), topn)
        return math.sum(scores[start:])
    }
}
