package wok

import "fmt"

// Parse tokenises and parses one v2 source file, reporting EVERY fault it can
// isolate rather than the first (see "recovery" below). The error is an
// ErrorList; File is the partial tree and must not be consumed when err != nil.
//
// Lexical faults short-circuit: a damaged token stream makes parse errors
// guesswork, so those are reported alone and parsing does not run.
func Parse(file, src string) (*File, error) {
	toks, lexErr := Tokenise(file, src)
	if lexErr != nil {
		return nil, lexErr
	}
	p := &parser{collector: collector{file: file}, toks: toks}
	return p.parseFile(), p.errs.err()
}

type parser struct {
	collector
	toks []Token
	idx  int

	layout  []layoutCtx
	foreign bool // inside a foreign member signature: own/lend/copy are live
}

// bail unwinds one item's parse to its enclosing block, where recovery
// resumes. It never escapes Parse.
type bail struct{ err *Error }

// stop unwinds the WHOLE parse: the error cap was reached and further
// messages would be noise, not a work list.
type stop struct{}

// ------------------------------------------------------------ the layout core
//
// There is no layout pre-pass and there are no virtual tokens. A block is a
// stack entry holding the column its items start at, and three questions
// answer every layout decision:
//
//	inItem()  the next token is on the same line, or indented past the block
//	          column -> it continues the item being parsed
//	col ==    a new line at exactly the block column -> the next item
//	col <     a new line left of the block column -> the block is over
//
// `(`, `[` and `{` push a BRACKET context, which suspends the rule until the
// matching closer: inside brackets, line breaks and columns mean nothing.

type layoutCtx struct {
	col     int
	bracket bool
}

func (p *parser) blockCol() int {
	if n := len(p.layout); n > 0 {
		if p.layout[n-1].bracket {
			return 0
		}
		return p.layout[n-1].col
	}
	return 0
}

// sameLine reports whether the current token continues the line of the token
// before it. The tokeniser already decided that (Token.First), so a layout
// question costs one field read and never a look backwards.
func (p *parser) sameLine() bool { return !p.tok().First }

// inItem reports whether the current token still belongs to the item being
// parsed. Every argument loop and operator loop is guarded by it.
func (p *parser) inItem() bool {
	if p.at(EOF) {
		return false
	}
	return p.sameLine() || p.tok().Col > p.blockCol()
}

// items parses a layout block whose items start at column col. This is the
// ONE place recovery happens.
//
// Layout is what makes that reliable: the block already knows where the next
// item begins, so a failed item is abandoned and the next one is picked up at
// its column -- no hunting for a `;` or `}` that might mean anything. Recovery
// is deliberately confined to item granularity (one message per declaration,
// statement, alternative or clause); resynchronising mid-expression is where
// parsers start inventing faults that are not there.
// The `starts` predicate is the RESYNCHRONISATION ANCHOR: after a fault,
// skipping stops only at a token that could genuinely begin an item of this
// block, not at whatever happens to sit at the block column. Declaration
// blocks pass startsDecl, signature blocks startsSig; statements,
// alternatives and clauses pass nil and resynchronise on the column alone,
// which is already unambiguous for them.
func (p *parser) items(col int, what string, starts func() bool, item func()) {
	if col <= p.blockCol() {
		p.fail(p.tok(), "expected an indented block of %ss (column %d or more)", what, p.blockCol()+1)
	}
	p.layout = append(p.layout, layoutCtx{col: col})
	depth := len(p.layout)
	for {
		before := p.idx
		if err := p.attempt(item); err != nil {
			// The failed item may have been midway through a bracket or a
			// foreign signature. Restoring both is what stops one fault from
			// corrupting every column comparison after it.
			p.layout = p.layout[:depth]
			p.foreign = false
			p.report(err)
			p.skipPastItem(col, before, starts)
		} else if p.idx == before {
			p.fail(p.tok(), "expected a %s", what)
		}
		// `where` never starts an item; it closes the block it follows and
		// attaches to the enclosing equation or alternative.
		if p.atWord(KwWhere) {
			break
		}
		if p.at(EOF) || p.tok().Col < col {
			break
		}
		if p.tok().Col > col {
			p.report(p.errorf(p.tok().Line, p.tok().Col,
				"unexpected indentation before %s: expected the next %s at column %d",
				describe(p.tok()), what, col))
			p.skipPastItem(col, p.idx, starts)
			if p.at(EOF) || p.tok().Col < col {
				break
			}
		}
	}
	p.layout = p.layout[:depth-1]
}

