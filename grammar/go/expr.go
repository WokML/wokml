package wok

// Statements and expressions.
//
// A block is a SEQUENCE (spec D11): `let` / `handle` / `use` are STATEMENTS
// that scope over the rest of the block, `_ = e` is the explicit discard, and
// the final line is the block's value. Each of those keywords also has a
// DELIMITED INLINE twin ending in `in`; the two are told apart by looking for
// `in` after the head, so the duality lives in one place per keyword.

func (p *parser) parseStmt() Stmt {
	pos := p.here()
	switch {
	case p.atWord(KwLet):
		p.next()
		b := p.parseBind()
		if p.acceptWord(KwIn) {
			return &SExpr{Pos: pos, X: &LetIn{Pos: pos, Bind: b, Body: p.parseBody()}}
		}
		return &SLet{Pos: pos, Bind: b}

	case p.atWord(KwHandle):
		p.next()
		label, slot, h := p.parseHandleHead()
		if p.acceptWord(KwIn) {
			return &SExpr{Pos: pos, X: &HandleIn{Pos: pos, Label: label, Slot: slot, Handler: h, Body: p.parseBody()}}
		}
		if label == "" {
			// P1: a statement handle's extent is invisible, so its label must
			// be greppable text. Only the delimited form may elide it (D13).
			// Blame the `handle` itself: the handler expression is already
			// consumed, so the current token is on the NEXT line.
			p.failAt(pos, "a `handle` statement must write its label: `handle <label> = <handler>`")
		}
		return &SHandle{Pos: pos, Label: label, Slot: slot, Handler: h}

	case p.atWord(KwUse):
		p.next()
		binds := p.parseUseBinds()
		if p.acceptWord(KwIn) {
			return &SExpr{Pos: pos, X: &UseIn{Pos: pos, Binds: binds, Body: p.parseBody()}}
		}
		return &SUse{Pos: pos, Binds: binds}

	case p.at(Under) && p.peek(1).Kind == Equals:
		p.next()
		p.next()
		return &SDiscard{Pos: pos, X: p.parseBody()}
	}
	return &SExpr{Pos: pos, X: p.parseExpr()}
}

// parseBind parses a let binding in its three forms:
//
//	let h = state 0            a value
//	let f x = e                a function
//	let (u, total) = e         a destructuring pattern
func (p *parser) parseBind() Bind {
	pos := p.here()
	if p.at(VarId) && (p.peek(1).Kind == Equals || p.startsAtomPatAt(1)) {
		b := Bind{Pos: pos, Name: p.next().Text}
		for p.inItem() && p.startsAtomPat() {
			b.Params = append(b.Params, p.parseAtomPat())
		}
		p.expect(Equals, "`=` in a let binding")
		b.Value = p.parseBody()
		return b
	}
	b := Bind{Pos: pos, Pat: p.parsePat()}
	p.expect(Equals, "`=` in a let binding")
	b.Value = p.parseBody()
	return b
}

// parseHandleHead parses `[<label> =] <handler>`. A capitalized label assigns
// that effect's DESIGNATION SLOT (P2); a lowercase one is a role label.
func (p *parser) parseHandleHead() (label string, slot bool, h Expr) {
	if (p.at(VarId) || p.at(ConId)) && p.peek(1).Kind == Equals {
		t := p.next()
		p.next()
		label, slot = t.Text, t.Kind == ConId
	}
	return label, slot, p.parseExpr()
}

// parseUseBinds parses `x as l, y as m`. Both sides are LABELS, never terms
// (spec 1.6): a term here is E-LABEL, reported by a later pass.
func (p *parser) parseUseBinds() []UseBind {
	var bs []UseBind
	for {
		pos := p.here()
		from := p.expectName("a label to re-bind")
		p.expectWord(KwAs)
		to := p.expectName("the new label")
		bs = append(bs, UseBind{Pos: pos, From: from.Text, To: to.Text, Slot: to.Kind == ConId})
		if !(p.inItem() && p.accept(Comma)) {
			return bs
		}
	}
}

// ---------------------------------------------------------------- expressions

// parseExpr is the loosest expression level: the leading-keyword forms, then
// an operator chain, then an optional `:=` baton update.
func (p *parser) parseExpr() Expr {
	pos := p.here()
	switch {
	case p.at(Lambda):
		p.next()
		e := &Lam{Pos: pos}
		for p.inItem() && p.startsAtomPat() {
			e.Params = append(e.Params, p.parseAtomPat())
		}
		p.expect(Arrow, "`->` after the lambda binders")
		e.Body = p.parseBody()
		return e

	case p.atWord(KwLet):
		p.next()
		b := p.parseBind()
		p.expectWord(KwIn)
		return &LetIn{Pos: pos, Bind: b, Body: p.parseBody()}

	case p.atWord(KwHandle):
		p.next()
		label, slot, h := p.parseHandleHead()
		p.expectWord(KwIn)
		return &HandleIn{Pos: pos, Label: label, Slot: slot, Handler: h, Body: p.parseBody()}

	case p.atWord(KwUse):
		p.next()
		binds := p.parseUseBinds()
		p.expectWord(KwIn)
		return &UseIn{Pos: pos, Binds: binds, Body: p.parseBody()}

	case p.atWord(KwIf):
		p.next()
		e := &If{Pos: pos, Cond: p.parseExpr()}
		p.expectWord(KwThen)
		e.Then = p.parseBody()
		p.expectWord(KwElse)
		e.Else = p.parseBody()
		return e

	case p.atWord(KwCase):
		return p.parseCase()

	case p.atWord(KwHandler):
		return p.parseHandlerLit()
	}

	e := p.parseChain()
	if p.at(ColonEq) && p.inItem() {
		opPos := p.here()
		p.next()
		v, ok := e.(*Var)
		if !ok {
			p.failAt(e.Position(), "`:=` updates a `var` baton, so its left side must be a plain name")
		}
		return &Assign{Pos: opPos, Target: v.Name, Value: p.parseBody()}
	}
	return e
}

