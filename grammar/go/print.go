package wok

import (
	"strings"
	"unicode/utf8"
)

// Format prints a tree as CANONICAL v2 source: the layout is derived from the
// tree alone, so a program has exactly one spelling and `Format` is a fixed
// point of itself. That is what makes it usable as a formatter and as a
// linter -- "this file is not equal to its formatted form" is the whole check.
//
// Three properties are pinned in roundtrip_test.go, and they are what the
// design here is for:
//
//	Dump(Parse(Format(t)))  == Dump(t)     printing preserves the tree
//	Format(Parse(Format(t))) == Format(t)  printing is idempotent
//	Dump(Read(Dump(t)))     == Dump(t)     the dump is a faithful encoding
//
// The tree records no parentheses and no line breaks, so both are RE-DERIVED:
// parentheses from precedence (see the prec* constants), breaks from the two
// facts the tree does record -- a Block is an indented statement sequence, and
// a layout block (case alternatives, handler clauses, class entries) is one
// item per line.
//
// LIMIT: comments are not preserved, because the tokeniser discards them
// (see tokeniser.go, skipSpaceAndComments). Until they are carried as trivia,
// `Format` must not be run over a file a human wrote and kept.
func Format(f *File) string {
	p := &printer{}
	for i, d := range f.Decls {
		if i > 0 && blankBetween(f.Decls[i-1], d) {
			p.nl(0)
		}
		p.decl(d, 0)
		p.b.WriteString("\n")
	}
	return p.b.String()
}

// width is where a line is broken when the construct permits it. It is not a
// hard limit: a form with no safe break point stays on one line however long
// it runs, because a break in the wrong place would change the PARSE rather
// than the layout.
const width = 80

// indentStep is one level of layout. Every nested block indents by it, so a
// block's column is always strictly greater than its parent's -- which is
// exactly what the offside rule in parser.go reads.
const indentStep = 2

type printer struct {
	b strings.Builder
}

func (p *printer) nl(indent int) {
	p.b.WriteString("\n")
	p.b.WriteString(strings.Repeat(" ", indent))
}

// col is the column the next character would land in. Breaking is decided
// against it rather than against the nesting indent: a construct is measured
// from where it actually STARTS, which for `foo = case ... of` is well past
// the indent of the line.
func (p *printer) col() int {
	s := p.b.String() // strings.Builder hands back its buffer; no copy
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return len(s) - i - 1
	}
	return len(s)
}

// render runs f into a fresh printer and returns the text. Breaking decisions
// are made by rendering the flat form first and measuring it, which keeps the
// break rule in one place instead of spread across every caller.
func render(f func(*printer)) string {
	var q printer
	f(&q)
	return q.b.String()
}

// flat renders one construct and reports whether it may be written as-is: it
// must be one line (a nested block already forced a break) and must end before
// the margin.
func (p *printer) flat(f func(*printer)) (string, bool) {
	s := render(f)
	return s, !strings.Contains(s, "\n") && p.col()+len(s) <= width
}

// ------------------------------------------------------------- declarations

// blankBetween decides the ONE piece of vertical whitespace that is not
// derivable from nesting. Declarations are separated by a blank line, with two
// exceptions that are grammatical rather than aesthetic: a run of `module` and
// `import` lines is one header, and a signature belongs to the equation it
// introduces (D23 -- it must precede it, so the pair is a unit).
func blankBetween(prev, next Decl) bool {
	if isHeader(prev) && isHeader(next) {
		return false
	}
	sig, ok := prev.(*SigDecl)
	if !ok {
		return true
	}
	fn, ok := next.(*FunDecl)
	if !ok {
		return true
	}
	for _, n := range sig.Names {
		if n == fn.Name {
			return false
		}
	}
	return true
}

func isHeader(d Decl) bool {
	switch d.(type) {
	case *ModuleDecl, *ImportDecl:
		return true
	}
	return false
}

