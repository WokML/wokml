# wok v2 front end in C23.
#
#   make            build the library and the CLI
#   make test       build and run every test binary
#   make sanitize   the same, under ASan + UBSan
#   make sweep      the exhaustive layout sweep (78,125 column sequences)
#   make fuzz       build the libFuzzer targets
#
# No GNU extensions, no VLAs, no implementation-defined layout assumptions.
# -Wswitch is load-bearing: no traversal may carry a `default:` label, because
# a default silences the missing-enumerator error that replaces roster tests.

CC      ?= cc
STD     := -std=c23
WARN    := -Wall -Wextra -Wpedantic -Wconversion -Wstrict-prototypes \
           -Wshadow -Wswitch -Wvla -Werror
OPT     ?= -O2 -g
INCLUDE := -I. -I../../include
CFLAGS  := $(STD) $(WARN) $(OPT) $(INCLUDE)
SANFLAG := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

LIB_SRC := wok_arena.c wok_diag.c wok_token.c wok_layout.c wok_ast.c \
           wok_parse.c wok_sexpr.c wok_print.c wok_shape.c wok_trivia.c \
           wok_utf8.c \
           wok_write.c
LIB_OBJ := $(LIB_SRC:.c=.o)

TEST_SRC := $(wildcard test/test_*.c)
TEST_BIN := $(TEST_SRC:.c=)

CORPUS := $(wildcard ../../docs/redesign/examples/accept/*.wok) \
          $(wildcard ../../docs/redesign/examples/reject/*.wok) \
          $(wildcard testdata/tour/*.wok) \
          $(wildcard testdata/fill/*.wok)

.PHONY: all test sanitize sweep fuzz clean corpus

all: wokparse wokfmt

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

wokparse: $(LIB_OBJ) cmd/wokparse.o
	$(CC) $(CFLAGS) -o $@ $^

wokfmt: $(LIB_OBJ) cmd/wokfmt.o
	$(CC) $(CFLAGS) -o $@ $^

test/test_%: test/test_%.c $(LIB_OBJ)
	$(CC) $(CFLAGS) -o $@ $< $(LIB_OBJ)

test: $(TEST_BIN) wokfmt
	@fail=0; for t in $(TEST_BIN); do \
	  printf '%-34s ' "$$t"; \
	  if ./$$t > /tmp/wok_test_out 2>&1; then echo ok; \
	  else echo FAIL; cat /tmp/wok_test_out; fail=1; fi; \
	done; exit $$fail

# Every test, plus the corpus, under ASan + UBSan. Wired beside the existing
# runtime sanitiser script.
sanitize:
	$(MAKE) clean
	$(MAKE) test CFLAGS="$(STD) $(WARN) -O1 -g $(SANFLAG) $(INCLUDE)"
	$(MAKE) wokparse wokfmt CFLAGS="$(STD) $(WARN) -O1 -g $(SANFLAG) $(INCLUDE)"
	@for f in $(CORPUS); do ./wokparse -check-only $$f > /dev/null || exit 1; done
	@echo "sanitize: clean over $(words $(CORPUS)) corpus files"
	@# Instrumented objects must not be left where an ordinary `make` would
	@# reuse them: they carry __asan/__ubsan references the normal link lacks.
	@$(MAKE) clean > /dev/null

sweep: test/test_layout_sweep
	./test/test_layout_sweep

fuzz: test/fuzz_layout test/fuzz_parse

test/fuzz_%: test/fuzz_%.c $(LIB_SRC)
	$(CC) $(STD) $(WARN) -O1 -g $(INCLUDE) -fsanitize=fuzzer,address,undefined \
	  -o $@ $< $(LIB_SRC)

corpus:
	@echo $(CORPUS) | tr ' ' '\n'

clean:
	rm -f $(LIB_OBJ) cmd/wokparse.o cmd/wokfmt.o wokparse wokfmt $(TEST_BIN) \
	      test/fuzz_layout test/fuzz_parse
	@# a debug build leaves a .dSYM bundle beside every binary; `clean` that
	@# leaves 10 MB behind is not clean
	rm -rf *.dSYM cmd/*.dSYM test/*.dSYM
