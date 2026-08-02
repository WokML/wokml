package wok

import (
	"fmt"
	"strconv"
	"strings"
)

// Dump renders a parsed file as an indented s-expression. This is the
// eyeball artifact: the shape of the dump should read back as the surface
// form it came from.
//
// It is also the canonical IDENTITY of a program. `Read` turns a dump back
// into the same tree and `Format` prints that tree as canonical source, so
// the dump has to be FAITHFUL: every field the parser fills must be
// recoverable from it, and no two different trees may dump alike. Two rules
// keep that true, and both cost a pair of parentheses:
//
//   - a nullary form is a LIST, never a bare word -- `(unit)`, not `unit`,
//     which a variable of that name would be indistinguishable from;
//   - a heterogeneous sequence is TAGGED -- `(params ...)`, `(args ...)` --
//     rather than left for the reader to tell apart by shape.
//
// Positions are deliberately absent: they are re-derived by printing, so two
// files that differ only in layout have the same dump. That is what makes the
// dump the thing to compare trees BY (see roundtrip_test.go).
func Dump(f *File) string {
	var b strings.Builder
	for _, d := range f.Decls {
		declSx(d).writeTo(&b, 0)
		b.WriteString("\n")
	}
	return b.String()
}

// ------------------------------------------------------------ s-expressions

const dumpWidth = 78

type sx struct {
	text   string
	kids   []sx
	isList bool // parenthesise even when empty, so `(args)` never reads as an atom
}

func atom(format string, args ...any) sx { return sx{text: fmt.Sprintf(format, args...)} }

func list(head string, kids ...sx) sx { return sx{text: head, kids: kids, isList: true} }

func (s sx) oneLine() string {
	if !s.isList {
		return s.text
	}
	parts := make([]string, 0, len(s.kids)+1)
	if s.text != "" {
		parts = append(parts, s.text)
	}
	for _, k := range s.kids {
		parts = append(parts, k.oneLine())
	}
	return "(" + strings.Join(parts, " ") + ")"
}

func (s sx) writeTo(b *strings.Builder, indent int) {
	one := s.oneLine()
	if len(s.kids) == 0 || indent+len(one) <= dumpWidth {
		b.WriteString(one)
		return
	}
	b.WriteString("(" + s.text)
	pad := strings.Repeat(" ", indent+2)
	for _, k := range s.kids {
		b.WriteString("\n" + pad)
		k.writeTo(b, indent+2)
	}
	b.WriteString(")")
}

func seq[T any](items []T, f func(T) sx) []sx {
	out := make([]sx, 0, len(items))
	for _, it := range items {
		out = append(out, f(it))
	}
	return out
}

func group(head string, kids []sx) sx { return sx{text: head, kids: kids, isList: true} }

// ------------------------------------------------------------- declarations

func declSx(d Decl) sx {
	switch x := d.(type) {
	case *ModuleDecl:
		return list("module", atom("%s", strings.Join(x.Path, ".")))

	case *ImportDecl:
		s := list("import", atom("%s", strings.Join(x.Path, ".")))
		if x.Names != nil {
			s.kids = append(s.kids, group("names", seq(x.Names, func(n string) sx { return atom("%s", n) })))
		}
		if x.Alias != "" {
			s.kids = append(s.kids, list("as", atom("%s", x.Alias)))
		}
		return s

	case *TypeDecl:
		s := list("type", atom("%s", x.Name), tyParamsSx(x.Params))
		s.kids = append(s.kids, seq(x.Cons, conDefSx)...)
		return s

	case *AliasDecl:
		return list("alias", atom("%s", x.Name), tyParamsSx(x.Params), typeSx(x.Type))

	case *EffectDecl:
		s := list("effect", atom("%s", x.Name), tyParamsSx(x.Params))
		s.kids = append(s.kids, seq(x.Ops, func(o OpSig) sx {
			return list("op", atom("%s", o.Name), typeSx(o.Type))
		})...)
		return s

	case *ClassDecl:
		s := list("class", atom("%s", x.Name), tyParamsSx(x.Params))
		s.kids = append(s.kids, seq(x.Entries, declSx)...)
		return s

	case *InstanceDecl:
		s := list("instance")
		if len(x.Ctx) > 0 {
			s.kids = append(s.kids, group("ctx", seq(x.Ctx, typeSx)))
		}
		s.kids = append(s.kids, atom("%s", x.Name), group("args", seq(x.Args, typeSx)))
		s.kids = append(s.kids, seq(x.Body, declSx)...)
		return s

	case *ForeignDecl:
		s := list("foreign", atom("%s", x.Name), atom("%q", x.Lib))
		s.kids = append(s.kids, seq(x.Members, func(m ForeignMember) sx {
			e := list("member", atom("%s", m.Name))
			if m.Symbol != "" {
				e.kids = append(e.kids, atom("%q", m.Symbol))
			}
			e.kids = append(e.kids, typeSx(m.Type))
			return e
		})...)
		return s

	case *SigDecl:
		head := "sig"
		if x.Extern {
			head = "extern-sig"
		}
		s := list(head, group("names", seq(x.Names, func(n string) sx { return atom("%s", n) })))
		s.kids = append(s.kids, typeSx(x.Type))
		return s

	case *ExternTypeDecl:
		return list("extern-type", atom("%s", x.Name), tyParamsSx(x.Params))

	case *FunDecl:
		head := "def"
		if x.Infix {
			head = "def-infix"
		}
		s := list(head, atom("%s", x.Name))
		s.kids = append(s.kids, group("params", seq(x.Params, patSx)))
		s.kids = append(s.kids, exprSx(x.Body))
		if len(x.Where) > 0 {
			s.kids = append(s.kids, group("where", seq(x.Where, declSx)))
		}
		return s
	}
	return atom("<unknown decl %T>", d)
}