func (p *printer) decl(d Decl, indent int) {
	switch x := d.(type) {
	case *ModuleDecl:
		p.b.WriteString("module " + strings.Join(x.Path, "."))

	case *ImportDecl:
		p.b.WriteString("import " + strings.Join(x.Path, "."))
		if x.Names != nil {
			names := make([]string, len(x.Names))
			for i, n := range x.Names {
				names[i] = sigName(n)
			}
			p.b.WriteString(" (" + strings.Join(names, ", ") + ")")
		}
		if x.Alias != "" {
			p.b.WriteString(" as " + x.Alias)
		}

	case *TypeDecl:
		p.b.WriteString("type " + x.Name)
		p.tyParams(x.Params)
		p.b.WriteString(" =")
		p.conDefs(x.Cons, indent)

	case *AliasDecl:
		p.b.WriteString("alias " + x.Name)
		p.tyParams(x.Params)
		p.b.WriteString(" = ")
		p.typ(x.Type, precType)

	case *EffectDecl:
		p.b.WriteString("effect " + x.Name)
		p.tyParams(x.Params)
		for _, op := range x.Ops {
			p.nl(indent + indentStep)
			p.b.WriteString(op.Name + " : ")
			p.typ(op.Type, precType)
		}

	case *ClassDecl:
		p.b.WriteString("class " + x.Name)
		p.tyParams(x.Params)
		p.declBlock(x.Entries, indent+indentStep)

	case *InstanceDecl:
		p.b.WriteString("instance ")
		for _, c := range x.Ctx {
			p.b.WriteString("(")
			p.typ(c, precType)
			p.b.WriteString(") => ")
		}
		p.b.WriteString(x.Name)
		for _, a := range x.Args {
			p.b.WriteString(" ")
			p.typ(a, precTypeAtom)
		}
		p.declBlock(x.Body, indent+indentStep)

	case *ForeignDecl:
		p.b.WriteString("foreign module " + x.Name + " " + quoteWok(x.Lib))
		for _, m := range x.Members {
			p.nl(indent + indentStep)
			p.b.WriteString(m.Name)
			if m.Symbol != "" {
				p.b.WriteString(" " + quoteWok(m.Symbol))
			}
			p.b.WriteString(" : ")
			p.typ(m.Type, precType)
		}

	case *SigDecl:
		if x.Extern {
			p.b.WriteString("extern ")
		}
		names := make([]string, len(x.Names))
		for i, n := range x.Names {
			names[i] = sigName(n)
		}
		p.b.WriteString(strings.Join(names, ", ") + " : ")
		p.typ(x.Type, precType)

	case *ExternTypeDecl:
		p.b.WriteString("extern type " + x.Name)
		p.tyParams(x.Params)

	case *FunDecl:
		p.funLHS(x)
		p.b.WriteString(" =")
		p.body(x.Body, indent)
		p.where(x.Where, indent)
	}
}

// funLHS writes an equation's head in the shape it was written: infix between
// its two operands, or prefix with the operator parenthesised.
func (p *printer) funLHS(x *FunDecl) {
	if x.Infix && len(x.Params) == 2 {
		p.pat(x.Params[0], precPatAtom)
		p.b.WriteString(" " + infixName(x.Name) + " ")
		p.pat(x.Params[1], precPatAtom)
		return
	}
	p.b.WriteString(sigName(x.Name))
	for _, prm := range x.Params {
		p.b.WriteString(" ")
		p.pat(prm, precPatAtom)
	}
}

// conDefs writes `= A | B | C` on one line, or one alternative per line once
// that runs past the margin. A leading `|` is legal: the parser reads the bar
// as a separator inside the item, and a continuation line is inside the item
// as long as it is indented past the block column.
func (p *printer) conDefs(cons []ConDef, indent int) {
	one, ok := p.flat(func(q *printer) {
		for i, c := range cons {
			if i > 0 {
				q.b.WriteString(" |")
			}
			q.b.WriteString(" ")
			q.conDef(c)
		}
	})
	if ok {
		p.b.WriteString(one)
		return
	}
	for i, c := range cons {
		p.nl(indent + indentStep)
		if i > 0 {
			p.b.WriteString("| ")
		}
		p.conDef(c)
	}
}

