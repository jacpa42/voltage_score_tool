COMMON_FLAGS := -keep-executable -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-using-param -vet-using-stmt -warnings-as-errors
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin-files -no-bounds-check -vet-unused-variables
FLAGS := --csv "/home/jacob/Downloads/Resistance 2026 Qualifiers.csv" --top-n=10 --num-competitors=6

.PHONY: r rr

r:
	odin build . $(RELEASE_FLAGS) --out=score
	strip score
	./score $(FLAGS)
