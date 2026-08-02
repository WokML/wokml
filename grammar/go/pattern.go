package wok

// Patterns.
//
//	Pat      x :: xs            right-associative cons
//	PatApp   Just x, Ping n     a constructor applied to atoms
//	AtomPat  x, _, 3, (p), [p], Point { x = a }, p as name
//
// Constructor and cons patterns must be parenthesised where an ATOM is
// required (lambda binders, equation parameters, handler clause arguments) --
// `\Just x -> ...` would otherwise read as two binders.

func (p *parser) parsePat() Pat {
	lhs := p.parsePatApp()
	if p.at(Cons) && p.inItem() {
		pos := p.here()
		p.next()
		return &PCons{Pos: pos, Head: lhs, Tail: p.parsePat()}
	}
	return lhs
}

func (p *parser) parsePatApp() Pat {
	if !p.at(ConId) {
		return p.parseAtomPat()
	}
	head := p.parseAtomPat()
	con, ok := head.(*PCon)
	if !ok { // a record pattern: `Point { x = a }` takes no further arguments
		return head
	}
	for p.inItem() && p.startsAtomPat() {
		con.Args = append(con.Args, p.parseAtomPat())
	}
	return con
}

func (p *parser) startsAtomPat() bool { return p.startsAtomPatAt(0) }

func (p *parser) startsAtomPatAt(n int) bool {
	switch p.peek(n).Kind {
	case VarId, ConId, Under, IntLit, StrLit, CharLit, LParen, LBrack:
		return true
	case VarSym: // a negative literal, `-1`
		return p.peek(n).Word == OpMinus && p.peek(n+1).Kind == IntLit
	}
	return false
}

func (p *parser) parseAtomPat() Pat {
	pat := p.parseAtomPatHead()
	for p.atWord(KwAs) && p.inItem() {
		pos := p.here()
		p.next()
		pat = &PAs{Pos: pos, Pat: pat, Name: p.expect(VarId, "a name after `as`").Text}
	}
	return pat
}

func (p *parser) parseAtomPatHead() Pat {
	t := p.tok()
	switch {
	case p.at(VarId):
		p.next()
		return &PVar{Pos: at(t), Name: t.Text}

	case p.at(Under):
		p.next()
		return &PWild{Pos: at(t)}

	case p.at(IntLit), p.at(StrLit), p.at(CharLit):
		p.next()
		return &PLit{Pos: at(t), Kind: t.Kind, Text: t.Text}

	case p.atWord(OpMinus) && p.peek(1).Kind == IntLit:
		p.next()
		lit := p.next()
		return &PLit{Pos: at(t), Kind: lit.Kind, Text: lit.Text, Neg: true}

	case p.at(ConId):
		name := p.next().Text
		for p.at(Period) && p.peek(1).Kind == ConId {
			p.next()
			name += "." + p.next().Text
		}
		if p.at(LBrace) && p.inItem() {
			return p.parseRecordPat(at(t), name)
		}
		return &PCon{Pos: at(t), Name: name}

	case p.at(LBrack):
		p.openBracket(LBrack, "`[` of a list pattern")
		var items []Pat
		for !p.at(RBrack) {
			items = append(items, p.parsePat())
			if !p.accept(Comma) {
				break
			}
		}
		p.closeBracket(RBrack, "`]` closing the list pattern")
		return &PList{Pos: at(t), Items: items}

	case p.at(LParen):
		if p.peek(1).Kind == RParen {
			p.next()
			p.next()
			return &PUnit{Pos: at(t)}
		}
		p.openBracket(LParen, "`(`")
		first := p.parsePat()
		if p.at(Comma) {
			items := []Pat{first}
			for p.accept(Comma) {
				items = append(items, p.parsePat())
			}
			p.closeBracket(RParen, "`)` closing a tuple pattern")
			return &PTuple{Pos: at(t), Items: items}
		}
		p.closeBracket(RParen, "`)`")
		return first
	}
	p.fail(t, "expected a pattern, found %s", describe(t))
	return nil
}

// parseRecordPat parses `Point {}`, `Point { x = a }`, `Point { x = a, .. }`
// and `Point { ..rest }`.
func (p *parser) parseRecordPat(pos Pos, con string) Pat {
	r := &PRecord{Pos: pos, Con: con}
	p.openBracket(LBrace, "`{` of a record pattern")
	for !p.at(RBrace) {
		if p.at(DotDot) {
			p.next()
			r.Open = true
			if p.at(VarId) {
				r.Rest = p.next().Text
			}
			break
		}
		fPos := p.here()
		name := p.expect(VarId, "a field name").Text
		p.expect(Equals, "`=` after a field name")
		r.Fields = append(r.Fields, FieldPat{Pos: fPos, Name: name, Pat: p.parsePat()})
		if !p.accept(Comma) {
			break
		}
	}
	p.closeBracket(RBrace, "`}` closing the record pattern")
	return r
}
