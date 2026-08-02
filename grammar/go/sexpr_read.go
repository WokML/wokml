package wok

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// Read is the inverse of Dump: it turns an s-expression back into the tree it
// came from. With Format on the other side, the dump becomes an INTERCHANGE
// form rather than a debug print -- a tool may rewrite the IR and get source
// back, and `Dump(Read(Dump(t))) == Dump(t)` is a test rather than a hope.
//
// It is deliberately strict. Every head it does not know, and every arity it
// does not expect, is an error naming the position in the dump: a reader that
// guesses would turn a typo in the IR into a different program, silently.
//
// Positions come from the DUMP, not from the source the dump was made of --
// the tree records no source positions (Dump omits them, since two files that
// differ only in layout are the same program). They are what a fault in the
// s-expression is blamed on.
func Read(name, text string) (_ *File, err error) {
	r := &reader{collector: collector{file: name}}
	defer func() {
		if p := recover(); p != nil {
			b, ok := p.(bail)
			if !ok {
				panic(p)
			}
			err = ErrorList{b.err}
		}
	}()
	data := r.scanAll(text)
	f := &File{Name: name, Decls: make([]Decl, 0, len(data))}
	for _, d := range data {
		f.Decls = append(f.Decls, r.decl(d))
	}
	return f, nil
}

type reader struct {
	collector
	src string
	off int

	line, col int
}

// datum is one s-expression: an atom, or a list whose head is its first atom.
// quote records how an atom was WRITTEN, which is the only way to tell the
// literal `"1"` from the name `1` -- and the reason the dump quotes at all.
type datum struct {
	text  string
	quote byte // 0 bare, '"' a string literal, '\'' a character literal
	head  string
	kids  []datum
	list  bool
	pos   Pos
}

func (r *reader) failAt(pos Pos, format string, args ...any) {
	panic(bail{r.errorf(pos.Line, pos.Col, format, args...)})
}

// ---------------------------------------------------------------- scanning

func (r *reader) scanAll(text string) []datum {
	r.src, r.off, r.line, r.col = text, 0, 1, 1
	var out []datum
	for {
		r.space()
		if r.off >= len(r.src) {
			return out
		}
		out = append(out, r.datum())
	}
}

func (r *reader) space() {
	for r.off < len(r.src) {
		switch r.src[r.off] {
		case '\n':
			r.off, r.line, r.col = r.off+1, r.line+1, 1
		case ' ', '\t', '\r':
			r.off, r.col = r.off+1, r.col+1
		default:
			return
		}
	}
}

func (r *reader) here() Pos { return Pos{Line: r.line, Col: r.col} }

func (r *reader) datum() datum {
	pos := r.here()
	if r.src[r.off] == '(' {
		r.off, r.col = r.off+1, r.col+1
		d := datum{list: true, pos: pos}
		r.space()
		if r.off < len(r.src) && r.src[r.off] != ')' {
			h := r.atom()
			if h.list || h.quote != 0 {
				r.failAt(h.pos, "a list must begin with a bare head atom")
			}
			d.head = h.text
		}
		for {
			r.space()
			if r.off >= len(r.src) {
				r.failAt(pos, "unterminated list")
			}
			if r.src[r.off] == ')' {
				r.off, r.col = r.off+1, r.col+1
				return d
			}
			d.kids = append(d.kids, r.datum())
		}
	}
	if r.src[r.off] == ')' {
		r.failAt(pos, "unexpected `)`")
	}
	return r.atom()
}

