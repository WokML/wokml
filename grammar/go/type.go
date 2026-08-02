package wok

// Types and capability rows (spec 1.3, D20).
//
// Precedence, loosest first:
//
//	Type      (C a) => T        constraint context
//	          T -> R with Row   a labeled capability row, binding looser than ->
//	Arrow     A -> B            right-associative
//	TypeApp   Maybe a b         left-associative juxtaposition
//	TypeAtom  a, Con, [T], (T, T), (), (row e)

func (p *parser) parseType() Type {
	pos := p.here()
	t := p.parseArrow()
	if p.at(FatArrow) && p.inItem() {
		p.next()
		return &TQual{Pos: pos, Ctx: t, Body: p.parseType()}
	}
	if p.atWord(KwWith) && p.inItem() {
		withPos := p.here()
		p.next()
		return &TWith{Pos: withPos, Type: t, Row: p.parseRow()}
	}
	return t
}

func (p *parser) parseArrow() Type {
	lhs := p.parseTypeApp()
	if p.at(Arrow) && p.inItem() {
		pos := p.here()
		p.next()
		return &TFun{Pos: pos, From: lhs, To: p.parseArrow()}
	}
	return lhs
}

func (p *parser) parseTypeApp() Type {
	// Transfer modes are CONTEXTUAL: `own` / `lend` / `copy` are keywords only
	// inside a foreign member signature, so `Bytes.copy` stays a plain name.
	if p.foreign && (p.atWord(CwOwn) || p.atWord(CwLend) || p.atWord(CwCopy)) && p.startsTypeAtomAt(1) {
		t := p.next()
		return &TTransfer{Pos: at(t), Mode: t.Text, Type: p.parseTypeAtom()}
	}
	head := p.parseTypeAtom()
	var args []Type
	for p.inItem() && p.startsTypeAtom() {
		args = append(args, p.parseTypeAtom())
	}
	if args == nil {
		return head
	}
	return &TApp{Pos: head.Position(), Fn: head, Args: args}
}

func (p *parser) startsTypeAtom() bool { return p.startsTypeAtomAt(0) }

func (p *parser) startsTypeAtomAt(n int) bool {
	switch p.peek(n).Kind {
	case VarId, ConId, LBrack, LParen:
		return true
	}
	return false
}

func (p *parser) parseTypeAtom() Type {
	t := p.tok()
	switch {
	case p.at(VarId):
		p.next()
		return &TVar{Pos: at(t), Name: t.Text}

	case p.at(ConId):
		name := p.next().Text
		for p.at(Period) && p.peek(1).Kind == ConId {
			p.next()
			name += "." + p.next().Text
		}
		return &TCon{Pos: at(t), Name: name}

	case p.at(LBrack):
		p.openBracket(LBrack, "`[` of a list type")
		elem := p.parseType()
		p.closeBracket(RBrack, "`]` closing the list type")
		return &TList{Pos: at(t), Elem: elem}

	case p.at(LParen):
		// `()`, `(row e)`, `(T)` or `(T, U, ...)`
		if p.peek(1).Kind == RParen {
			p.next()
			p.next()
			return &TUnit{Pos: at(t)}
		}
		if p.peek(1).Word == CwRow && p.peek(2).Kind == VarId {
			p.next()
			p.next()
			name := p.next().Text
			p.expect(RParen, "`)` after a row argument")
			return &TRow{Pos: at(t), Name: name}
		}
		p.openBracket(LParen, "`(`")
		first := p.parseType()
		if p.at(Comma) {
			items := []Type{first}
			for p.accept(Comma) {
				items = append(items, p.parseType())
			}
			p.closeBracket(RParen, "`)` closing a tuple type")
			return &TTuple{Pos: at(t), Items: items}
		}
		p.closeBracket(RParen, "`)`")
		return first
	}
	p.fail(t, "expected a type, found %s", describe(t))
	return nil
}

// parseRow parses the right operand of `with`: entries joined by `+`.
//
//	with State U64 + Except String            slot obligations
//	with (from : State U64) + (to : State U64) role obligations (D20)
//	with eff e                                 a row variable
//
// `+` is matched as an ordinary operator, not a reserved symbol, so `+` stays
// available as a term-level operator (the same choice grammar/Wok.cf makes).
func (p *parser) parseRow() *Row {
	row := &Row{Pos: p.here()}
	for {
		row.Entries = append(row.Entries, p.parseRowEntry())
		if p.inItem() && p.atWord(OpPlus) {
			p.next()
			continue
		}
		return row
	}
}

func (p *parser) parseRowEntry() RowEntry {
	pos := p.here()

	// A labeled entry is parenthesised, mandatorily (D20). The label must be
	// lowercase; a capital is E-LABEL, recorded here and reported later.
	if p.at(LParen) && (p.peek(1).Kind == VarId || p.peek(1).Kind == ConId) && p.peek(2).Kind == Colon {
		p.openBracket(LParen, "`(` of a labeled row entry")
		label := p.next()
		p.next() // `:`
		e := RowEntry{Pos: pos, Label: label.Text, Slot: label.Kind == ConId, Type: p.parseType()}
		p.closeBracket(RParen, "`)` closing the labeled row entry")
		return e
	}

	// A row variable: `eff e` (contextual keyword).
	if p.atWord(CwEff) && p.peek(1).Kind == VarId {
		p.next()
		return RowEntry{Pos: pos, Var: true, Name: p.next().Text}
	}

	// A bare entry is an obligation on that effect's DESIGNATION SLOT (P2).
	return RowEntry{Pos: pos, Type: p.parseTypeApp()}
}