// case e of
//
//	[]      -> ()
//	y :: ys -> ...
func (p *parser) parseCase() Expr {
	pos := p.here()
	p.expectWord(KwCase)
	e := &Case{Pos: pos, Scrut: p.parseExpr()}
	p.expectWord(KwOf)
	p.block("case alternative", nil, func() {
		aPos := p.here()
		a := Alt{Pos: aPos, Pat: p.parsePat()}
		p.expect(Arrow, "`->` after a case pattern")
		a.Body = p.parseBody()
		a.Where = p.parseWhere()
		e.Alts = append(e.Alts, a)
	})
	return e
}

// handler State
//
//	var cur = init
//	get      -> cur
//	set x    -> cur := x
//	return v -> (v, cur)
//	once yield x k -> x :: k ()
//
// The effect name is mandatory (spec C3): clauses resolve against its
// declaration.
func (p *parser) parseHandlerLit() Expr {
	pos := p.here()
	p.expectWord(KwHandler)
	h := &HandlerLit{Pos: pos, Effect: p.expect(ConId, "the effect this handler handles").Text}
	p.block("handler clause", nil, func() {
		h.Clauses = append(h.Clauses, p.parseClause())
	})
	return h
}

func (p *parser) parseClause() Clause {
	pos := p.here()
	switch {
	// var cur = init -- the per-activation copy point (C12)
	case p.atWord(KwVar):
		p.next()
		c := Clause{Pos: pos, Kind: ClauseVar, Name: p.expect(VarId, "a baton name").Text}
		p.expect(Equals, "`=` after a `var` baton name")
		c.Init = p.parseBody()
		return c

	// return p -> e -- the value clause
	case p.atWord(KwReturn):
		p.next()
		c := Clause{Pos: pos, Kind: ClauseReturn, Name: "return", Pats: []Pat{p.parsePat()}}
		p.expect(Arrow, "`->` after the return pattern")
		c.Body = p.parseBody()
		return c

	// once op p1 p2 k -> e -- a control clause; the LAST binder is the
	// continuation and is always a bare name, never a pattern (D14).
	case p.atWord(KwOnce):
		p.next()
		c := Clause{Pos: pos, Kind: ClauseOnce, Name: p.expect(VarId, "an operation name").Text}
		var pats []Pat
		for p.inItem() && p.startsAtomPat() {
			pats = append(pats, p.parseAtomPat())
		}
		if len(pats) == 0 {
			p.fail(p.tok(), "a `once` clause must bind the continuation as its last binder")
		}
		last, ok := pats[len(pats)-1].(*PVar)
		if !ok {
			p.fail(p.tok(), "the continuation binder of a `once` clause must be a plain name, not a pattern")
		}
		c.K, c.Pats = last.Name, pats[:len(pats)-1]
		p.expect(Arrow, "`->` after the clause binders")
		c.Body = p.parseBody()
		return c
	}

	// op p1 p2 -> e -- auto-resume (tail-resumptive)
	c := Clause{Pos: pos, Kind: ClausePlain, Name: p.expect(VarId, "an operation name").Text}
	for p.inItem() && p.startsAtomPat() {
		c.Pats = append(c.Pats, p.parseAtomPat())
	}
	p.expect(Arrow, "`->` after the clause binders")
	c.Body = p.parseBody()
	return c
}

// parseChain builds a FLAT operator chain. Precedence and associativity are
// deferred to a later reordering pass, so no fixity table lives here.
func (p *parser) parseChain() Expr {
	head := p.parseApp()
	var tail []InfixTerm
	for p.inItem() {
		pos := p.here()
		var term InfixTerm
		switch {
		case p.at(VarSym):
			term = InfixTerm{Pos: pos, Op: p.next().Text}
		case p.at(Cons):
			p.next()
			term = InfixTerm{Pos: pos, Op: "::"}
		case p.at(Backtick):
			p.next()
			term = InfixTerm{Pos: pos, Op: p.expect(VarId, "an operator name").Text, Backtick: true}
			p.expect(Backtick, "a closing backtick")
		default:
			if tail == nil {
				return head
			}
			return &Infix{Pos: head.Position(), Head: head, Tail: tail}
		}
		term.Rhs = p.parseApp()
		tail = append(tail, term)
	}
	if tail == nil {
		return head
	}
	return &Infix{Pos: head.Position(), Head: head, Tail: tail}
}