// atom reads one atom. A quote is an OPENER only in first position, so `x'`
// stays the single name it is -- `'` is an identifier character in wok
// (token.go, identRune), and treating it as a delimiter anywhere would split
// every primed name in two.
func (r *reader) atom() datum {
	pos := r.here()
	if q := r.src[r.off]; q == '"' || q == '\'' {
		start := r.off
		r.off, r.col = r.off+1, r.col+1
		for r.off < len(r.src) && r.src[r.off] != q {
			if r.src[r.off] == '\\' {
				r.off, r.col = r.off+1, r.col+1
			}
			if r.off >= len(r.src) || r.src[r.off] == '\n' {
				break
			}
			r.off, r.col = r.off+1, r.col+1
		}
		if r.off >= len(r.src) || r.src[r.off] != q {
			r.failAt(pos, "unterminated %c-quoted atom", q)
		}
		r.off, r.col = r.off+1, r.col+1
		text, err := strconv.Unquote(r.src[start:r.off])
		if err != nil {
			r.failAt(pos, "malformed literal %s: %v", r.src[start:r.off], err)
		}
		return datum{text: text, quote: q, pos: pos}
	}
	start := r.off
	for r.off < len(r.src) && !isAtomEnd(r.src[r.off]) {
		r.off, r.col = r.off+1, r.col+1
	}
	if r.off == start {
		r.failAt(pos, "unexpected character %q", string(r.src[r.off]))
	}
	return datum{text: r.src[start:r.off], pos: pos}
}

func isAtomEnd(b byte) bool {
	switch b {
	case ' ', '\t', '\r', '\n', '(', ')':
		return true
	}
	return false
}

// ----------------------------------------------------------------- shapes
//
// Every accessor below blames a position, so a malformed dump names the list
// that is wrong rather than failing somewhere downstream with a nil.

func (r *reader) want(d datum, head string, min int) datum {
	if !d.list || d.head != head {
		r.failAt(d.pos, "expected a `(%s ...)` list, found %s", head, d.describe())
	}
	if len(d.kids) < min {
		r.failAt(d.pos, "`(%s ...)` needs at least %d element(s), found %d", head, min, len(d.kids))
	}
	return d
}

// name reads a bare atom used as an identifier.
func (r *reader) name(d datum) string {
	if d.list || d.quote != 0 {
		r.failAt(d.pos, "expected a name, found %s", d.describe())
	}
	return d.text
}

func (r *reader) text(d datum) string {
	if d.quote != '"' {
		r.failAt(d.pos, "expected a quoted string, found %s", d.describe())
	}
	return d.text
}

func (d datum) describe() string {
	if d.list {
		return "`(" + d.head + " ...)`"
	}
	if d.quote != 0 {
		return "a " + map[byte]string{'"': "string", '\'': "character"}[d.quote] + " literal"
	}
	return "`" + d.text + "`"
}

// isCon reports whether a bare atom names a constructor or a module: the tree
// does not record the distinction between `Foo` and `foo` anywhere, because
// the tokeniser decided it from the first character and nothing can undo that.
func isCon(name string) bool {
	r, _ := utf8.DecodeRuneInString(name)
	return isUpper(r) // identifiers are ASCII here; see the README's deviation 2
}

func readSeq[T any](ds []datum, f func(datum) T) []T {
	out := make([]T, 0, len(ds))
	for _, d := range ds {
		out = append(out, f(d))
	}
	return out
}

// ------------------------------------------------------------ declarations