func tyParamsSx(ps []TyParam) sx {
	return group("params", seq(ps, func(t TyParam) sx {
		if t.Row {
			return list("row", atom("%s", t.Name))
		}
		return atom("%s", t.Name)
	}))
}

func conDefSx(c ConDef) sx {
	name := c.Name
	if name == "" {
		name = "_"
	}
	if c.Record {
		return list("con-record", atom("%s", name), group("fields", seq(c.Fields, func(f FieldType) sx {
			return list("field", atom("%s", f.Name), typeSx(f.Type))
		})))
	}
	s := list("con", atom("%s", name))
	s.kids = append(s.kids, seq(c.Args, typeSx)...)
	return s
}

// --------------------------------------------------------------------- types

func typeSx(t Type) sx {
	switch x := t.(type) {
	case *TVar:
		return atom("%s", x.Name)
	case *TCon:
		return atom("%s", x.Name)
	case *TApp:
		s := list("app", typeSx(x.Fn))
		s.kids = append(s.kids, seq(x.Args, typeSx)...)
		return s
	case *TFun:
		return list("->", typeSx(x.From), typeSx(x.To))
	case *TList:
		return list("list", typeSx(x.Elem))
	case *TTuple:
		return group("tuple", seq(x.Items, typeSx))
	case *TUnit:
		return list("unit")
	case *TRow:
		return list("row-arg", atom("%s", x.Name))
	case *TWith:
		return list("with", typeSx(x.Type), rowSx(x.Row))
	case *TQual:
		return list("=>", typeSx(x.Ctx), typeSx(x.Body))
	case *TTransfer:
		return list(x.Mode, typeSx(x.Type))
	}
	return atom("<unknown type %T>", t)
}

func rowSx(r *Row) sx {
	return group("row", seq(r.Entries, func(e RowEntry) sx {
		switch {
		case e.Var:
			return list("eff", atom("%s", e.Name))
		case e.Label != "":
			head := "role"
			if e.Slot {
				head = "role-CAPITAL" // E-LABEL: slots have no labeled spelling
			}
			return list(head, atom("%s", e.Label), typeSx(e.Type))
		default:
			return list("slot", typeSx(e.Type))
		}
	}))
}

// ------------------------------------------------------------------ patterns

func patSx(p Pat) sx {
	switch x := p.(type) {
	case *PVar:
		return atom("%s", x.Name)
	case *PWild:
		return atom("_")
	case *PLit:
		return litSx(x.Kind, x.Text, x.Neg)
	case *PCon:
		s := list("pcon", atom("%s", x.Name))
		s.kids = append(s.kids, seq(x.Args, patSx)...)
		return s
	case *PCons:
		return list("::", patSx(x.Head), patSx(x.Tail))
	case *PTuple:
		return group("tuple", seq(x.Items, patSx))
	case *PList:
		return group("list", seq(x.Items, patSx))
	case *PUnit:
		return list("unit")
	case *PAs:
		return list("as", patSx(x.Pat), atom("%s", x.Name))
	case *PRecord:
		s := list("precord", atom("%s", x.Con))
		s.kids = append(s.kids, seq(x.Fields, func(f FieldPat) sx {
			return list("field", atom("%s", f.Name), patSx(f.Pat))
		})...)
		if x.Open {
			if x.Rest != "" {
				s.kids = append(s.kids, atom("..%s", x.Rest))
			} else {
				s.kids = append(s.kids, atom(".."))
			}
		}
		return s
	}
	return atom("<unknown pattern %T>", p)
}

func litSx(k Kind, text string, neg bool) sx {
	switch k {
	case StrLit:
		return atom("%q", text)
	case CharLit:
		return atom("%s", strconv.QuoteRune([]rune(text + "\x00")[0]))
	default:
		if neg {
			return atom("-%s", text)
		}
		return atom("%s", text)
	}
}

