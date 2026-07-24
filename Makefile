COMMON_FLAGS := -keep-executable -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-using-param -vet-using-stmt -warnings-as-errors
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin-files -no-bounds-check -vet-unused-variables

.PHONY: r rr

r:
	odin run . $(DEBUG_FLAGS) -- --csv "/home/jacob/Downloads/Resistance Qualifiers.csv" --top-n=10 --same-pool
rr:
	odin run . $(RELEASE_FLAGS) -- --csv "/home/jacob/Downloads/Resistance Qualifiers.csv" --top-n=10 --same-pool
	strip score