func (r *reader) decl(d datum) Decl {
	if !d.list {
		r.failAt(d.pos, "expected a declaration, found %s", d.describe())
	}
	pos := d.pos
	switch d.head {
	case "module":
		r.want(d, "module", 1)
		return &ModuleDecl{Pos: pos, Path: strings.Split(r.name(d.kids[0]), ".")}

	case "import":
		r.want(d, "import", 1)
		x := &ImportDecl{Pos: pos, Path: strings.Split(r.name(d.kids[0]), ".")}
		for _, k := range d.kids[1:] {
			switch k.head {
			case "names":
				x.Names = []string{}
				for _, n := range k.kids {
					x.Names = append(x.Names, r.name(n))
				}
			case "as":
				x.Alias = r.name(r.want(k, "as", 1).kids[0])
			default:
				r.failAt(k.pos, "an import takes `(names ...)` and `(as A)`, found %s", k.describe())
			}
		}
		return x

	case "type":
		r.want(d, "type", 2)
		return &TypeDecl{
			Pos:    pos,
			Name:   r.name(d.kids[0]),
			Params: r.tyParams(d.kids[1]),
			Cons:   readSeq(d.kids[2:], r.conDef),
		}

	case "alias":
		r.want(d, "alias", 3)
		return &AliasDecl{
			Pos:    pos,
			Name:   r.name(d.kids[0]),
			Params: r.tyParams(d.kids[1]),
			Type:   r.typ(d.kids[2]),
		}

	case "effect":
		r.want(d, "effect", 2)
		x := &EffectDecl{Pos: pos, Name: r.name(d.kids[0]), Params: r.tyParams(d.kids[1])}
		for _, k := range d.kids[2:] {
			r.want(k, "op", 2)
			x.Ops = append(x.Ops, OpSig{Pos: k.pos, Name: r.name(k.kids[0]), Type: r.typ(k.kids[1])})
		}
		return x

	case "class":
		r.want(d, "class", 2)
		return &ClassDecl{
			Pos:     pos,
			Name:    r.name(d.kids[0]),
			Params:  r.tyParams(d.kids[1]),
			Entries: readSeq(d.kids[2:], r.decl),
		}

	case "instance":
		r.want(d, "instance", 2)
		x := &InstanceDecl{Pos: pos}
		rest := d.kids
		if rest[0].list && rest[0].head == "ctx" {
			x.Ctx = readSeq(rest[0].kids, r.typ)
			rest = rest[1:]
		}
		if len(rest) < 2 {
			r.failAt(pos, "an instance needs a class name and `(args ...)`")
		}
		x.Name = r.name(rest[0])
		x.Args = readSeq(r.want(rest[1], "args", 0).kids, r.typ)
		x.Body = readSeq(rest[2:], r.decl)
		return x

	case "foreign":
		r.want(d, "foreign", 2)
		x := &ForeignDecl{Pos: pos, Name: r.name(d.kids[0]), Lib: r.text(d.kids[1])}
		for _, k := range d.kids[2:] {
			r.want(k, "member", 2)
			m := ForeignMember{Pos: k.pos, Name: r.name(k.kids[0])}
			rest := k.kids[1:]
			if rest[0].quote == '"' {
				m.Symbol = r.text(rest[0])
				rest = rest[1:]
			}
			if len(rest) != 1 {
				r.failAt(k.pos, "a foreign member is `(member name [\"symbol\"] type)`")
			}
			m.Type = r.typ(rest[0])
			x.Members = append(x.Members, m)
		}
		return x

	case "sig", "extern-sig":
		r.want(d, d.head, 2)
		names := r.want(d.kids[0], "names", 1)
		return &SigDecl{
			Pos:    pos,
			Names:  readSeq(names.kids, r.name),
			Type:   r.typ(d.kids[1]),
			Extern: d.head == "extern-sig",
		}

	case "extern-type":
		r.want(d, "extern-type", 2)
		return &ExternTypeDecl{Pos: pos, Name: r.name(d.kids[0]), Params: r.tyParams(d.kids[1])}

	case "def", "def-infix":
		r.want(d, d.head, 3)
		x := &FunDecl{
			Pos:    pos,
			Name:   r.name(d.kids[0]),
			Params: readSeq(r.want(d.kids[1], "params", 0).kids, r.pat),
			Infix:  d.head == "def-infix",
			Body:   r.expr(d.kids[2]),
		}
		if len(d.kids) > 3 {
			x.Where = readSeq(r.want(d.kids[3], "where", 0).kids, r.decl)
		}
		return x
	}
	r.failAt(pos, "unknown declaration `%s`", d.head)
	return nil
}

