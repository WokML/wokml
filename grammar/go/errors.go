package wok

import (
	"fmt"
	"sort"
	"strings"
)

// Error is one positioned fault, in the `file:line:col: message` form every
// editor and CI log already knows how to jump to. The fields are exported and
// JSON-tagged so a tool can consume them without parsing the text.
type Error struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Col  int    `json:"col"`
	Msg  string `json:"message"`
}

func (e *Error) Error() string {
	return fmt.Sprintf("%s:%d:%d: %s", e.File, e.Line, e.Col, e.Msg)
}

// ErrorList is a batch of faults from one run, in source order. Reporting a
// batch is what makes the report-fix-test loop one round instead of N: fix
// everything named, run once more.
//
// The shape follows go/scanner.ErrorList: it IS an error, and its message is
// the first fault plus a count, so a caller that only prints `err` still gets
// the most important line first.
type ErrorList []*Error

func (list ErrorList) Error() string {
	switch len(list) {
	case 0:
		return "no errors"
	case 1:
		return list[0].Error()
	default:
		return fmt.Sprintf("%s (and %d more errors)", list[0], len(list)-1)
	}
}

// All renders every fault, one per line -- the human form.
func (list ErrorList) All() string {
	var b strings.Builder
	for _, e := range list {
		b.WriteString(e.Error())
		b.WriteString("\n")
	}
	return b.String()
}

// err returns the list as an error, or nil when it is empty. A typed nil
// ErrorList would be a non-nil error interface, which is the classic Go trap.
func (list ErrorList) err() error {
	if len(list) == 0 {
		return nil
	}
	return list
}

func (list ErrorList) sort() {
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].Line != list[j].Line {
			return list[i].Line < list[j].Line
		}
		return list[i].Col < list[j].Col
	})
}

// maxErrors caps a batch. Past this point a report stops being a work list
// and starts being noise -- the file is truncated or damaged beyond what
// resynchronisation can isolate, and only the first faults are trustworthy.
//
// The cap fires far less often than it used to: skipping now resynchronises
// on a DECLARATION ANCHOR rather than a bare column (see skipPastItem), so a
// misindented region costs one fault rather than one per line. What remains
// is a genuine backstop, not the routine outcome of a mangled file.
const maxErrors = 20

// collector accumulates faults with cascade suppression, and is embedded by
// both the scanner and the parser so they report identically.
type collector struct {
	file string
	errs ErrorList
	full bool // the cap was reached; stop parsing
}

// record adds a fault unless it repeats a position already reported. One
// mistake must produce one error: a second complaint about the same spot is
// always a cascade, never new information.
func (c *collector) record(err *Error) {
	if n := len(c.errs); n > 0 {
		last := c.errs[n-1]
		if err.Line == last.Line && err.Col <= last.Col {
			return
		}
	}
	c.errs = append(c.errs, err)
	c.full = len(c.errs) >= maxErrors
}

func (c *collector) errorf(line, col int, format string, args ...any) *Error {
	return &Error{File: c.file, Line: line, Col: col, Msg: fmt.Sprintf(format, args...)}
}