func (p *printer) conDef(c ConDef) {
	p.b.WriteString(c.Name)
	if c.Record {
		if c.Name != "" {
			p.b.WriteString(" ")
		}
		p.b.WriteString("{ ")
		for i, f := range c.Fields {
			if i > 0 {
				p.b.WriteString(", ")
			}
			p.b.WriteString(f.Name + " : ")
			p.typ(f.Type, precType)
		}
		p.b.WriteString(" }")
		return
	}
	for _, a := range c.Args {
		p.b.WriteString(" ")
		p.typ(a, precTypeAtom)
	}
}

func (p *printer) tyParams(ps []TyParam) {
	for _, t := range ps {
		if t.Row {
			p.b.WriteString(" (row " + t.Name + ")")
		} else {
			p.b.WriteString(" " + t.Name)
		}
	}
}

// declBlock writes a layout block of declarations: one per line at indent,
// with no blank lines. A `class` or `instance` body is a list of members, and
// spacing them out would only make the block harder to see as one thing.
func (p *printer) declBlock(ds []Decl, indent int) {
	for _, d := range ds {
		p.nl(indent)
		p.decl(d, indent)
	}
}

// where attaches a local block to the equation or alternative just written.
// It sits one level in from the item, and its declarations one level further:
// `where` must be inside the item (indented past the item's own block column)
// and its block must in turn be inside `where`.
func (p *printer) where(ds []Decl, indent int) {
	if len(ds) == 0 {
		return
	}
	p.nl(indent + indentStep)
	p.b.WriteString("where")
	p.declBlock(ds, indent+2*indentStep)
}

// --------------------------------------------------------------- statements

func (p *printer) stmt(s Stmt, indent int) {
	switch x := s.(type) {
	case *SLet:
		p.b.WriteString("let ")
		p.bind(x.Bind, indent)
	case *SHandle:
		p.b.WriteString("handle " + x.Label + " = ")
		p.expr(x.Handler, precExpr, indent)
	case *SUse:
		p.b.WriteString("use " + useBinds(x.Binds))
	case *SDiscard:
		p.b.WriteString("_ =")
		p.body(x.X, indent)
	case *SExpr:
		p.expr(x.X, precExpr, indent)
	}
}

func (p *printer) bind(b Bind, indent int) {
	switch {
	case b.Pat != nil:
		p.pat(b.Pat, precPat)
	default:
		p.b.WriteString(b.Name)
		for _, prm := range b.Params {
			p.b.WriteString(" ")
			p.pat(prm, precPatAtom)
		}
	}
	p.b.WriteString(" =")
	p.body(b.Value, indent)
}

func useBinds(bs []UseBind) string {
	parts := make([]string, len(bs))
	for i, b := range bs {
		parts[i] = b.From + " as " + b.To
	}
	return strings.Join(parts, ", ")
}

// body writes the right-hand side of `=` or `->`. A Block is the ONE thing
// that forces a break: it is an indented statement sequence in the tree
// precisely because it was one in the source (spec D11), and printing it on
// one line would collapse it into a single expression.
func (p *printer) body(e Expr, indent int) {
	if blk, ok := e.(*Block); ok {
		p.block(blk, indent+indentStep)
		return
	}
	p.b.WriteString(" ")
	p.expr(e, precExpr, indent)
}

func (p *printer) block(blk *Block, indent int) {
	for _, s := range blk.Stmts {
		p.nl(indent)
		p.stmt(s, indent)
	}
}

// -------------------------------------------------------------- expressions
//
// Precedence, tightest last. The tree records no parentheses, so they are
// re-derived here: a form printed where a tighter one is required is wrapped.
// The levels mirror the productions in expr.go exactly -- parseChain builds
// its operands with parseApp, parseApp its operands with parseAtom -- which is
// what makes `expr(e, precApp)` the right question to ask.

const (
	precExpr  = iota // lambda, let/handle/use ... in, if, case, handler, :=
	precChain        // an operator chain
	precApp          // application, prefix negation
	precAtom         // a name, a literal, a bracketed form, a dotted form
)

func precOf(e Expr) int {
	switch e.(type) {
	case *Lam, *LetIn, *HandleIn, *UseIn, *If, *Case, *HandlerLit, *Assign, *Block:
		return precExpr
	case *Infix:
		return precChain
	case *App, *Neg:
		return precApp
	}
	return precAtom
}