func (r *reader) tyParams(d datum) []TyParam {
	return readSeq(r.want(d, "params", 0).kids, func(k datum) TyParam {
		if k.list {
			r.want(k, "row", 1)
			return TyParam{Pos: k.pos, Name: r.name(k.kids[0]), Row: true}
		}
		return TyParam{Pos: k.pos, Name: r.name(k)}
	})
}

func (r *reader) conDef(d datum) ConDef {
	switch d.head {
	case "con":
		r.want(d, "con", 1)
		return ConDef{Pos: d.pos, Name: r.name(d.kids[0]), Args: readSeq(d.kids[1:], r.typ)}
	case "con-record":
		r.want(d, "con-record", 2)
		// `_` is how the dump writes the name-elided record form; no real
		// constructor can be spelled that way, so the reading is unambiguous.
		name := r.name(d.kids[0])
		if name == "_" {
			name = ""
		}
		fields := r.want(d.kids[1], "fields", 0)
		return ConDef{
			Pos:    d.pos,
			Name:   name,
			Record: true,
			Fields: readSeq(fields.kids, func(k datum) FieldType {
				r.want(k, "field", 2)
				return FieldType{Pos: k.pos, Name: r.name(k.kids[0]), Type: r.typ(k.kids[1])}
			}),
		}
	}
	r.failAt(d.pos, "expected a constructor, found %s", d.describe())
	return ConDef{}
}

// -------------------------------------------------------------------- types

func (r *reader) typ(d datum) Type {
	if !d.list {
		if d.quote != 0 {
			r.failAt(d.pos, "expected a type, found %s", d.describe())
		}
		if isCon(d.text) {
			return &TCon{Pos: d.pos, Name: d.text}
		}
		return &TVar{Pos: d.pos, Name: d.text}
	}
	switch d.head {
	case "app":
		r.want(d, "app", 2)
		return &TApp{Pos: d.pos, Fn: r.typ(d.kids[0]), Args: readSeq(d.kids[1:], r.typ)}
	case "->":
		r.want(d, "->", 2)
		return &TFun{Pos: d.pos, From: r.typ(d.kids[0]), To: r.typ(d.kids[1])}
	case "list":
		r.want(d, "list", 1)
		return &TList{Pos: d.pos, Elem: r.typ(d.kids[0])}
	case "tuple":
		return &TTuple{Pos: d.pos, Items: readSeq(r.want(d, "tuple", 1).kids, r.typ)}
	case "unit":
		return &TUnit{Pos: d.pos}
	case "row-arg":
		r.want(d, "row-arg", 1)
		return &TRow{Pos: d.pos, Name: r.name(d.kids[0])}
	case "with":
		r.want(d, "with", 2)
		return &TWith{Pos: d.pos, Type: r.typ(d.kids[0]), Row: r.row(d.kids[1])}
	case "=>":
		r.want(d, "=>", 2)
		return &TQual{Pos: d.pos, Ctx: r.typ(d.kids[0]), Body: r.typ(d.kids[1])}
	case "own", "lend", "copy":
		r.want(d, d.head, 1)
		return &TTransfer{Pos: d.pos, Mode: d.head, Type: r.typ(d.kids[0])}
	}
	r.failAt(d.pos, "unknown type `%s`", d.head)
	return nil
}

func (r *reader) row(d datum) *Row {
	r.want(d, "row", 0)
	return &Row{Pos: d.pos, Entries: readSeq(d.kids, func(k datum) RowEntry {
		switch k.head {
		case "eff":
			r.want(k, "eff", 1)
			return RowEntry{Pos: k.pos, Var: true, Name: r.name(k.kids[0])}
		case "role", "role-CAPITAL":
			r.want(k, k.head, 2)
			return RowEntry{
				Pos:   k.pos,
				Label: r.name(k.kids[0]),
				Slot:  k.head == "role-CAPITAL",
				Type:  r.typ(k.kids[1]),
			}
		case "slot":
			r.want(k, "slot", 1)
			return RowEntry{Pos: k.pos, Type: r.typ(k.kids[0])}
		}
		r.failAt(k.pos, "unknown row entry `%s`", k.head)
		return RowEntry{}
	})}
}