// report records a fault and, once the cap is reached, unwinds the whole
// parse: past that point further messages are noise rather than a work list.
func (p *parser) report(err *Error) {
	p.record(err)
	if p.full {
		panic(stop{})
	}
}

// attempt runs one item, converting its bail into a returned error. The cap
// panic (stop) is left to unwind past every block to Parse.
func (p *parser) attempt(item func()) (err *Error) {
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		b, ok := r.(bail)
		if !ok {
			panic(r)
		}
		err = b.err
	}()
	item()
	return nil
}

// skipPastItem consumes tokens up to the start of the next item in a block at
// column col. It always consumes at least one token, so recovery cannot loop.
//
// Two stopping rules, in order:
//
//	dedent  a token left of the block column always ends the skip, so a
//	        damaged item can never swallow the block that contains it
//	anchor  at the block column, stop only where an item could BEGIN
//
// The anchor is what turns a misindented run into one fault instead of one
// per line: skipping walks over the wreckage to the next thing that is
// recognisably a declaration.
func (p *parser) skipPastItem(col, before int, starts func() bool) {
	if p.idx == before {
		p.next()
	}
	for !p.at(EOF) {
		if !p.sameLine() {
			if p.tok().Col < col {
				return
			}
			if p.tok().Col == col && (starts == nil || starts()) {
				return
			}
		}
		p.next()
	}
}

// startsDecl reports whether the current token could begin a DECLARATION: a
// declaration keyword, a signature, or an equation head. A ConId, an operator
// or a closing bracket at the block column is wreckage, not a fresh start.
func (p *parser) startsDecl() bool {
	t := p.tok()
	if t.Kind == Keyword {
		switch t.Word {
		case KwModule, KwImport, KwType, KwAlias, KwEffect,
			KwClass, KwInstance, KwForeign, KwExtern:
			return true
		}
		return false
	}
	return t.Kind == VarId || t.Kind == LParen
}

// startsSig is the anchor for blocks whose every item is `name : Type`
// (effect operations, foreign members).
func (p *parser) startsSig() bool { return p.at(VarId) }

// block parses a layout block introduced by the construct just parsed: either
// a single item on the CURRENT line (`handler Tick tick x -> x * 2`), or an
// indented block on the following lines.
//
// There is no item separator: v2 has no `;`, so a block's items are delimited
// by columns and nothing else.
func (p *parser) block(what string, starts func() bool, item func()) {
	if p.sameLine() {
		item()
		return
	}
	p.items(p.tok().Col, what, starts, item)
}

// parseBody parses the right-hand side of `=` or `->`: an expression on the
// same line, or an indented BLOCK -- a sequence of statements whose last line
// is its value (spec D11).
func (p *parser) parseBody() Expr {
	if p.sameLine() {
		return p.parseExpr()
	}
	blk := &Block{Pos: p.here()}
	p.items(p.tok().Col, "statement", nil, func() {
		blk.Stmts = append(blk.Stmts, p.parseStmt())
	})
	return blk
}

func (p *parser) openBracket(k Kind, what string) Token {
	t := p.expect(k, what)
	p.layout = append(p.layout, layoutCtx{bracket: true})
	return t
}

func (p *parser) closeBracket(k Kind, what string) Token {
	t := p.expect(k, what)
	p.layout = p.layout[:len(p.layout)-1]
	return t
}

// ------------------------------------------------------------ token plumbing

func (p *parser) tok() Token { return p.toks[p.idx] }

func (p *parser) peek(n int) Token {
	if p.idx+n >= len(p.toks) {
		return p.toks[len(p.toks)-1]
	}
	return p.toks[p.idx+n]
}

func (p *parser) here() Pos { return Pos{Line: p.tok().Line, Col: p.tok().Col} }

