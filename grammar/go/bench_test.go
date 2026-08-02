package wok

import (
	"os"
	"testing"
)

// The corpus, one source per file: enough real wok for the numbers to mean
// something, and the same input for both stages. The files are kept apart
// because each is a MODULE -- concatenating them would not parse.
func benchSources(b *testing.B) []string {
	b.Helper()
	var srcs []string
	var bytes int
	for _, path := range corpus(b) {
		text, err := os.ReadFile(path)
		if err != nil {
			b.Fatal(err)
		}
		srcs = append(srcs, string(text))
		bytes += len(text)
	}
	b.SetBytes(int64(bytes))
	return srcs
}

// BenchmarkTokenise measures the scanner alone. Runs are measured in bytes
// rather than decoded rune by rune (see takeWhile) and the token slice is
// sized from the source length, so a regression in either shows up here.
func BenchmarkTokenise(b *testing.B) {
	srcs := benchSources(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, src := range srcs {
			if _, err := Tokenise("bench.wok", src); err != nil {
				b.Fatal(err)
			}
		}
	}
}

// BenchmarkParse measures the whole front end. The parser compares kinds and
// interned words only, so this figure moves with the grammar, never with the
// length of a keyword.
func BenchmarkParse(b *testing.B) {
	srcs := benchSources(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, src := range srcs {
			if _, err := Parse("bench.wok", src); err != nil {
				b.Fatal(err)
			}
		}
	}
}
