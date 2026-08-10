# Wok programming language

A Miranda-flavored functional language. Two front ends live here: the Haskell
pipeline (`wok`) and the v2 C23 front end (`grammar/c`).

## Prerequisites

- GHC 9.10+, Cabal 3.14+
- A C23 compiler (`cc`); clang for the sanitizer targets

In dev we use clangd for code linter and as language server. But we will test on both
GCC and Clang.

## Build the Haskell pipeline

```bash
cabal install --overwrite-policy=always BNFC alex happy
cabal build
```

## Build the C parser

```bash
cd grammar/c
make            # builds the library plus the wokparse and wokfmt CLIs
```

Other targets in the same directory:

```bash
make test       # every C test binary
make sanitize   # the same, under ASan + UBSan, plus the corpus sweep
make sweep      # the exhaustive layout sweep
make fuzz       # the libFuzzer targets (needs a full LLVM)
make clean
```

## Run all tests

`cabal test` on its own skips the parser-vs-parser differential groups and
reports green without them. To run the whole suite, build the C parser first
and point `WOK_WOKPARSE` at it:

```bash
cd grammar/c && make && cd ../..
WOK_WOKPARSE=$PWD/grammar/c/wokparse cabal test
```

The C-side suite is separate:

```bash
cd grammar/c && make test
```

## Run the CLI

```bash
cabal run wok -- test/examples/01-literals.wok                   # parse + pretty-print
cabal run wok -- test/run-examples/07-effect-ask.wok --run       # evaluate main
cabal run wok -- test/run-examples/07-effect-ask.wok --dump-anf  # dump elaborated ANF

grammar/c/wokparse -check-only FILE.wok    # v2 front end, full check
grammar/c/wokparse -sexp FILE.wok          # s-expression dump
grammar/c/wokfmt FILE.wok                  # format
```

## Regenerate

```bash
# After editing grammar/Wok.cf
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
cabal build

# After adding or changing golden example files
cabal test --test-options=--accept
```

NOTE: Please ignore the src-generated/ when you configured hlint or formatters.
Since it is the output directory of parser generator bnfc and alex.