func at(t Token) Pos { return Pos{Line: t.Line, Col: t.Col} }

func (p *parser) next() Token {
	t := p.toks[p.idx]
	if t.Kind != EOF {
		p.idx++
	}
	return t
}

func (p *parser) at(k Kind) bool { return p.tok().Kind == k }

// atWord matches a NAMED SPELLING, whichever register it belongs to: a
// reserved word (KwLet), a contextual word (CwRow) or an operator run a
// production reads by name (OpPlus). The Word already encodes which -- the
// tokeniser gives `let` its word only as a Keyword and `row` its word only as
// a VarId -- so one helper covers all three and no kind check is needed here.
func (p *parser) atWord(w Word) bool { return p.tok().Word == w }

func (p *parser) accept(k Kind) bool {
	if p.at(k) {
		p.next()
		return true
	}
	return false
}

func (p *parser) acceptWord(w Word) bool {
	if p.atWord(w) {
		p.next()
		return true
	}
	return false
}

func (p *parser) expect(k Kind, what string) Token {
	if !p.at(k) {
		p.fail(p.tok(), "expected %s, found %s", what, describe(p.tok()))
	}
	return p.next()
}

func (p *parser) expectWord(w Word) Token {
	if !p.atWord(w) {
		p.fail(p.tok(), "expected `%s`, found %s", w, describe(p.tok()))
	}
	return p.next()
}

// expectName accepts a lowercase or uppercase name; Slot-ness (P2) is decided
// by the caller from the token kind.
func (p *parser) expectName(what string) Token {
	if !p.at(VarId) && !p.at(ConId) {
		p.fail(p.tok(), "expected %s, found %s", what, describe(p.tok()))
	}
	return p.next()
}

func describe(t Token) string {
	switch t.Kind {
	case EOF:
		return "end of file"
	case Keyword:
		return fmt.Sprintf("keyword `%s`", t.Text)
	case VarId, ConId, VarSym, IntLit:
		return fmt.Sprintf("`%s`", t.Text)
	case StrLit, CharLit:
		return fmt.Sprintf("%s %q", t.Kind, t.Text)
	default:
		return fmt.Sprintf("`%s`", t.Kind)
	}
}

func (p *parser) fail(t Token, format string, args ...any) {
	p.failAt(at(t), format, args...)
}

// failAt blames a position rather than the current token: used where the
// offending thing is behind us (an ill-formed `:=` target, say).
func (p *parser) failAt(pos Pos, format string, args ...any) {
	panic(bail{p.errorf(pos.Line, pos.Col, format, args...)})
}

// ------------------------------------------------------------- declarations

func (p *parser) parseFile() (f *File) {
	f = &File{Name: p.file}
	if p.at(EOF) {
		return f
	}
	// The cap unwinds the whole parse; the batch collected so far still
	// stands, with a final line saying why it ends here.
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		if _, ok := r.(stop); !ok {
			panic(r)
		}
		p.errs = append(p.errs, p.errorf(p.tok().Line, p.tok().Col,
			"too many errors; stopping here"))
	}()
	p.items(p.tok().Col, "declaration", p.startsDecl, func() {
		f.Decls = append(f.Decls, p.parseDecl())
	})
	p.checkForwardOrder(f.Decls)
	if !p.at(EOF) {
		p.record(p.errorf(p.tok().Line, p.tok().Col,
			"unexpected %s after the last declaration", describe(p.tok())))
	}
	return f
}

func (p *parser) parseDecl() Decl {
	// Every word below is reserved, so the Word alone identifies the form: no
	// kind check, and no identifier can reach these arms.
	switch p.tok().Word {
	case KwModule:
		return p.parseModuleDecl()
	case KwImport:
		return p.parseImportDecl()
	case KwType:
		return p.parseTypeDecl()
	case KwAlias:
		return p.parseAliasDecl()
	case KwEffect:
		return p.parseEffectDecl()
	case KwClass:
		return p.parseClassDecl()
	case KwInstance:
		return p.parseInstanceDecl()
	case KwForeign:
		return p.parseForeignDecl()
	case KwExtern:
		return p.parseExternDecl()
	}
	return p.parseSigOrEqn()
}

