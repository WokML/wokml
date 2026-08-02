package wok

import "fmt"

// Pos is a 1-based source position. Every node carries one, so a later pass
// can blame a binder by site (spec section 3: every diagnostic names the
// value, its class, and its binding site).
type Pos struct {
	Line int
	Col  int
}

func (p Pos) String() string { return fmt.Sprintf("%d:%d", p.Line, p.Col) }
func (p Pos) Position() Pos  { return p }

// File is one source file: a layout block of declarations.
type File struct {
	Name  string
	Decls []Decl
}

// The four node families. Pos supplies every marker method, so embedding Pos
// is what makes a struct a node; the compiler still keeps the families apart
// at each use site because each interface names a distinct marker.
type (
	Decl interface {
		Position() Pos
		declNode()
	}
	Expr interface {
		Position() Pos
		exprNode()
	}
	Pat interface {
		Position() Pos
		patNode()
	}
	Type interface {
		Position() Pos
		typeNode()
	}
	Stmt interface {
		Position() Pos
		stmtNode()
	}
)

// ---------------------------------------------------------------- declarations

// ModuleDecl: `module Main`
type ModuleDecl struct {
	Pos
	Path []string
}

// ImportDecl: `import Geometry (area, Point) as G`. Names == nil means the
// whole module; Alias == "" means no rename.
type ImportDecl struct {
	Pos
	Path  []string
	Names []string
	Alias string
}

// TypeDecl: `type Color = Red | Green | Blue` and `type Point = { x : U64 }`
// (surface.md section 3; `type` replaces v1's `data`).
type TypeDecl struct {
	Pos
	Name   string
	Params []TyParam
	Cons   []ConDef
}

// AliasDecl: `alias Weighted = [(U64, U64)]`
type AliasDecl struct {
	Pos
	Name   string
	Params []TyParam
	Type   Type
}

// EffectDecl: `effect State s` + a layout block of op signatures.
type EffectDecl struct {
	Pos
	Name   string
	Params []TyParam
	Ops    []OpSig
}

// ClassDecl: `class Eq a` + a block of signatures and default equations.
type ClassDecl struct {
	Pos
	Name    string
	Params  []TyParam
	Entries []Decl
}

// InstanceDecl: `instance Eq Color` + a block of equations.
type InstanceDecl struct {
	Pos
	Ctx  []Type
	Name string
	Args []Type
	Body []Decl
}

// ForeignDecl: `foreign module Libc "c"` + a block of member signatures whose
// types carry the transfer law (`own` / `lend` / `copy`).
type ForeignDecl struct {
	Pos
	Name    string
	Lib     string
	Members []ForeignMember
}

// SigDecl: `state : s -> Handler (State s) a (a, s)`, or a multi-name
// signature `f, (+), h : T`. Extern marks the prelude-only trust anchor.
type SigDecl struct {
	Pos
	Names  []string
	Type   Type
	Extern bool
}

// ExternTypeDecl: `extern type Suspension a b r (row e)`
type ExternTypeDecl struct {
	Pos
	Name   string
	Params []TyParam
}

// FunDecl is one equation: `sumList xs = ...`, `(==) a b = ...`,
// `x + y = ...`. Infix records that the head was written between its operands.
type FunDecl struct {
	Pos
	Name   string
	Params []Pat
	Infix  bool
	Body   Expr
	Where  []Decl
}

// TyParam is a type-constructor parameter: a plain variable, or `(row e)`.
type TyParam struct {
	Pos
	Name string
	Row  bool
}

// ConDef is one constructor of a `type` declaration. Name is "" for the
// name-elided record form (`type Point = { x : U64, y : U64 }`).
type ConDef struct {
	Pos
	Name   string
	Args   []Type
	Fields []FieldType
	Record bool
}

type FieldType struct {
	Pos
	Name string
	Type Type
}

type OpSig struct {
	Pos
	Name string
	Type Type
}

type ForeignMember struct {
	Pos
	Name   string
	Symbol string // "" = the C symbol is the member name
	Type   Type
}

// ------------------------------------------------------------------ statements

// A block is a SEQUENCE (spec D11). let/handle/use are statements scoping over
// the rest of the block; the final statement is the block's value.

// SLet: `let pat = expr` (no `in`).
type SLet struct {
	Pos
	Bind Bind
}

// SHandle: `handle l = h` — installs, binding label l over the rest of the
// block. Slot records that the label was capitalized, i.e. it assigns that
// effect's DESIGNATION SLOT (spec P2/D17) rather than a role label.
type SHandle struct {
	Pos
	Label   string
	Slot    bool
	Handler Expr
}

// SUse: `use x as l` — re-binds labels over the rest of the block.
type SUse struct {
	Pos
	Binds []UseBind
}

// SDiscard: `_ = expr`, the explicit discard the discard law demands
// (E-DISCARD otherwise).
type SDiscard struct {
	Pos
	X Expr
}