// --------------------------------------------------------------- expressions

func exprSx(e Expr) sx {
	switch x := e.(type) {
	case *Var:
		return atom("%s", x.Name)
	case *Con:
		return atom("%s", x.Name)
	case *Lit:
		return litSx(x.Kind, x.Text, false)
	case *OpRef:
		return list("op", atom("%s", x.Op))
	case *Dot:
		return list("dot", exprSx(x.Recv), atom("%s", x.Name))
	case *App:
		s := list("app", exprSx(x.Fn))
		s.kids = append(s.kids, seq(x.Args, exprSx)...)
		return s
	case *Infix:
		s := list("infix", exprSx(x.Head))
		s.kids = append(s.kids, seq(x.Tail, func(t InfixTerm) sx {
			return list(t.Op, exprSx(t.Rhs))
		})...)
		return s
	case *Neg:
		return list("neg", exprSx(x.Operand))
	case *Lam:
		return list("lam", group("params", seq(x.Params, patSx)), exprSx(x.Body))
	case *If:
		return list("if", exprSx(x.Cond), exprSx(x.Then), exprSx(x.Else))
	case *Case:
		s := list("case", exprSx(x.Scrut))
		s.kids = append(s.kids, seq(x.Alts, func(a Alt) sx {
			alt := list("alt", patSx(a.Pat), exprSx(a.Body))
			if len(a.Where) > 0 {
				alt.kids = append(alt.kids, group("where", seq(a.Where, declSx)))
			}
			return alt
		})...)
		return s
	case *HandlerLit:
		s := list("handler", atom("%s", x.Effect))
		s.kids = append(s.kids, seq(x.Clauses, clauseSx)...)
		return s
	case *Block:
		return group("block", seq(x.Stmts, stmtSx))
	case *LetIn:
		return list("let-in", bindSx(x.Bind), exprSx(x.Body))
	case *HandleIn:
		return list("handle-in", labelSx(x.Label, x.Slot), exprSx(x.Handler), exprSx(x.Body))
	case *UseIn:
		return list("use-in", group("binds", seq(x.Binds, useBindSx)), exprSx(x.Body))
	case *Assign:
		return list(":=", atom("%s", x.Target), exprSx(x.Value))
	case *Tuple:
		return group("tuple", seq(x.Items, exprSx))
	case *ListLit:
		return group("list", seq(x.Items, exprSx))
	case *Unit:
		return list("unit")
	case *RecordLit:
		s := list("record", exprSx(x.Con))
		if x.Spread != nil {
			s.kids = append(s.kids, list("..", exprSx(x.Spread)))
		}
		s.kids = append(s.kids, seq(x.Fields, func(f FieldExpr) sx {
			return list("field", atom("%s", f.Name), exprSx(f.Value))
		})...)
		return s
	}
	return atom("<unknown expr %T>", e)
}

func clauseSx(c Clause) sx {
	switch c.Kind {
	case ClauseVar:
		return list("var", atom("%s", c.Name), exprSx(c.Init))
	case ClauseReturn:
		return list("return", patSx(c.Pats[0]), exprSx(c.Body))
	case ClauseOnce:
		return list("once", atom("%s", c.Name), group("args", seq(c.Pats, patSx)),
			list("k", atom("%s", c.K)), exprSx(c.Body))
	default:
		return list("clause", atom("%s", c.Name), group("args", seq(c.Pats, patSx)), exprSx(c.Body))
	}
}

func stmtSx(s Stmt) sx {
	switch x := s.(type) {
	case *SLet:
		return list("let", bindSx(x.Bind))
	case *SHandle:
		return list("handle", labelSx(x.Label, x.Slot), exprSx(x.Handler))
	case *SUse:
		return group("use", seq(x.Binds, useBindSx))
	case *SDiscard:
		return list("discard", exprSx(x.X))
	case *SExpr:
		return exprSx(x.X)
	}
	return atom("<unknown statement %T>", s)
}

func bindSx(b Bind) sx {
	if b.Pat != nil {
		return list("bind", patSx(b.Pat), exprSx(b.Value))
	}
	if len(b.Params) > 0 {
		return list("bind-fn", atom("%s", b.Name), group("params", seq(b.Params, patSx)), exprSx(b.Value))
	}
	return list("bind", atom("%s", b.Name), exprSx(b.Value))
}

// labelSx marks which binding regime a label belongs to (spec P2): a
// capitalized name assigns that effect's DESIGNATION SLOT, a lowercase one is
// a free ROLE label, and "" is the elided inline label (D13).
func labelSx(label string, slot bool) sx {
	switch {
	case label == "":
		return list("elided")
	case slot:
		return list("slot", atom("%s", label))
	default:
		return list("role", atom("%s", label))
	}
}

func useBindSx(u UseBind) sx {
	return list("as", atom("%s", u.From), labelSx(u.To, u.Slot))
}