// module Main
func (p *parser) parseModuleDecl() Decl {
	pos := p.here()
	p.expectWord(KwModule)
	return &ModuleDecl{Pos: pos, Path: p.parseModPath()}
}

// import Geometry (area, Point) as G
func (p *parser) parseImportDecl() Decl {
	pos := p.here()
	p.expectWord(KwImport)
	d := &ImportDecl{Pos: pos, Path: p.parseModPath()}
	if p.at(LParen) && p.inItem() {
		p.openBracket(LParen, "`(` of an import list")
		d.Names = []string{}
		for !p.at(RParen) {
			d.Names = append(d.Names, p.parseImportName())
			if !p.accept(Comma) {
				break
			}
		}
		p.closeBracket(RParen, "`)` closing the import list")
	}
	if p.atWord(KwAs) && p.inItem() {
		p.next()
		d.Alias = p.expect(ConId, "an alias name").Text
	}
	return d
}

func (p *parser) parseImportName() string {
	if p.at(LParen) {
		p.next()
		op := p.expect(VarSym, "an operator name").Text
		p.expect(RParen, "`)` after the operator name")
		return op
	}
	return p.expectName("an imported name").Text
}

func (p *parser) parseModPath() []string {
	path := []string{p.expect(ConId, "a module name").Text}
	for p.at(Period) && p.peek(1).Kind == ConId {
		p.next()
		path = append(path, p.next().Text)
	}
	return path
}

// type Color = Red | Green | Blue
// type Point = { x : U64, y : U64 }
func (p *parser) parseTypeDecl() Decl {
	pos := p.here()
	p.expectWord(KwType)
	d := &TypeDecl{Pos: pos, Name: p.expect(ConId, "a type name").Text}
	d.Params = p.parseTyParams()
	p.expect(Equals, "`=` in a type declaration")
	for {
		d.Cons = append(d.Cons, p.parseConDef())
		if !(p.inItem() && p.accept(Bar)) {
			break
		}
	}
	return d
}

func (p *parser) parseConDef() ConDef {
	pos := p.here()
	// The name-elided record form: `type Point = { x : U64 }`.
	if p.at(LBrace) {
		return ConDef{Pos: pos, Record: true, Fields: p.parseFieldTypes()}
	}
	c := ConDef{Pos: pos, Name: p.expect(ConId, "a constructor name").Text}
	if p.at(LBrace) && p.inItem() {
		c.Record = true
		c.Fields = p.parseFieldTypes()
		return c
	}
	for p.inItem() && p.startsTypeAtom() {
		c.Args = append(c.Args, p.parseTypeAtom())
	}
	return c
}

func (p *parser) parseFieldTypes() []FieldType {
	p.openBracket(LBrace, "`{` of a record type")
	var fs []FieldType
	for !p.at(RBrace) {
		pos := p.here()
		name := p.expect(VarId, "a field name").Text
		p.expect(Colon, "`:` after a field name")
		fs = append(fs, FieldType{Pos: pos, Name: name, Type: p.parseType()})
		if !p.accept(Comma) {
			break
		}
	}
	p.closeBracket(RBrace, "`}` closing the record type")
	return fs
}

// alias Weighted = [(U64, U64)]
func (p *parser) parseAliasDecl() Decl {
	pos := p.here()
	p.expectWord(KwAlias)
	d := &AliasDecl{Pos: pos, Name: p.expect(ConId, "an alias name").Text}
	d.Params = p.parseTyParams()
	p.expect(Equals, "`=` in an alias declaration")
	d.Type = p.parseType()
	return d
}

// effect State s
//
//	get : s
//	set : s -> ()
func (p *parser) parseEffectDecl() Decl {
	pos := p.here()
	p.expectWord(KwEffect)
	d := &EffectDecl{Pos: pos, Name: p.expect(ConId, "an effect name").Text}
	d.Params = p.parseTyParams()
	p.block("operation signature", p.startsSig, func() {
		opPos := p.here()
		name := p.expect(VarId, "an operation name").Text
		p.expect(Colon, "`:` after an operation name")
		d.Ops = append(d.Ops, OpSig{Pos: opPos, Name: name, Type: p.parseType()})
	})
	return d
}