// SExpr is a bare expression line. Non-final ones must be unit-typed; the
// check belongs to a later pass.
type SExpr struct {
	Pos
	X Expr
}

// Bind is a let binding. Params != nil means a function binding (`let f x = e`)
// and Name holds its head; otherwise Pat holds the bound pattern, unless Name
// is set for the plain `let x = e` case.
type Bind struct {
	Pos
	Name   string
	Params []Pat
	Pat    Pat
	Value  Expr
}

// UseBind is one `x as l` pair.
type UseBind struct {
	Pos
	From string
	To   string
	Slot bool
}

// ----------------------------------------------------------------- expressions

type Var struct {
	Pos
	Name string
}

type Con struct {
	Pos
	Name string
}

// Lit holds an integer, string, or character literal; Kind says which.
type Lit struct {
	Pos
	Kind Kind
	Text string
}

// OpRef is a parenthesised operator used as a value: `(+)`.
type OpRef struct {
	Pos
	Op string
}

// Dot is the ONE dotted form. `M.f` (qualifier), `st.get` (row label) and
// `p.x` (record projection) all land here: spec 1.5 resolves them later, and
// the E-LABEL collision rule needs them undistinguished at parse time.
type Dot struct {
	Pos
	Recv  Expr
	Name  string
	Upper bool
}

type App struct {
	Pos
	Fn   Expr
	Args []Expr
}

// Infix is a FLAT operator chain. Precedence is deferred to a later
// reordering pass (as src/Wok/Reordering.hs already does today).
type Infix struct {
	Pos
	Head Expr
	Tail []InfixTerm
}

type InfixTerm struct {
	Pos
	Op       string
	Backtick bool // written `add` rather than symbolically
	Rhs      Expr
}

// Neg is prefix negation in operand position.
type Neg struct {
	Pos
	Operand Expr
}

type Lam struct {
	Pos
	Params []Pat
	Body   Expr
}

type If struct {
	Pos
	Cond Expr
	Then Expr
	Else Expr
}

type Case struct {
	Pos
	Scrut Expr
	Alts  []Alt
}

type Alt struct {
	Pos
	Pat   Pat
	Body  Expr
	Where []Decl
}

// HandlerLit is `handler E` + clauses: a first-class handler VALUE (spec C9,
// D3). The effect name is mandatory (C3).
type HandlerLit struct {
	Pos
	Effect  string
	Clauses []Clause
}

type ClauseKind uint8

const (
	ClausePlain  ClauseKind = iota // op p1 p2 -> e      (auto-resume)
	ClauseOnce                     // once op p1 k -> e  (control clause)
	ClauseReturn                   // return p -> e      (the value clause)
	ClauseVar                      // var cur = e        (a frame baton)
)

// Clause is one handler clause. For ClauseOnce, K is the continuation binder
// (always a bare name, never a pattern — D14) and Pats holds the op arguments
// only, so E-ARITY can compare len(Pats) against the op's arity directly.
type Clause struct {
	Pos
	Kind ClauseKind
	Name string
	Pats []Pat
	K    string
	Init Expr // ClauseVar only
	Body Expr
}

// Block is an indented sequence of statements (spec D11).
type Block struct {
	Pos
	Stmts []Stmt
}

// LetIn / HandleIn / UseIn are the DELIMITED inline twins of the statement
// forms. HandleIn.Label may be "" — the inline form may elide it, defaulting
// to the effect head (spec D13, two-tier).
type LetIn struct {
	Pos
	Bind Bind
	Body Expr
}

type HandleIn struct {
	Pos
	Label   string
	Slot    bool
	Handler Expr
	Body    Expr
}

type UseIn struct {
	Pos
	Binds []UseBind
	Body  Expr
}

// Assign is `cur := e`, a baton update (legal only inside the declaring
// handler's clause bodies; E-VARSCOPE otherwise).
type Assign struct {
	Pos
	Target string
	Value  Expr
}

type Tuple struct {
	Pos
	Items []Expr
}

type ListLit struct {
	Pos
	Items []Expr
}

type Unit struct {
	Pos
}

// RecordLit is `Point { x = 1 }` or the update form `Point { ..p, x = 9 }`.
type RecordLit struct {
	Pos
	Con    Expr
	Spread Expr
	Fields []FieldExpr
}

type FieldExpr struct {
	Pos
	Name  string
	Value Expr
}

// -------------------------------------------------------------------- patterns

type PVar struct {
	Pos
	Name string
}

type PWild struct {
	Pos
}

type PLit struct {
	Pos
	Kind Kind
	Text string
	Neg  bool
}

// PCon is a constructor pattern, possibly qualified (`List.Cons x xs`).
type PCon struct {
	Pos
	Name string
	Args []Pat
}

