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
#
# EVERY generated file lands under $(BUILD). The source directories hold only
# sources, so `ls test/` answers "what is tested" rather than "what was tested
# and then built"; `clean` is one `rm -rf`; and an orphaned object from a
# renamed source cannot survive to be linked, because nothing is ever written
# beside the thing it was built from. The two CLI binaries are the exception:
# test_pipe drives `./wokfmt` through popen, and a tool the tests invoke by
# name belongs where a person would look for it.

CC      ?= cc
BUILD   := build
STD     := -std=c23
WARN    := -Wall -Wextra -Wpedantic -Wconversion -Wstrict-prototypes \
           -Wshadow -Wswitch -Wvla -Werror
OPT     ?= -O2 -g
INCLUDE := -I. -I../../include
# -MMD -MP: the compiler writes each object's HEADER dependencies to a .d file,
# which is included below. Without it, editing wok_ast.h -- the schema every
# other file is derived from -- rebuilds NOTHING, and the tree that comes out
# is half old schema and half new. That is the one edit this package is
# designed to make routine, so it is the one that must not go stale.
CFLAGS  := $(STD) $(WARN) $(OPT) $(INCLUDE) -MMD -MP
SANFLAG := -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all

LIB_SRC := wok_arena.c wok_diag.c wok_token.c wok_layout.c wok_ast.c \
           wok_resolve.c wok_reorder.c \
           wok_parse.c wok_sexpr.c wok_print.c wok_shape.c wok_trivia.c \
           wok_utf8.c \
           wok_write.c
LIB_OBJ := $(LIB_SRC:%.c=$(BUILD)/%.o)

TEST_SRC := $(wildcard test/test_*.c)
TEST_BIN := $(TEST_SRC:%.c=$(BUILD)/%)

DEPS := $(LIB_OBJ:.o=.d) $(BUILD)/cmd/wokparse.d $(BUILD)/cmd/wokfmt.d \
        $(TEST_BIN:=.d)

