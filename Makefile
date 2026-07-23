COMMON_FLAGS := -keep-executable -file -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-using-param -vet-using-stmt -warnings-as-errors
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin -no-bounds-check -vet-unused-variables

.PHONY: r rr

r:
	odin run score.odin $(DEBUG_FLAGS) < "/home/jacob/Downloads/Resistance 2026 Qualifiers.csv"
rr:
	odin run score.odin $(RELEASE_FLAGS) < "/home/jacob/Downloads/Resistance Qualifiers.csv"