func (p *printer) expr(e Expr, prec, indent int) {
	if precOf(e) < prec {
		p.b.WriteString("(")
		p.exprBare(e, indent)
		p.b.WriteString(")")
		return
	}
	p.exprBare(e, indent)
}

func (p *printer) exprBare(e Expr, indent int) {
	switch x := e.(type) {
	case *Var:
		p.b.WriteString(x.Name)

	case *Con:
		p.b.WriteString(x.Name)

	case *Lit:
		p.b.WriteString(litText(x.Kind, x.Text, false))

	case *OpRef:
		p.b.WriteString("(" + x.Op + ")")

	case *Dot:
		p.expr(x.Recv, precAtom, indent)
		p.b.WriteString("." + x.Name)

	case *App:
		p.app(x, indent)

	case *Infix:
		p.infix(x, indent)

	case *Neg:
		p.b.WriteString("-")
		p.expr(x.Operand, precApp, indent)

	case *Lam:
		p.b.WriteString(`\`)
		for i, prm := range x.Params {
			if i > 0 {
				p.b.WriteString(" ")
			}
			p.pat(prm, precPatAtom)
		}
		p.b.WriteString(" ->")
		p.body(x.Body, indent)

	case *If:
		p.ifExpr(x, indent)

	case *Case:
		p.b.WriteString("case ")
		p.expr(x.Scrut, precExpr, indent)
		p.b.WriteString(" of")
		for _, a := range x.Alts {
			p.nl(indent + indentStep)
			p.pat(a.Pat, precPat)
			p.b.WriteString(" ->")
			p.body(a.Body, indent+indentStep)
			p.where(a.Where, indent+indentStep)
		}

	case *HandlerLit:
		p.b.WriteString("handler " + x.Effect)
		for _, c := range x.Clauses {
			p.nl(indent + indentStep)
			p.clause(c, indent+indentStep)
		}

	case *Block:
		// Only reachable from a hand-built tree: the parser produces a Block
		// solely in body position, where `body` prints it as one.
		p.block(x, indent+indentStep)

	case *LetIn:
		p.b.WriteString("let ")
		p.bind(x.Bind, indent+indentStep)
		p.inBody(x.Body, x.Bind.Value, indent)

	case *HandleIn:
		p.b.WriteString("handle ")
		if x.Label != "" {
			p.b.WriteString(x.Label + " = ")
		}
		p.expr(x.Handler, precExpr, indent+indentStep)
		p.inBody(x.Body, x.Handler, indent)

	case *UseIn:
		p.b.WriteString("use " + useBinds(x.Binds))
		p.inBody(x.Body, nil, indent)

	case *Assign:
		p.b.WriteString(x.Target + " :=")
		p.body(x.Value, indent)

	case *Tuple:
		p.bracketed("(", ")", false, len(x.Items), indent, func(q *printer, i int) {
			q.expr(x.Items[i], precExpr, indent+indentStep)
		})

	case *ListLit:
		p.bracketed("[", "]", false, len(x.Items), indent, func(q *printer, i int) {
			q.expr(x.Items[i], precExpr, indent+indentStep)
		})

	case *Unit:
		p.b.WriteString("()")

	case *RecordLit:
		p.expr(x.Con, precAtom, indent)
		n := len(x.Fields)
		if x.Spread != nil {
			n++
		}
		p.b.WriteString(" ")
		p.bracketed("{", "}", true, n, indent, func(q *printer, i int) {
			if x.Spread != nil {
				if i == 0 {
					q.b.WriteString("..")
					q.expr(x.Spread, precExpr, indent+indentStep)
					return
				}
				i--
			}
			q.b.WriteString(x.Fields[i].Name + " = ")
			q.expr(x.Fields[i].Value, precExpr, indent+indentStep)
		})
	}
}

// inBody writes the ` in <body>` tail of a delimited let / handle / use.
//
// When the head ended in a BLOCK the `in` cannot follow on the same line: the
// block runs until a token dedents past it, so `in` goes on its own line, left
// of the block and still inside the enclosing item.
func (p *printer) inBody(body Expr, head Expr, indent int) {
	if blk, _ := head.(*Block); blk != nil {
		p.nl(indent + indentStep)
		p.b.WriteString("in")
		p.body(body, indent)
		return
	}
	p.b.WriteString(" in")
	p.body(body, indent)
}

// ifExpr writes `if c then a else b` on one line, or breaks before `then` and
// `else`. Breaking is safe because both branches keep their first token on the
// keyword's own line: a branch that started on the NEXT line would be read as
// a block (parseBody), which is a different tree.
func (p *printer) ifExpr(x *If, indent int) {
	one, ok := p.flat(func(q *printer) {
		q.b.WriteString("if ")
		q.expr(x.Cond, precExpr, indent)
		q.b.WriteString(" then ")
		q.expr(x.Then, precExpr, indent)
		q.b.WriteString(" else ")
		q.expr(x.Else, precExpr, indent)
	})
	if ok && !isBlock(x.Then) && !isBlock(x.Else) {
		p.b.WriteString(one)
		return
	}
	p.b.WriteString("if ")
	p.expr(x.Cond, precExpr, indent)
	p.nl(indent + indentStep)
	p.b.WriteString("then")
	p.body(x.Then, indent+indentStep)
	p.nl(indent + indentStep)
	p.b.WriteString("else")
	p.body(x.Else, indent+indentStep)
}

func isBlock(e Expr) bool {
	_, ok := e.(*Block)
	return ok
}

// app writes `f a b`, wrapping arguments onto continuation lines once the
// application runs past the margin. A continuation line is indented past the
// item's own column, which is exactly what `inItem` (parser.go) requires for a
// token to still belong to the item being parsed.
func (p *printer) app(x *App, indent int) {
	one, ok := p.flat(func(q *printer) {
		q.expr(x.Fn, precAtom, indent)
		for _, a := range x.Args {
			q.b.WriteString(" ")
			q.expr(a, precAtom, indent)
		}
	})
	if ok {
		p.b.WriteString(one)
		return
	}
	p.expr(x.Fn, precAtom, indent)
	for _, a := range x.Args {
		p.nl(indent + indentStep)
		p.expr(a, precAtom, indent+indentStep)
	}
}

// infix writes a flat operator chain, breaking BEFORE each operator so a
// wrapped line starts with the operator that produced it. Precedence is not
// this pass's business (the chain is flat in the tree), so no grouping is
// invented here.
func (p *printer) infix(x *Infix, indent int) {
	term := func(q *printer, t InfixTerm) {
		q.b.WriteString(infixName(t.Op) + " ")
		q.expr(t.Rhs, precApp, indent+indentStep)
	}
	one, ok := p.flat(func(q *printer) {
		q.expr(x.Head, precApp, indent)
		for _, t := range x.Tail {
			q.b.WriteString(" ")
			term(q, t)
		}
	})
	if ok {
		p.b.WriteString(one)
		return
	}
	p.expr(x.Head, precApp, indent)
	for _, t := range x.Tail {
		p.nl(indent + indentStep)
		term(p, t)
	}
}

// bracketed writes a comma-separated list inside brackets, one item per line
// once it runs past the margin. Layout is SUSPENDED inside brackets (the
// parser pushes a bracket context), so the break is free of the offside rule
// and cannot change the parse whatever the columns come out as.
//
// pad is the one spelling difference between the bracket kinds: a record body
// is written `{ x = 1 }` and a list or tuple `[1, 2]`.
func (p *printer) bracketed(open, close string, pad bool, n, indent int, item func(*printer, int)) {
	space := ""
	if pad && n > 0 {
		space = " "
	}
	one, ok := p.flat(func(q *printer) {
		q.b.WriteString(open + space)
		for i := range n {
			if i > 0 {
				q.b.WriteString(", ")
			}
			item(q, i)
		}
		q.b.WriteString(space + close)
	})
	if ok {
		p.b.WriteString(one)
		return
	}
	p.b.WriteString(open)
	for i := range n {
		p.nl(indent + indentStep)
		item(p, i)
		if i < n-1 {
			p.b.WriteString(",")
		}
	}
	p.nl(indent)
	p.b.WriteString(close)
}

func (p *printer) clause(c Clause, indent int) {
	switch c.Kind {
	case ClauseVar:
		p.b.WriteString("var " + c.Name + " =")
		p.body(c.Init, indent)
	case ClauseReturn:
		p.b.WriteString("return ")
		p.pat(c.Pats[0], precPat)
		p.b.WriteString(" ->")
		p.body(c.Body, indent)
	case ClauseOnce:
		p.b.WriteString("once " + c.Name)
		for _, a := range c.Pats {
			p.b.WriteString(" ")
			p.pat(a, precPatAtom)
		}
		p.b.WriteString(" " + c.K + " ->")
		p.body(c.Body, indent)
	default:
		p.b.WriteString(c.Name)
		for _, a := range c.Pats {
			p.b.WriteString(" ")
			p.pat(a, precPatAtom)
		}
		p.b.WriteString(" ->")
		p.body(c.Body, indent)
	}
}

// ----------------------------------------------------------------- patterns

const (
	precPat     = iota // x :: xs
	precPatApp         // Just x
	precPatAtom        // x, _, 3, (p), [p], Point { .. }, p as name
)

func precOfPat(pt Pat) int {
	switch x := pt.(type) {
	case *PCons:
		return precPat
	case *PCon:
		if len(x.Args) > 0 {
			return precPatApp
		}
	}
	return precPatAtom
}

func (p *printer) pat(pt Pat, prec int) {
	if precOfPat(pt) < prec {
		p.b.WriteString("(")
		p.patBare(pt)
		p.b.WriteString(")")
		return
	}
	p.patBare(pt)
}

func (p *printer) patBare(pt Pat) {
	switch x := pt.(type) {
	case *PVar:
		p.b.WriteString(x.Name)
	case *PWild:
		p.b.WriteString("_")
	case *PLit:
		p.b.WriteString(litText(x.Kind, x.Text, x.Neg))
	case *PCon:
		p.b.WriteString(x.Name)
		for _, a := range x.Args {
			p.b.WriteString(" ")
			p.pat(a, precPatAtom)
		}
	case *PCons:
		p.pat(x.Head, precPatApp)
		p.b.WriteString(" :: ")
		p.pat(x.Tail, precPat)
	case *PTuple:
		p.b.WriteString("(")
		for i, it := range x.Items {
			if i > 0 {
				p.b.WriteString(", ")
			}
			p.pat(it, precPat)
		}
		p.b.WriteString(")")
	case *PList:
		p.b.WriteString("[")
		for i, it := range x.Items {
			if i > 0 {
				p.b.WriteString(", ")
			}
			p.pat(it, precPat)
		}
		p.b.WriteString("]")
	case *PUnit:
		p.b.WriteString("()")
	case *PAs:
		p.pat(x.Pat, precPatAtom)
		p.b.WriteString(" as " + x.Name)
	case *PRecord:
		p.b.WriteString(x.Con + " {")
		parts := make([]string, 0, len(x.Fields)+1)
		for _, f := range x.Fields {
			parts = append(parts, render(func(q *printer) {
				q.b.WriteString(f.Name + " = ")
				q.pat(f.Pat, precPat)
			}))
		}
		if x.Open {
			parts = append(parts, ".."+x.Rest)
		}
		if len(parts) > 0 {
			p.b.WriteString(" " + strings.Join(parts, ", ") + " ")
		}
		p.b.WriteString("}")
	}
}

// -------------------------------------------------------------------- types

const (
	precType     = iota // (C a) => T, T with row
	precArrow           // A -> B
	precTypeApp         // Maybe a, own Bytes
	precTypeAtom        // a, Con, [T], (T, T), (), (row e)
)

func precOfType(t Type) int {
	switch t.(type) {
	case *TQual, *TWith:
		return precType
	case *TFun:
		return precArrow
	case *TApp, *TTransfer:
		return precTypeApp
	}
	return precTypeAtom
}

func (p *printer) typ(t Type, prec int) {
	if precOfType(t) < prec {
		p.b.WriteString("(")
		p.typBare(t)
		p.b.WriteString(")")
		return
	}
	p.typBare(t)
}

func (p *printer) typBare(t Type) {
	switch x := t.(type) {
	case *TVar:
		p.b.WriteString(x.Name)
	case *TCon:
		p.b.WriteString(x.Name)
	case *TApp:
		p.typ(x.Fn, precTypeAtom)
		for _, a := range x.Args {
			p.b.WriteString(" ")
			p.typ(a, precTypeAtom)
		}
	case *TFun:
		p.typ(x.From, precTypeApp)
		p.b.WriteString(" -> ")
		p.typ(x.To, precArrow)
	case *TList:
		p.b.WriteString("[")
		p.typ(x.Elem, precType)
		p.b.WriteString("]")
	case *TTuple:
		p.b.WriteString("(")
		for i, it := range x.Items {
			if i > 0 {
				p.b.WriteString(", ")
			}
			p.typ(it, precType)
		}
		p.b.WriteString(")")
	case *TUnit:
		p.b.WriteString("()")
	case *TRow:
		p.b.WriteString("(row " + x.Name + ")")
	case *TWith:
		p.typ(x.Type, precArrow)
		p.b.WriteString(" with ")
		p.row(x.Row)
	case *TQual:
		// The context is always parenthesised. `instance` requires it
		// (parseInstanceDecl reads a type ATOM there), so writing it the same
		// way in both places keeps one spelling for one thing.
		p.b.WriteString("(")
		p.typ(x.Ctx, precType)
		p.b.WriteString(") => ")
		p.typ(x.Body, precType)
	case *TTransfer:
		p.b.WriteString(x.Mode + " ")
		p.typ(x.Type, precTypeAtom)
	}
}

func (p *printer) row(r *Row) {
	for i, e := range r.Entries {
		if i > 0 {
			p.b.WriteString(" + ")
		}
		switch {
		case e.Var:
			p.b.WriteString("eff " + e.Name)
		case e.Label != "":
			p.b.WriteString("(" + e.Label + " : ")
			p.typ(e.Type, precType)
			p.b.WriteString(")")
		default:
			p.typ(e.Type, precTypeApp)
		}
	}
}

// ------------------------------------------------------------------ lexemes

// isSymbolic reports whether a name is spelled out of operator characters, and
// so must be parenthesised where a plain name is expected and backtick-free
// where an operator is. It is the ONE fact that distinguishes `(+) x y` from
// `add x y` and `x + y` from "x `add` y" -- which is why neither the tree nor
// the dump has to record it.
func isSymbolic(name string) bool {
	if name == "" {
		return false
	}
	r, _ := utf8.DecodeRuneInString(name)
	return isSymChar(r) || name == "::"
}

// sigName writes a name where a NAME is expected: an operator needs brackets.
func sigName(name string) string {
	if isSymbolic(name) {
		return "(" + name + ")"
	}
	return name
}

// infixName writes a name where an OPERATOR is expected: an alphabetic one
// needs backticks.
func infixName(name string) string {
	if isSymbolic(name) {
		return name
	}
	return "`" + name + "`"
}

func litText(k Kind, text string, neg bool) string {
	switch k {
	case StrLit:
		return quoteWok(text)
	case CharLit:
		r, _ := utf8.DecodeRuneInString(text)
		return quoteWokRune(r)
	default:
		if neg {
			return "-" + text
		}
		return text
	}
}

// quoteWok quotes a string using WOK's escapes, not Go's. strconv.Quote would
// happily emit `\x00` and `é`, which this language's scanner (see
// `escapes` in tokeniser.go) cannot read back.
func quoteWok(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		writeEscaped(&b, r, '"')
	}
	b.WriteByte('"')
	return b.String()
}

func quoteWokRune(r rune) string {
	var b strings.Builder
	b.WriteByte('\'')
	writeEscaped(&b, r, '\'')
	b.WriteByte('\'')
	return b.String()
}

// writeEscaped writes one rune, escaping it when the scanner would otherwise
// misread it: the quote that delimits the literal, the backslash that starts
// an escape, and the four control characters that have a spelling.
func writeEscaped(b *strings.Builder, r rune, quote rune) {
	switch r {
	case '\n':
		b.WriteString(`\n`)
	case '\t':
		b.WriteString(`\t`)
	case '\r':
		b.WriteString(`\r`)
	case 0:
		b.WriteString(`\0`)
	case '\\':
		b.WriteString(`\\`)
	case quote:
		b.WriteByte('\\')
		b.WriteRune(r)
	default:
		b.WriteRune(r)
	}
}