CORPUS := $(wildcard ../../test/redesign/accept/*.wok) \
          $(wildcard ../../test/redesign/reject/*.wok) \
          $(wildcard testdata/tour/*.wok) \
          $(wildcard testdata/fill/*.wok)

.PHONY: all test sanitize sweep fuzz clean corpus coverage

all: wokparse wokfmt

-include $(DEPS)

# `mkdir -p $(@D)` rather than an order-only prerequisite on the directories:
# a directory's mtime changes whenever anything is written into it, so naming
# one as a prerequisite rebuilds every target that depends on it, every time.
$(BUILD)/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@

wokparse: $(LIB_OBJ) $(BUILD)/cmd/wokparse.o
	$(CC) $(CFLAGS) -o $@ $^

wokfmt: $(LIB_OBJ) $(BUILD)/cmd/wokfmt.o
	$(CC) $(CFLAGS) -o $@ $^

$(BUILD)/test/test_%: test/test_%.c $(LIB_OBJ)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $< $(LIB_OBJ)

test: $(TEST_BIN) wokfmt wokparse
	@fail=0; for t in $(TEST_BIN); do \
	  printf '%-40s ' "$$t"; \
	  if ./$$t > /tmp/wok_test_out 2>&1; then echo ok; \
	  else echo FAIL; cat /tmp/wok_test_out; fail=1; fi; \
	done; exit $$fail
	@# The CLI's mode split is DELIBERATE and pinned here, because no test
	@# binary exercises cmd/wokparse.c: bare mode dumps any parse-clean file
	@# (a stage-4 fault must not cost the reader the tree it is about), while
	@# the check modes gate on stage 4 too. reject/07 is parse-clean with a
	@# resolver fault, so it distinguishes the two.
	@f=../../test/redesign/reject/07-assign-outside.wok; \
	  ./wokparse $$f > /dev/null 2>&1 || \
	    { echo "cli: bare mode must dump a parse-clean file"; exit 1; }; \
	  if ./wokparse -check-only $$f > /dev/null 2>&1; then \
	    echo "cli: -check-only must fault reject/07"; exit 1; fi; \
	  echo "cli: mode split holds"
	@# `-reorder` is a MODIFIER of `-sexp`, not a mode of its own (see
	@# wok_reorder.h / docs/superpowers/specs/2026-08-07-sexp-reorder-pass.md):
	@# naming it without `-sexp` is a usage error, not a silent no-op. On a
	@# fixity-clean file `-sexp -reorder` dumps like any other -sexp run; on a
	@# fixity-faulted file it must dump NOTHING, the same "no partial tree on
	@# a fault" rule the bare/-check-only split above already keeps.
	@g=../../test/sexp-reorder-fixtures/single-op-chain.wok; \
	  b=../../test/sexp-reorder-fixtures/reject-undeclared-operator.wok; \
	  if ./wokparse -reorder $$g > /dev/null 2>&1; then \
	    echo "cli: -reorder without -sexp must be a usage error"; exit 1; fi; \
	  ./wokparse -sexp -reorder $$g > /tmp/wok_reorder_ok 2>/dev/null || \
	    { echo "cli: -sexp -reorder must dump a fixity-clean file"; exit 1; }; \
	  [ -s /tmp/wok_reorder_ok ] || \
	    { echo "cli: -sexp -reorder dumped nothing for a clean file"; exit 1; }; \
	  if ./wokparse -sexp -reorder $$b > /tmp/wok_reorder_bad 2>/dev/null; then \
	    echo "cli: -sexp -reorder must fault a fixity-broken file"; exit 1; fi; \
	  if [ -s /tmp/wok_reorder_bad ]; then \
	    echo "cli: -sexp -reorder must dump nothing on a fault"; exit 1; fi; \
	  rm -f /tmp/wok_reorder_ok /tmp/wok_reorder_bad; \
	  echo "cli: reorder mode split holds"

# Every test, plus the corpus, under ASan + UBSan. Wired beside the existing
# runtime sanitiser script.
sanitize:
	$(MAKE) clean
	$(MAKE) test CFLAGS="$(STD) $(WARN) -O1 -g $(SANFLAG) $(INCLUDE)"
	$(MAKE) wokparse wokfmt CFLAGS="$(STD) $(WARN) -O1 -g $(SANFLAG) $(INCLUDE)"
	@# Two things are checked at once: the SANITISERS stay quiet everywhere
	@# (an abort exits well above 1), and the corpus means what its directory
	@# says. Only reject/ files may exit 1 -- they are rejects, and some carry
	@# a stage-4 fault the tool is supposed to report. accept/, tour/ and
	@# fill/ must exit 0: for fill/ this loop is the ONLY gate that runs the
	@# resolver at all, so tolerating rc 1 here would let a faulting fixture
	@# ship while the real -check-only pipeline rejects it.
	@for f in $(CORPUS); do ./wokparse -check-only $$f > /dev/null 2>&1; \
	  rc=$$?; case $$f in */reject/*) max=1;; *) max=0;; esac; \
	  if [ $$rc -gt $$max ]; then \
	    echo "sanitize: $$f exited $$rc"; exit 1; fi; done
	@echo "sanitize: clean over $(words $(CORPUS)) corpus files"
	@# The same corpus again, under `-sexp -reorder`: still only a sanitiser
	@# report or an out-of-range exit code is a failure. Unlike -check-only,
	@# reject/ is not the only directory allowed to fault here -- most of the
	@# corpus declares no in-file `fixity` at all, and reorder mode has no
	@# grace for an operator with no table entry (spec: "check mode would
	@# have skipped it silently; reorder mode is strict"), so accept/, tour/
	@# and fill/ files legitimately exit 1 too. What this sweep is actually
	@# checking is ASan/UBSan silence and "nothing worse than a diagnosed
	@# fault" over every corpus file's reorder path, not a directory-keyed
	@# verdict the way -check-only's sweep above is.
	@for f in $(CORPUS); do ./wokparse -sexp -reorder $$f > /dev/null 2>&1; \
	  rc=$$?; \
	  if [ $$rc -gt 1 ]; then \
	    echo "sanitize: $$f -sexp -reorder exited $$rc"; exit 1; fi; done
	@echo "sanitize: clean over $(words $(CORPUS)) corpus files under -reorder"
	@# Instrumented objects must not be left where an ordinary `make` would
	@# reuse them: they carry __asan/__ubsan references the normal link lacks.
	@$(MAKE) clean > /dev/null

# Line coverage, GCC ONLY. gcov's data format is tied to the compiler that
# produced it, so this must run in the gcc devshell -- `gcov` there is that
# gcc's gcov, which is the whole reason the shells are separate.
#
# -O1, not -O0: nixpkgs' gcc injects -D_FORTIFY_SOURCE, and glibc #warns that
# fortification needs optimization, which -Werror turns into a build failure.
# -O1 satisfies it while still keeping line attribution close enough to the
# source to read; -O2 is where the optimiser merges lines until the report
# describes the object instead.
COVDIR := coverage
GCOV   ?= gcov

# PROVENANCE. A coverage report with no commit on it is unreadable a week
# later: you cannot tell what it measured, and two reports cannot be compared.
# So the commit, its date, and the CI run are stamped into both outputs.
#
# SOURCE_DATE_EPOCH is the reason the first published report read
# "Test Date: 1980-01-01". Nix exports it as 315532800 so builds are
# reproducible, and lcov honours it. Unsetting it would restore wall-clock and
# lose reproducibility; setting it to the COMMIT's own date keeps the report
# reproducible AND makes the date mean something -- rebuild this commit
# tomorrow and you get the same page, dated when the code was written.
COV_SHA   := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
COV_EPOCH := $(shell git log -1 --format=%ct 2>/dev/null || date +%s)
COV_DATE  := $(shell date -u -r $(COV_EPOCH) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -d @$(COV_EPOCH) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
# Set by CI; empty locally, which is itself information.
COV_RUN   ?= $(if $(GITHUB_RUN_ID),https://github.com/$(GITHUB_REPOSITORY)/actions/runs/$(GITHUB_RUN_ID),)
# --ignore-errors unused: the exclude list below is a SUPERSET covering every
# platform this can run on, so some pattern always matches nothing -- vendor/
# is under runtime/ and never compiled here, /nix/store only exists in CI,
# /usr only outside it. lcov 2.x treats an unused pattern as a hard error
# (exit 25), which would make the report platform-specific for no gain.
LCOV   ?= lcov --gcov-tool $(GCOV) --rc branch_coverage=0 --ignore-errors unused
coverage:
	$(MAKE) clean
	$(MAKE) test CC=$(CC) CFLAGS="$(STD) $(WARN) -O1 -g --coverage $(INCLUDE)"
	@mkdir -p $(COVDIR)
	@# The BASELINE is not optional. A file no test ever enters emits no .gcda
	@# and would be missing from the report entirely -- so it would not lower
	@# the percentage, and the untested file becomes invisible. That is the one
	@# thing this report exists to show, so capture zero counts for everything
	@# compiled and merge them under the measured run.
	$(LCOV) --capture --initial --directory $(BUILD) --base-directory . \
	  --output-file $(COVDIR)/base.info
	$(LCOV) --capture --directory $(BUILD) --base-directory . \
	  --output-file $(COVDIR)/run.info
	$(LCOV) --add-tracefile $(COVDIR)/base.info \
	  --add-tracefile $(COVDIR)/run.info --output-file $(COVDIR)/all.info
	@# Vendored code and the suites themselves are not the subject. Left in,
	@# they dominate the denominator and the number stops meaning anything.
	$(LCOV) --remove $(COVDIR)/all.info \
	  '*/test/*' '*/vendor/*' '/nix/store/*' '/usr/*' \
	  --output-file $(COVDIR)/wok.info
	SOURCE_DATE_EPOCH=$(COV_EPOCH) genhtml $(COVDIR)/wok.info \
	  --output-directory $(COVDIR)/html \
	  --title "$(COV_SHA)" --legend --show-details
	@# The same measurement for readers that are not browsers. Served next to
	@# the HTML, so a tool asks for one URL instead of scraping 86 files of
	@# markup. uncovered_lines is the part worth having: a percentage says how
	@# much is missed, the line numbers say what.
	python3 ../../scripts/lcov-to-json.py $(COVDIR)/wok.info \
	  --root ../.. --commit $(COV_SHA) --generated-at "$(COV_DATE)" \
	  > $(COVDIR)/html/coverage.json
	@# EXACTNESS GATE. The JSON is consumed by tools that cannot notice a
	@# wrong number, so it is checked against lcov's own summary of the same
	@# tracefile and the build stops on any disagreement. This is not
	@# hypothetical: the two silently differed once (365 functions vs 686),
	@# because the parser knew only the classic FN:/FNDA: spelling.
	$(LCOV) --summary $(COVDIR)/wok.info 2>&1 \
	  | python3 ../../scripts/coverage-verify.py $(COVDIR)/html/coverage.json
	@printf '{"commit":"%s","date":"%s","run":"%s"}\n' \
	  '$(COV_SHA)' '$(COV_DATE)' '$(COV_RUN)' > $(COVDIR)/html/build.json
	@# The raw tracefile too: it is what both of the above were derived from,
	@# and a tool that wants to recompute rather than trust us needs it.
	@cp $(COVDIR)/wok.info $(COVDIR)/html/coverage.info
	python3 ../../scripts/coverage-postprocess.py $(COVDIR)/html \
	  --commit $(COV_SHA) --date "$(COV_DATE)" --run "$(COV_RUN)"
	@echo "coverage: $(COVDIR)/html/index.html  (+ coverage.json, build.json, coverage.info)"
	@echo "stamped:  commit $(COV_SHA), dated $(COV_DATE)"

sweep: $(BUILD)/test/test_layout_sweep
	./$(BUILD)/test/test_layout_sweep

fuzz: $(BUILD)/test/fuzz_layout $(BUILD)/test/fuzz_parse

$(BUILD)/test/fuzz_%: test/fuzz_%.c $(LIB_SRC)
	@mkdir -p $(@D)
	$(CC) $(STD) $(WARN) -O1 -g $(INCLUDE) -fsanitize=fuzzer,address,undefined \
	  -o $@ $< $(LIB_SRC)

corpus:
	@echo $(CORPUS) | tr ' ' '\n'

clean:
	@# One directory holds every generated file, so this is the whole of it --
	@# no list to keep in step with LIB_SRC, and no orphan from a renamed
	@# source left behind to be linked by a later build.
	rm -rf $(BUILD)
	@# The two exceptions, and the .dSYM bundles a debug build leaves beside
	@# them: a `clean` that leaves 10 MB behind is not clean.
	rm -f wokparse wokfmt
	rm -rf wokparse.dSYM wokfmt.dSYM
	@# TRANSITIONAL. Objects used to be written beside their sources, so a
	@# checkout from before that moved carries a set this build never touches
	@# again. Every pattern here is ANCHORED TO AN EXTENSION no source has --
	@# a bare `test/test_*` would match test_batch.c, which is a `clean` that
	@# deletes the suite. Delete these lines once nobody has such a tree; the
	@# stale BINARIES are left alone and merely gitignored, because no glob
	@# tells `test/test_batch` from `test/test_batch.c` safely.
	rm -f *.o *.o.tmp *.d cmd/*.o cmd/*.d test/*.d
	rm -rf cmd/*.dSYM test/*.dSYM
