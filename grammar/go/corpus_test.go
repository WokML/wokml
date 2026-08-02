package wok

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the golden dumps in testdata/golden")

// corpus is the v2 conformance suite (spec section 7) plus the surface tour.
// The reject/ files are SYNTACTICALLY valid -- they fail semantic checks the
// parser does not perform -- so every file here must parse.
func corpus(t testing.TB) map[string]string {
	t.Helper()
	files := map[string]string{}
	for _, dir := range []string{
		"../../docs/redesign/examples/accept",
		"../../docs/redesign/examples/reject",
		"testdata",
	} {
		matches, err := filepath.Glob(filepath.Join(dir, "*.wok"))
		if err != nil {
			t.Fatal(err)
		}
		for _, path := range matches {
			name := strings.TrimSuffix(filepath.Base(path), ".wok")
			if base := filepath.Base(dir); base != "testdata" {
				name = base + "-" + name
			}
			files[name] = path
		}
	}
	if len(files) < 21 {
		t.Fatalf("found only %d corpus files; expected the 20 conformance examples plus the tour", len(files))
	}
	return files
}

func TestCorpusParses(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := Parse(path, string(src)); err != nil {
				t.Fatalf("%v", err)
			}
		})
	}
}

// TestGolden pins the AST of every corpus file. The dumps are the by-eye
// artifact: read them beside docs/redesign/surface.md. Refresh with
//
//	go test -run Golden -update
func TestGolden(t *testing.T) {
	for name, path := range corpus(t) {
		t.Run(name, func(t *testing.T) {
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			f, err := Parse(path, string(src))
			if err != nil {
				t.Fatalf("%v", err)
			}
			got := Dump(f)

			gold := filepath.Join("testdata", "golden", name+".sexp")
			if *update {
				if err := os.MkdirAll(filepath.Dir(gold), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(gold, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(gold)
			if err != nil {
				t.Fatalf("%v (run: go test -run Golden -update)", err)
			}
			if got != string(want) {
				t.Errorf("dump changed.\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
		})
	}
}

// TestParseIsDeterministic guards the dump against map iteration or other
// accidental nondeterminism, since the goldens are diffed by hand.
func TestParseIsDeterministic(t *testing.T) {
	src, err := os.ReadFile("../../docs/redesign/examples/accept/03-ambient-mtl.wok")
	if err != nil {
		t.Fatal(err)
	}
	first := ""
	for i := range 5 {
		f, err := Parse("x.wok", string(src))
		if err != nil {
			t.Fatal(err)
		}
		got := Dump(f)
		if i == 0 {
			first = got
		} else if got != first {
			t.Fatal("dump is not deterministic")
		}
	}
}