// class Eq a
//
//	(==) : a -> a -> Bool
func (p *parser) parseClassDecl() Decl {
	pos := p.here()
	p.expectWord(KwClass)
	d := &ClassDecl{Pos: pos, Name: p.expect(ConId, "a class name").Text}
	d.Params = p.parseTyParams()
	p.block("class entry", p.startsDecl, func() {
		d.Entries = append(d.Entries, p.parseSigOrEqn())
	})
	p.checkForwardOrder(d.Entries)
	return d
}

// instance Eq Color / instance (Eq a) => Eq [a]
func (p *parser) parseInstanceDecl() Decl {
	pos := p.here()
	p.expectWord(KwInstance)
	d := &InstanceDecl{Pos: pos}
	if p.at(LParen) {
		ctx := p.parseTypeAtom()
		p.expect(FatArrow, "`=>` after an instance context")
		d.Ctx = []Type{ctx}
	}
	d.Name = p.expect(ConId, "a class name").Text
	for p.sameLine() && p.startsTypeAtom() { // the instance body block follows
		d.Args = append(d.Args, p.parseTypeAtom())
	}
	p.block("instance method", p.startsDecl, func() {
		d.Body = append(d.Body, p.parseSigOrEqn())
	})
	p.checkForwardOrder(d.Body)
	return d
}

// foreign module Libc "c"
//
//	strlen : lend Bytes -> U64
func (p *parser) parseForeignDecl() Decl {
	pos := p.here()
	p.expectWord(KwForeign)
	p.expectWord(KwModule)
	d := &ForeignDecl{Pos: pos, Name: p.expect(ConId, "a foreign module name").Text}
	d.Lib = p.expect(StrLit, "the library name").Text
	p.block("foreign member", p.startsSig, func() {
		mPos := p.here()
		m := ForeignMember{Pos: mPos, Name: p.expect(VarId, "a member name").Text}
		if p.at(StrLit) {
			m.Symbol = p.next().Text
		}
		p.expect(Colon, "`:` after a member name")
		p.foreign = true
		m.Type = p.parseType()
		p.foreign = false
		d.Members = append(d.Members, m)
	})
	return d
}

// extern reset : () -> ()      (the prelude-only trust anchor)
// extern type Suspension a b r (row e)
func (p *parser) parseExternDecl() Decl {
	pos := p.here()
	p.expectWord(KwExtern)
	if p.acceptWord(KwType) {
		d := &ExternTypeDecl{Pos: pos, Name: p.expect(ConId, "a type name").Text}
		d.Params = p.parseTyParams()
		return d
	}
	d, ok := p.parseSigOrEqn().(*SigDecl)
	if !ok {
		p.fail(p.tok(), "`extern` introduces a signature, not an equation")
	}
	d.Pos = pos
	d.Extern = true
	return d
}

// parseTyParams reads the parameters of a type-constructor head. They must sit
// on the head's own line: `effect State s` is followed by a layout block, and
// inItem() alone would happily read the block's first line as another
// parameter.
func (p *parser) parseTyParams() []TyParam {
	var ps []TyParam
	for p.sameLine() {
		switch {
		case p.at(VarId):
			t := p.next()
			ps = append(ps, TyParam{Pos: at(t), Name: t.Text})
		case p.at(LParen) && p.peek(1).Word == CwRow:
			pos := p.here()
			p.next()
			p.next()
			name := p.expect(VarId, "a row variable").Text
			p.expect(RParen, "`)` after a row parameter")
			ps = append(ps, TyParam{Pos: pos, Name: name, Row: true})
		default:
			return ps
		}
	}
	return ps
}