// PCons is the right-associative `x :: xs`.
type PCons struct {
	Pos
	Head Pat
	Tail Pat
}

type PTuple struct {
	Pos
	Items []Pat
}

type PList struct {
	Pos
	Items []Pat
}

type PUnit struct {
	Pos
}

// PAs is `pat as name`.
type PAs struct {
	Pos
	Pat  Pat
	Name string
}

// PRecord is `Point { x = a }`, `Point { x = a, .. }` or `Point { ..rest }`.
type PRecord struct {
	Pos
	Con    string
	Fields []FieldPat
	Open   bool
	Rest   string
}

type FieldPat struct {
	Pos
	Name string
	Pat  Pat
}

// ----------------------------------------------------------------------- types

type TVar struct {
	Pos
	Name string
}

type TCon struct {
	Pos
	Name string
}

type TApp struct {
	Pos
	Fn   Type
	Args []Type
}

type TFun struct {
	Pos
	From Type
	To   Type
}

type TList struct {
	Pos
	Elem Type
}

type TTuple struct {
	Pos
	Items []Type
}

type TUnit struct {
	Pos
}

// TRow is a row-kinded argument, written `(row e)`.
type TRow struct {
	Pos
	Name string
}

// TWith attaches a labeled capability row: `T -> R with (st : State U64)`.
type TWith struct {
	Pos
	Type Type
	Row  *Row
}

// TQual is a constraint context: `(Eq a) => T`.
type TQual struct {
	Pos
	Ctx  Type
	Body Type
}

// TTransfer is the FFI transfer law on a foreign signature: `own`, `lend`,
// `copy` (surface.md section 2). Only reachable inside a foreign member.
type TTransfer struct {
	Pos
	Mode string
	Type Type
}

// Row is a labeled capability row (spec 1.3): unordered, keyed by name.
type Row struct {
	Pos
	Entries []RowEntry
}

// RowEntry is one row obligation.
//
//	Label == "" && !Var : a DESIGNATION SLOT obligation, `State U64`
//	Label != ""         : a ROLE obligation, `(st : State U64)` (D20)
//	Var                 : a row variable, `eff e`
type RowEntry struct {
	Pos
	Label string
	Slot  bool // the written label was capitalized (E-LABEL: slots have no labeled spelling)
	Var   bool
	Name  string // the row variable's name, when Var
	Type  Type
}

// ------------------------------------------------------- node family markers
//
// One line per node. They are what keeps declarations, statements,
// expressions, patterns and types from being silently interchangeable.

func (*ModuleDecl) declNode()     {}
func (*ImportDecl) declNode()     {}
func (*TypeDecl) declNode()       {}
func (*AliasDecl) declNode()      {}
func (*EffectDecl) declNode()     {}
func (*ClassDecl) declNode()      {}
func (*InstanceDecl) declNode()   {}
func (*ForeignDecl) declNode()    {}
func (*SigDecl) declNode()        {}
func (*ExternTypeDecl) declNode() {}
func (*FunDecl) declNode()        {}

func (*SLet) stmtNode()     {}
func (*SHandle) stmtNode()  {}
func (*SUse) stmtNode()     {}
func (*SDiscard) stmtNode() {}
func (*SExpr) stmtNode()    {}

func (*Var) exprNode()        {}
func (*Con) exprNode()        {}
func (*Lit) exprNode()        {}
func (*OpRef) exprNode()      {}
func (*Dot) exprNode()        {}
func (*App) exprNode()        {}
func (*Infix) exprNode()      {}
func (*Neg) exprNode()        {}
func (*Lam) exprNode()        {}
func (*If) exprNode()         {}
func (*Case) exprNode()       {}
func (*HandlerLit) exprNode() {}
func (*Block) exprNode()      {}
func (*LetIn) exprNode()      {}
func (*HandleIn) exprNode()   {}
func (*UseIn) exprNode()      {}
func (*Assign) exprNode()     {}
func (*Tuple) exprNode()      {}
func (*ListLit) exprNode()    {}
func (*Unit) exprNode()       {}
func (*RecordLit) exprNode()  {}

func (*PVar) patNode()    {}
func (*PWild) patNode()   {}
func (*PLit) patNode()    {}
func (*PCon) patNode()    {}
func (*PCons) patNode()   {}
func (*PTuple) patNode()  {}
func (*PList) patNode()   {}
func (*PUnit) patNode()   {}
func (*PAs) patNode()     {}
func (*PRecord) patNode() {}

func (*TVar) typeNode()      {}
func (*TCon) typeNode()      {}
func (*TApp) typeNode()      {}
func (*TFun) typeNode()      {}
func (*TList) typeNode()     {}
func (*TTuple) typeNode()    {}
func (*TUnit) typeNode()     {}
func (*TRow) typeNode()      {}
func (*TWith) typeNode()     {}
func (*TQual) typeNode()     {}
func (*TTransfer) typeNode() {}