// ----------------------------------------------------------------- patterns

func (r *reader) pat(d datum) Pat {
	if !d.list {
		switch {
		case d.quote == '"':
			return &PLit{Pos: d.pos, Kind: StrLit, Text: d.text}
		case d.quote == '\'':
			return &PLit{Pos: d.pos, Kind: CharLit, Text: d.text}
		case d.text == "_":
			return &PWild{Pos: d.pos}
		case strings.HasPrefix(d.text, "-"):
			return &PLit{Pos: d.pos, Kind: IntLit, Text: d.text[1:], Neg: true}
		case isDigit(rune(d.text[0])):
			return &PLit{Pos: d.pos, Kind: IntLit, Text: d.text}
		}
		return &PVar{Pos: d.pos, Name: d.text}
	}
	switch d.head {
	case "pcon":
		r.want(d, "pcon", 1)
		return &PCon{Pos: d.pos, Name: r.name(d.kids[0]), Args: readSeq(d.kids[1:], r.pat)}
	case "::":
		r.want(d, "::", 2)
		return &PCons{Pos: d.pos, Head: r.pat(d.kids[0]), Tail: r.pat(d.kids[1])}
	case "tuple":
		return &PTuple{Pos: d.pos, Items: readSeq(r.want(d, "tuple", 1).kids, r.pat)}
	case "list":
		return &PList{Pos: d.pos, Items: readSeq(d.kids, r.pat)}
	case "unit":
		return &PUnit{Pos: d.pos}
	case "as":
		r.want(d, "as", 2)
		return &PAs{Pos: d.pos, Pat: r.pat(d.kids[0]), Name: r.name(d.kids[1])}
	case "precord":
		r.want(d, "precord", 1)
		x := &PRecord{Pos: d.pos, Con: r.name(d.kids[0])}
		for _, k := range d.kids[1:] {
			if !k.list {
				// `..` or `..rest`: the open marker, always last.
				x.Open, x.Rest = true, strings.TrimPrefix(r.name(k), "..")
				continue
			}
			r.want(k, "field", 2)
			x.Fields = append(x.Fields, FieldPat{Pos: k.pos, Name: r.name(k.kids[0]), Pat: r.pat(k.kids[1])})
		}
		return x
	}
	r.failAt(d.pos, "unknown pattern `%s`", d.head)
	return nil
}

// -------------------------------------------------------------- expressions

