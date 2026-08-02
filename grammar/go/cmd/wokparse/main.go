// Command wokparse reads wok v2 source and reports every fault it can
// isolate, so one run yields a whole work list rather than the first mistake.
//
//	wokparse file.wok ...           print the AST as an s-expression
//	wokparse -tokens file.wok ...   print the token stream with positions
//	wokparse -fmt file.wok ...      print the file in canonical form
//	wokparse -check file.wok ...    report files that are NOT in canonical form
//	wokparse -read file.sexp ...    rebuild source from an s-expression dump
//	wokparse -json file.wok ...     print diagnostics as JSON, for tools
//	wokparse -quiet file.wok ...    report faults only
//
// The last three are the two halves of one loop: `-fmt` prints a tree as
// source, `-read` reads a dump back into a tree, so a tool may rewrite the IR
// and get source back. `-check` is the linter -- a file that differs from its
// own formatting is not canonical -- and prints nothing when everything is
// already in shape.
//
// Diagnostics go to stderr as `file:line:col: message`, the form editors and
// CI logs already know how to jump to. Exit status is 1 if any file failed.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	wok "wok/grammar"
)

// mode is what to do with each file. They are mutually exclusive, and
// selecting more than one is a usage error rather than a silent precedence.
type mode struct {
	tokens bool
	format bool
	check  bool
	read   bool
}

func (m mode) count() int {
	n := 0
	for _, on := range []bool{m.tokens, m.format, m.check, m.read} {
		if on {
			n++
		}
	}
	return n
}

func main() {
	var m mode
	flag.BoolVar(&m.tokens, "tokens", false, "print the token stream instead of the AST")
	flag.BoolVar(&m.format, "fmt", false, "print the file in canonical form")
	flag.BoolVar(&m.check, "check", false, "report files that are not in canonical form")
	flag.BoolVar(&m.read, "read", false, "the input is an s-expression dump; print the source it denotes")
	quiet := flag.Bool("quiet", false, "print diagnostics only, not the output")
	asJSON := flag.Bool("json", false, "print diagnostics as JSON on stdout")
	flag.Parse()

	if flag.NArg() == 0 || m.count() > 1 {
		fmt.Fprintln(os.Stderr, "usage: wokparse [-tokens|-fmt|-check|-read] [-json] [-quiet] file ...")
		os.Exit(2)
	}

	var faults []*wok.Error
	failed := false
	for _, path := range flag.Args() {
		errs, err := run(path, m, *quiet || *asJSON)
		switch {
		case err != nil: // could not read the file, or it is not canonical
			fmt.Fprintln(os.Stderr, err)
			failed = true
		case len(errs) > 0:
			faults = append(faults, errs...)
			failed = true
		}
	}

	if *asJSON {
		// One object per fault, in source order: `[]` means a clean parse.
		out := json.NewEncoder(os.Stdout)
		out.SetIndent("", "  ")
		out.SetEscapeHTML(false) // messages quote `<label>`; keep them readable
		if faults == nil {
			faults = []*wok.Error{}
		}
		if err := out.Encode(faults); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	} else {
		for _, f := range faults {
			fmt.Fprintln(os.Stderr, f)
		}
	}

	if failed {
		os.Exit(1)
	}
}

// run processes one file and returns its faults. A non-nil error means the
// file could not be read at all, or -check found it unformatted; parse faults
// come back in the slice, so a batch of them stays one report.
func run(path string, m mode, quiet bool) ([]*wok.Error, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	if m.read {
		file, err := wok.Read(path, string(src))
		if err != nil {
			return asList(err)
		}
		if !quiet {
			fmt.Print(wok.Format(file))
		}
		return nil, nil
	}

	if m.tokens {
		toks, err := wok.Tokenise(path, string(src))
		if !quiet {
			for _, t := range toks {
				fmt.Println(t)
			}
		}
		return asList(err)
	}

	file, parseErr := wok.Parse(path, string(src))
	if parseErr != nil {
		return asList(parseErr)
	}
	switch {
	case m.check:
		if out := wok.Format(file); out != string(src) {
			return nil, fmt.Errorf("%s: not in canonical form (run: wokparse -fmt %s)", path, path)
		}
	case m.format:
		if !quiet {
			fmt.Print(wok.Format(file))
		}
	default:
		if !quiet {
			fmt.Print(wok.Dump(file))
		}
	}
	return nil, nil
}

// asList unwraps the batch a stage reports. Anything that is not an ErrorList
// is a failure of the run itself, not a fault in the file.
func asList(err error) ([]*wok.Error, error) {
	if err == nil {
		return nil, nil
	}
	list, ok := err.(wok.ErrorList)
	if !ok {
		return nil, err
	}
	return list, nil
}