func (p *parser) parseApp() Expr {
	// Prefix negation, in operand position only: `f -5` is still subtraction,
	// exactly as in ML and Haskell.
	if p.atWord(OpMinus) {
		pos := p.here()
		p.next()
		return &Neg{Pos: pos, Operand: p.parseApp()}
	}
	fn := p.parseAtom()
	var args []Expr
	for p.inItem() && p.startsAtom() {
		args = append(args, p.parseAtom())
	}
	if args == nil {
		return fn
	}
	return &App{Pos: fn.Position(), Fn: fn, Args: args}
}

func (p *parser) startsAtom() bool {
	switch p.tok().Kind {
	case VarId, ConId, IntLit, StrLit, CharLit, LParen, LBrack:
		return true
	}
	return false
}

func (p *parser) parseAtom() Expr {
	t := p.tok()
	var e Expr
	switch {
	case p.at(VarId):
		p.next()
		e = &Var{Pos: at(t), Name: t.Text}

	case p.at(ConId):
		p.next()
		e = &Con{Pos: at(t), Name: t.Text}

	case p.at(IntLit), p.at(StrLit), p.at(CharLit):
		p.next()
		e = &Lit{Pos: at(t), Kind: t.Kind, Text: t.Text}

	case p.at(LBrack):
		p.openBracket(LBrack, "`[` of a list")
		list := &ListLit{Pos: at(t)}
		for !p.at(RBrack) {
			list.Items = append(list.Items, p.parseExpr())
			if !p.accept(Comma) {
				break
			}
		}
		p.closeBracket(RBrack, "`]` closing the list")
		e = list

	case p.at(LParen):
		e = p.parseParen()

	case p.at(Under):
		p.fail(t, "`_` is a pattern; to drop a value write `_ = <expr>`")

	default:
		p.fail(t, "expected an expression, found %s", describe(t))
	}
	return p.parsePostfix(e)
}

// parseParen covers `()`, `(+)`, `(e)` and `(e, e, ...)`.
func (p *parser) parseParen() Expr {
	t := p.tok()
	if p.peek(1).Kind == RParen {
		p.next()
		p.next()
		return &Unit{Pos: at(t)}
	}
	if p.peek(1).Kind == VarSym && p.peek(2).Kind == RParen {
		p.next()
		op := p.next().Text
		p.next()
		return &OpRef{Pos: at(t), Op: op}
	}
	p.openBracket(LParen, "`(`")
	first := p.parseExpr()
	if p.at(Comma) {
		tup := &Tuple{Pos: at(t), Items: []Expr{first}}
		for p.accept(Comma) {
			tup.Items = append(tup.Items, p.parseExpr())
		}
		p.closeBracket(RParen, "`)` closing a tuple")
		return tup
	}
	p.closeBracket(RParen, "`)`")
	return first
}

// parsePostfix applies the dotted forms and record construction. Every dot
// lands in one node kind; spec 1.5 resolves qualifier / label / projection
// later, and the collision between them is an error, not a precedence.
func (p *parser) parsePostfix(e Expr) Expr {
	for {
		switch {
		case p.at(Period) && p.inItem():
			p.next()
			n := p.tok()
			if n.Kind != VarId && n.Kind != ConId {
				p.fail(n, "expected a name after `.`, found %s", describe(n))
			}
			p.next()
			e = &Dot{Pos: at(n), Recv: e, Name: n.Text, Upper: n.Kind == ConId}

		case p.at(LBrace) && p.inItem() && isConLike(e):
			e = p.parseRecordLit(e)

		default:
			return e
		}
	}
}

// isConLike reports whether a record literal may follow: only a constructor,
// possibly qualified (`M.Point { ... }`).
func isConLike(e Expr) bool {
	switch x := e.(type) {
	case *Con:
		return true
	case *Dot:
		return x.Upper
	}
	return false
}

// parseRecordLit parses `Point { x = 1, y = 2 }` and the update form
// `Point { ..p }` / `Point { ..p, x = 99 }`.
func (p *parser) parseRecordLit(con Expr) Expr {
	r := &RecordLit{Pos: con.Position(), Con: con}
	p.openBracket(LBrace, "`{` of a record literal")
	if p.at(DotDot) {
		p.next()
		r.Spread = p.parseExpr()
		if !p.accept(Comma) {
			p.closeBracket(RBrace, "`}` closing the record literal")
			return r
		}
	}
	for !p.at(RBrace) {
		fPos := p.here()
		name := p.expect(VarId, "a field name").Text
		p.expect(Equals, "`=` after a field name")
		r.Fields = append(r.Fields, FieldExpr{Pos: fPos, Name: name, Value: p.parseExpr()})
		if !p.accept(Comma) {
			break
		}
	}
	p.closeBracket(RBrace, "`}` closing the record literal")
	return r
}