func (r *reader) expr(d datum) Expr {
	if !d.list {
		switch {
		case d.quote == '"':
			return &Lit{Pos: d.pos, Kind: StrLit, Text: d.text}
		case d.quote == '\'':
			return &Lit{Pos: d.pos, Kind: CharLit, Text: d.text}
		case isDigit(rune(d.text[0])):
			return &Lit{Pos: d.pos, Kind: IntLit, Text: d.text}
		case isCon(d.text):
			return &Con{Pos: d.pos, Name: d.text}
		}
		return &Var{Pos: d.pos, Name: d.text}
	}
	switch d.head {
	case "op":
		r.want(d, "op", 1)
		return &OpRef{Pos: d.pos, Op: r.name(d.kids[0])}

	case "dot":
		r.want(d, "dot", 2)
		name := r.name(d.kids[1])
		return &Dot{Pos: d.pos, Recv: r.expr(d.kids[0]), Name: name, Upper: isCon(name)}

	case "app":
		r.want(d, "app", 2)
		return &App{Pos: d.pos, Fn: r.expr(d.kids[0]), Args: readSeq(d.kids[1:], r.expr)}

	case "infix":
		r.want(d, "infix", 2)
		x := &Infix{Pos: d.pos, Head: r.expr(d.kids[0])}
		for _, k := range d.kids[1:] {
			r.want(k, k.head, 1)
			// Backtick-ness is not recorded: an ALPHABETIC operator can only
			// have been written between backticks, and a symbolic one can only
			// have been written without. The spelling decides.
			x.Tail = append(x.Tail, InfixTerm{
				Pos: k.pos, Op: k.head, Backtick: !isSymbolic(k.head), Rhs: r.expr(k.kids[0]),
			})
		}
		return x

	case "neg":
		r.want(d, "neg", 1)
		return &Neg{Pos: d.pos, Operand: r.expr(d.kids[0])}

	case "lam":
		r.want(d, "lam", 2)
		return &Lam{
			Pos:    d.pos,
			Params: readSeq(r.want(d.kids[0], "params", 0).kids, r.pat),
			Body:   r.expr(d.kids[1]),
		}

	case "if":
		r.want(d, "if", 3)
		return &If{Pos: d.pos, Cond: r.expr(d.kids[0]), Then: r.expr(d.kids[1]), Else: r.expr(d.kids[2])}

	case "case":
		r.want(d, "case", 1)
		x := &Case{Pos: d.pos, Scrut: r.expr(d.kids[0])}
		for _, k := range d.kids[1:] {
			r.want(k, "alt", 2)
			a := Alt{Pos: k.pos, Pat: r.pat(k.kids[0]), Body: r.expr(k.kids[1])}
			if len(k.kids) > 2 {
				a.Where = readSeq(r.want(k.kids[2], "where", 0).kids, r.decl)
			}
			x.Alts = append(x.Alts, a)
		}
		return x

	case "handler":
		r.want(d, "handler", 1)
		x := &HandlerLit{Pos: d.pos, Effect: r.name(d.kids[0])}
		x.Clauses = readSeq(d.kids[1:], r.clause)
		return x

	case "block":
		return &Block{Pos: d.pos, Stmts: readSeq(d.kids, r.stmt)}

	case "let-in":
		r.want(d, "let-in", 2)
		return &LetIn{Pos: d.pos, Bind: r.bind(d.kids[0]), Body: r.expr(d.kids[1])}

	case "handle-in":
		r.want(d, "handle-in", 3)
		label, slot := r.label(d.kids[0])
		return &HandleIn{Pos: d.pos, Label: label, Slot: slot, Handler: r.expr(d.kids[1]), Body: r.expr(d.kids[2])}

	case "use-in":
		r.want(d, "use-in", 2)
		return &UseIn{
			Pos:   d.pos,
			Binds: readSeq(r.want(d.kids[0], "binds", 0).kids, r.useBind),
			Body:  r.expr(d.kids[1]),
		}

	case ":=":
		r.want(d, ":=", 2)
		return &Assign{Pos: d.pos, Target: r.name(d.kids[0]), Value: r.expr(d.kids[1])}

	case "tuple":
		return &Tuple{Pos: d.pos, Items: readSeq(r.want(d, "tuple", 1).kids, r.expr)}

	case "list":
		return &ListLit{Pos: d.pos, Items: readSeq(d.kids, r.expr)}

	case "unit":
		return &Unit{Pos: d.pos}

	case "record":
		r.want(d, "record", 1)
		x := &RecordLit{Pos: d.pos, Con: r.expr(d.kids[0])}
		for _, k := range d.kids[1:] {
			switch k.head {
			case "..":
				x.Spread = r.expr(r.want(k, "..", 1).kids[0])
			case "field":
				r.want(k, "field", 2)
				x.Fields = append(x.Fields, FieldExpr{Pos: k.pos, Name: r.name(k.kids[0]), Value: r.expr(k.kids[1])})
			default:
				r.failAt(k.pos, "a record takes `(.. e)` and `(field n e)`, found %s", k.describe())
			}
		}
		return x
	}
	r.failAt(d.pos, "unknown expression `%s`", d.head)
	return nil
}