// parseSigOrEqn parses the two unkeyworded declaration forms: a signature
// (`f, (+) : T`) or an equation (`f x = e`).
func (p *parser) parseSigOrEqn() Decl {
	if p.looksLikeSig() {
		pos := p.here()
		d := &SigDecl{Pos: pos}
		for {
			d.Names = append(d.Names, p.parseSigName())
			if !p.accept(Comma) {
				break
			}
		}
		p.expect(Colon, "`:` in a signature")
		d.Type = p.parseType()
		return d
	}

	pos := p.here()
	name, params, infix := p.parseFunLHS()
	p.expect(Equals, "`=` after the left-hand side")
	d := &FunDecl{Pos: pos, Name: name, Params: params, Infix: infix}
	d.Body = p.parseBody()
	d.Where = p.parseWhere()
	return d
}

// looksLikeSig scans (without consuming) for `name , name ... :`.
func (p *parser) looksLikeSig() bool {
	i := p.idx
	for {
		switch {
		case p.toks[i].Kind == VarId:
			i++
		case p.toks[i].Kind == LParen && p.toks[i+1].Kind == VarSym && p.toks[i+2].Kind == RParen:
			i += 3
		default:
			return false
		}
		if p.toks[i].Kind == Comma {
			i++
			continue
		}
		return p.toks[i].Kind == Colon
	}
}

func (p *parser) parseSigName() string {
	if p.at(LParen) {
		p.next()
		op := p.expect(VarSym, "an operator name").Text
		p.expect(RParen, "`)` after the operator name")
		return op
	}
	return p.expect(VarId, "a name").Text
}

// parseFunLHS parses the left-hand side of an equation in its three forms:
//
//	add x y     prefix
//	(+) x y     prefix, parenthesised operator
//	x + y       infix, symbolic
//	x `add` y   infix, backticked
func (p *parser) parseFunLHS() (name string, params []Pat, infix bool) {
	switch {
	case p.at(LParen) && p.peek(1).Kind == VarSym && p.peek(2).Kind == RParen:
		p.next()
		name = p.next().Text
		p.next()
	case p.at(VarId) && !p.startsInfixOpAt(1):
		name = p.next().Text
	default:
		lhs := p.parseAtomPat()
		switch {
		case p.at(VarSym):
			name = p.next().Text
		case p.at(Backtick):
			p.next()
			name = p.expect(VarId, "an operator name").Text
			p.expect(Backtick, "a closing backtick")
		default:
			p.fail(p.tok(), "expected an operator between the two left-hand-side patterns")
		}
		return name, []Pat{lhs, p.parseAtomPat()}, true
	}
	for p.inItem() && p.startsAtomPat() {
		params = append(params, p.parseAtomPat())
	}
	return name, params, false
}

func (p *parser) startsInfixOpAt(n int) bool {
	k := p.peek(n).Kind
	return k == VarSym || k == Backtick || k == Cons
}

// checkForwardOrder enforces that a signature PRECEDES the equation it
// describes (D23). v2 reads forward only: a reader, and a single-pass front
// end, meet the type before the code it constrains, and never has to scan back
// for a signature that might appear later.
//
// It also makes a signature the strongest resynchronisation anchor there is
// (see startsDecl): after a fault, the next `name : Type` is unambiguously a
// fresh declaration and cannot be the tail of the damaged one.
//
// The rule is per declaration BLOCK, so a local `where` binding may carry its
// own signature independently of the top level.
func (p *parser) checkForwardOrder(decls []Decl) {
	defined := map[string]Pos{}
	for _, d := range decls {
		switch x := d.(type) {
		case *FunDecl:
			if _, seen := defined[x.Name]; !seen {
				defined[x.Name] = x.Position()
			}
		case *SigDecl:
			for _, name := range x.Names {
				if at, seen := defined[name]; seen {
					p.report(p.errorf(x.Position().Line, x.Position().Col,
						"signature for `%s` comes after its definition at %s: "+
							"v2 reads forward only, so a signature must precede its equation",
						name, at))
					break
				}
			}
		}
	}
}

func (p *parser) parseWhere() []Decl {
	if !(p.atWord(KwWhere) && p.inItem()) {
		return nil
	}
	p.next()
	var ds []Decl
	p.block("local declaration", p.startsDecl, func() {
		ds = append(ds, p.parseSigOrEqn())
	})
	p.checkForwardOrder(ds)
	return ds
}