func (r *reader) clause(d datum) Clause {
	switch d.head {
	case "var":
		r.want(d, "var", 2)
		return Clause{Pos: d.pos, Kind: ClauseVar, Name: r.name(d.kids[0]), Init: r.expr(d.kids[1])}
	case "return":
		r.want(d, "return", 2)
		return Clause{
			Pos: d.pos, Kind: ClauseReturn, Name: "return",
			Pats: []Pat{r.pat(d.kids[0])}, Body: r.expr(d.kids[1]),
		}
	case "once":
		r.want(d, "once", 4)
		k := r.want(d.kids[2], "k", 1)
		return Clause{
			Pos: d.pos, Kind: ClauseOnce, Name: r.name(d.kids[0]),
			Pats: readSeq(r.want(d.kids[1], "args", 0).kids, r.pat),
			K:    r.name(k.kids[0]), Body: r.expr(d.kids[3]),
		}
	case "clause":
		r.want(d, "clause", 3)
		return Clause{
			Pos: d.pos, Kind: ClausePlain, Name: r.name(d.kids[0]),
			Pats: readSeq(r.want(d.kids[1], "args", 0).kids, r.pat),
			Body: r.expr(d.kids[2]),
		}
	}
	r.failAt(d.pos, "unknown handler clause `%s`", d.head)
	return Clause{}
}

// stmt reads one item of a block. A statement keyword and its DELIMITED inline
// twin have distinct heads in the dump (`let` and `let-in`), so the two never
// have to be told apart by looking for a body.
func (r *reader) stmt(d datum) Stmt {
	if d.list {
		switch d.head {
		case "let":
			r.want(d, "let", 1)
			return &SLet{Pos: d.pos, Bind: r.bind(d.kids[0])}
		case "handle":
			r.want(d, "handle", 2)
			label, slot := r.label(d.kids[0])
			return &SHandle{Pos: d.pos, Label: label, Slot: slot, Handler: r.expr(d.kids[1])}
		case "use":
			return &SUse{Pos: d.pos, Binds: readSeq(r.want(d, "use", 1).kids, r.useBind)}
		case "discard":
			r.want(d, "discard", 1)
			return &SDiscard{Pos: d.pos, X: r.expr(d.kids[0])}
		}
	}
	return &SExpr{Pos: d.pos, X: r.expr(d)}
}

func (r *reader) bind(d datum) Bind {
	switch d.head {
	case "bind":
		r.want(d, "bind", 2)
		// A bare atom here is the plain `let x = e` head. A pattern that is
		// just a name is the same binding written the same way, so reading it
		// as the head form loses nothing and keeps one spelling for one thing.
		if !d.kids[0].list {
			return Bind{Pos: d.pos, Name: r.name(d.kids[0]), Value: r.expr(d.kids[1])}
		}
		return Bind{Pos: d.pos, Pat: r.pat(d.kids[0]), Value: r.expr(d.kids[1])}
	case "bind-fn":
		r.want(d, "bind-fn", 3)
		return Bind{
			Pos:    d.pos,
			Name:   r.name(d.kids[0]),
			Params: readSeq(r.want(d.kids[1], "params", 0).kids, r.pat),
			Value:  r.expr(d.kids[2]),
		}
	}
	r.failAt(d.pos, "expected a binding, found %s", d.describe())
	return Bind{}
}

func (r *reader) useBind(d datum) UseBind {
	r.want(d, "as", 2)
	to, slot := r.label(d.kids[1])
	return UseBind{Pos: d.pos, From: r.name(d.kids[0]), To: to, Slot: slot}
}

// label reads the binding regime a label was written in (spec P2): a
// designation SLOT, a free ROLE, or the elided inline label (D13).
func (r *reader) label(d datum) (string, bool) {
	switch d.head {
	case "elided":
		return "", false
	case "slot":
		r.want(d, "slot", 1)
		return r.name(d.kids[0]), true
	case "role":
		r.want(d, "role", 1)
		return r.name(d.kids[0]), false
	}
	r.failAt(d.pos, "expected a label, found %s", d.describe())
	return "", false
}
