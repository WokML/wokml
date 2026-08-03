// wok_ast -- THE SCHEMA. Every node's fields are written exactly once, here.
//
// From this one list the build derives: the tag enum, the per-node slot
// indices, typed accessors and setters, and a descriptor table that the dump,
// the reader and the coverage bitmap all walk generically. Adding a node means
// adding one line; forgetting to teach the dump about it is impossible,
// because the dump does not know about nodes individually.
//
// Each line says TWO things: the family the node belongs to, and -- per field --
// the family that field demands. The second used to live only in wok_parse.c,
// which meant the reader could not tell an expression from a type and a
// corrupted dump read back as a different program. Now it can. A node added
// here without a family does not compile; a family that disagrees with what the
// parser builds fails in test_generative at startup, by name.
//
// Nodes are UNIFORM: a header plus a flexible array of slots. That trades a
// little static typing for a schema a machine can walk, and two things buy
// some of it back: an accessor's C type comes from the field's CLASS, so a
// NODE slot cannot be read as a span; and every accessor asserts the node's
// TAG in a debug build, so E_App_fn(someTypeNode) fires rather than returning
// a misread word. Neither checks the FAMILY -- that is the reader's job, in
// wok_sexpr.c, on the way in.

#pragma once

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "wok_arena.h"
#include "wok_base.h"

typedef struct WokNode WokNode;

typedef struct {
  u32 off, len;
} WokSpan;

typedef struct {
  WokNode **items;
  u32 n;
} WokSeq;

// A sequence slot stores ONLY the items pointer; its length lives inline, in
// the word immediately before items. Without that, WokSeq's {ptr, uint32}
// would drag the whole union to 16 bytes and every NODE, INT, NAME and FLAG
// slot would pay 8 bytes of padding it never uses -- and 77% of nodes have
// just one or two slots.
typedef union {
  WokNode *node;
  WokNode **seq;
  WokSpan span;
  u64 num;
  bool flag;
} WokSlot;

static_assert(sizeof(WokSlot) == 8, "a slot is one word; see the note above");

static inline WokSeq wok_seq_empty(void) {
  return (WokSeq){.items = nullptr, .n = 0};
}

// Rebuilds the fat {items, n} view from a stored pointer. The count sits at
// items[-1]; an empty sequence is a null pointer.
static inline WokSeq wok_seq_unpack(WokNode **items) {
  if (items == nullptr) return wok_seq_empty();
  return (WokSeq){.items = items, .n = (u32)(uptr)items[-1]};
}

struct WokNode {
  u32 off, len;  // source span, for diagnostics only
  // WHICH node this is: a WokTag, and the index every generic walk takes into
  // wok_node_desc[] to find the field list it then walks -- the dump, the
  // reader, the coverage bitmap, the printer's overflow report. It is the one
  // field that turns a uniform header-plus-slots block back into a typed node.
  //
  // Spelled u16 rather than WokTag only because the enum is DERIVED from
  // WOK_NODES further down this file, so the name does not exist yet here. The
  // enum is already `: u16`, so nothing is narrowed by saying so.
  u16 tag;
  // The arity its tag declares, copied here by wok_node so a walk never has to
  // reach for the schema just to bound a loop.
  u16 nslots;
  // The four bytes of padding the slot array's 8-byte alignment already
  // forced. 0 means no comments; otherwise this indexes a WokTrivia table
  // (wok_trivia.h). It is NOT a slot: comments are not part of a program's
  // identity, so nothing derived from the schema -- dump, reader, coverage --
  // can see this field.
  u32 trivia;
  WokSlot slot[];
};

// The trivia index must stay free. If either of these fires the header grew,
// and every node in every parse just paid for it.
static_assert(sizeof(WokNode) == 16, "the node header is 16 bytes");
static_assert(offsetof(WokNode, slot) == 16, "slots follow the header");

// Field classes. NODE is required, OPT may be null, SEQ is a slice into the
// arena, NAME and TEXT are views into the source, INT is a decoded literal or
// a schema constant, FLAG is a decided bit.
#define WOK_FIELD_CLASSES(X) \
  X(NODE) X(OPT) X(SEQ) X(NAME) X(TEXT) X(INT) X(FLAG)

typedef enum : unsigned char {
#define WOK_X(c) WFC_##c,
  WOK_FIELD_CLASSES(WOK_X)
#undef WOK_X
      WOK_FIELD_CLASS_COUNT
} WokFieldClass;

// Field FAMILIES. The class says a field holds a child; the family says WHICH
// KIND of child, and that is the half the schema used to leave to wok_parse.c.
// Every node declares the family it BELONGS to, every NODE/OPT/SEQ field the
// family it DEMANDS, and the s-expression reader compares the two -- so a dump
// with a type where an expression belongs is rejected rather than silently
// read back as a different program.
//
// NONE is for NAME, TEXT, INT and FLAG fields, which hold no child at all.
// ERROR is the damage marker, and it is a WILDCARD: mk_err plants an error
// node wherever a production gave up -- in a type, a pattern, an alternative,
// a clause -- so a family that refused it would make a damaged parse's dump
// unreadable, which is exactly when reading one back is worth something.
#define WOK_FAMILIES(X)                                                     \
  X(NONE) X(ERROR)                                                          \
  /* the big four, plus the file and the block item */                      \
  X(FILE) X(DECL) X(TYPE) X(PAT) X(EXPR) X(STMT)                            \
  /* names, and a dotted path of them */                                    \
  X(NAME) X(PATH)                                                           \
  /* every helper is its own family: each is demanded by ONE kind of slot */ \
  X(LHS) X(BINDLHS) X(SIGNAME) X(TYPARAM) X(CONDEF) X(FIELDTYPE) X(OPSIG)   \
  X(FOREIGNMEM) X(ROWENTRY) X(FIELDPAT) X(CHAINOP) X(BIND) X(USEBIND)       \
  X(ALT) X(CLAUSE) X(FIELD)

typedef enum : unsigned char {
#define WOK_X(f) WFAM_##f,
  WOK_FAMILIES(WOK_X)
#undef WOK_X
      WOK_FAMILY_COUNT
} WokFamily;

// The three places a family is WIDER than one node kind. Each is a fact about
// the grammar, not a loosening: parse_stmt's last arm is a bare expression, and
// parse_bind takes either a prefix head or a pattern. Nothing else subsumes.
WOK_PURE static inline bool wok_family_accepts(WokFamily want, WokFamily got) {
  if (want == got) return true;
  if (got == WFAM_ERROR) return true;  // damage stands anywhere; see above
  if (want == WFAM_STMT && got == WFAM_EXPR) return true;
  if (want == WFAM_BINDLHS && (got == WFAM_LHS || got == WFAM_PAT)) return true;
  return false;
}

// --------------------------------------------------------------- constants

// H_Clause kinds (spec 1.1: clause kinds are keyword-distinguished).
enum {
  WOK_CLAUSE_PLAIN = 0,   // op p1 p2 -> e      auto-resume, tail-resumptive
  WOK_CLAUSE_ONCE = 1,    // once op p1 k -> e  control clause; last binder is k
  WOK_CLAUSE_RETURN = 2,  // return p -> e      the value clause
  WOK_CLAUSE_VAR = 3,     // var cur = e        a frame baton
};

// H_RowEntry kinds (spec 1.3 / D20).
enum {
  WOK_ROW_SLOT = 0,    // `State U64`          designation-slot obligation (P2)
  WOK_ROW_ROLE = 1,    // `(from : State U64)` role obligation, parenthesized
  WOK_ROW_VAR = 2,     // `eff e`              row variable
};

// T_Transfer modes (surface.md section 3: the FFI transfer law).
enum {
  WOK_TRANSFER_OWN = 0,   // consumed by C
  WOK_TRANSFER_LEND = 1,  // read-only view
  WOK_TRANSFER_COPY = 2,  // duplicated across the boundary
};

// ------------------------------------------------------------- the schema
//
// One line per node: X(tag, FAMILY). The FIELDS macro takes the field-emitting
// macro F and the tag T, so the generated names can be prefixed per node, and
// each field reads F(T, CLASS, name, FAMILY) -- the class it stores, and the
// family it demands of whatever fills it.

#define WOK_NODES(X)                                                       \
  /* names and paths */                                                    \
  X(N_Name, NAME) X(N_ModPath, PATH)                                       \
  /* declarations */                                                       \
  X(D_Module, DECL) X(D_Import, DECL) X(D_Type, DECL) X(D_Alias, DECL)     \
  X(D_Effect, DECL) X(D_Class, DECL) X(D_Instance, DECL)                   \
  X(D_Foreign, DECL) X(D_ExternType, DECL) X(D_Sig, DECL)                  \
  X(D_Equation, DECL) X(D_Error, ERROR)                                     \
  /* declaration helpers */                                                \
  X(H_TyParam, TYPARAM) X(H_ConDef, CONDEF) X(H_FieldType, FIELDTYPE)      \
  X(H_OpSig, OPSIG) X(H_ForeignMember, FOREIGNMEM) X(H_SigName, SIGNAME)   \
  X(L_Prefix, LHS) X(L_Infix, LHS)                                         \
  /* types */                                                              \
  X(T_Var, TYPE) X(T_Con, TYPE) X(T_App, TYPE) X(T_Fun, TYPE)              \
  X(T_Qual, TYPE) X(T_With, TYPE) X(T_List, TYPE) X(T_Tuple, TYPE)         \
  X(T_Unit, TYPE) X(T_RowArg, TYPE) X(T_Transfer, TYPE)                    \
  X(H_RowEntry, ROWENTRY)                                                  \
  /* patterns */                                                           \
  X(P_Var, PAT) X(P_Wild, PAT) X(P_Int, PAT) X(P_Str, PAT) X(P_Char, PAT)  \
  X(P_Con, PAT) X(P_Cons, PAT) X(P_Tuple, PAT) X(P_List, PAT)              \
  X(P_Unit, PAT) X(P_As, PAT) X(P_Record, PAT) X(H_FieldPat, FIELDPAT)     \
  /* expressions */                                                        \
  X(E_Var, EXPR) X(E_Con, EXPR) X(E_Int, EXPR) X(E_Str, EXPR)              \
  X(E_Char, EXPR) X(E_Unit, EXPR) X(E_OpRef, EXPR) X(E_App, EXPR)          \
  X(E_Chain, EXPR) X(E_Dot, EXPR) X(E_Neg, EXPR) X(E_List, EXPR)           \
  X(E_Tuple, EXPR) X(E_Lambda, EXPR) X(E_LetIn, EXPR) X(E_HandleIn, EXPR)  \
  X(E_UseIn, EXPR) X(E_If, EXPR) X(E_Case, EXPR) X(E_Handler, EXPR)        \
  X(E_Assign, EXPR) X(E_Record, EXPR) X(E_Block, EXPR)          \
  X(E_Error, ERROR)    \
  /* statements (D11: an indented block is a SEQUENCE) */                  \
  X(S_Let, STMT) X(S_Handle, STMT) X(S_Use, STMT) X(S_Discard, STMT)       \
  /* expression helpers */                                                 \
  X(H_ChainOp, CHAINOP) X(H_Bind, BIND) X(H_UseBind, USEBIND)              \
  X(H_Alt, ALT) X(H_Clause, CLAUSE) X(H_Field, FIELD)                      \
  /* the file */                                                           \
  X(W_File, FILE)

// names ---------------------------------------------------------------------
#define N_Name_FIELDS(F, T) F(T, NAME, text, NONE) F(T, FLAG, upper, NONE)
#define N_ModPath_FIELDS(F, T) F(T, SEQ, parts, NAME)

// declarations --------------------------------------------------------------
#define D_Module_FIELDS(F, T) F(T, NODE, path, PATH)
// names is empty for a plain import; alias is null unless `as A` was written.
#define D_Import_FIELDS(F, T) \
  F(T, NODE, path, PATH) F(T, SEQ, names, NAME) F(T, OPT, alias, NAME)
#define D_Type_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, SEQ, params, TYPARAM) F(T, SEQ, cons, CONDEF)
#define D_Alias_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, SEQ, params, TYPARAM) F(T, NODE, body, TYPE)
#define D_Effect_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, SEQ, params, TYPARAM) F(T, SEQ, ops, OPSIG)
#define D_Class_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, SEQ, params, TYPARAM) F(T, SEQ, body, DECL)
#define D_Instance_FIELDS(F, T) \
  F(T, OPT, ctx, TYPE) F(T, NAME, name, NONE) F(T, SEQ, args, TYPE) \
  F(T, SEQ, body, DECL)
#define D_Foreign_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, TEXT, lib, NONE) F(T, SEQ, members, FOREIGNMEM)
#define D_ExternType_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, SEQ, params, TYPARAM)
// `extern` marks a compiler hole: analyses trust the MARKER, never a name.
#define D_Sig_FIELDS(F, T) \
  F(T, SEQ, names, SIGNAME) F(T, NODE, type, TYPE) F(T, FLAG, is_extern, NONE)
#define D_Equation_FIELDS(F, T) \
  F(T, NODE, lhs, LHS) F(T, NODE, body, EXPR) F(T, SEQ, wheres, DECL)
#define D_Error_FIELDS(F, T) F(T, TEXT, text, NONE)

#define H_TyParam_FIELDS(F, T) F(T, NAME, name, NONE) F(T, FLAG, is_row, NONE)
// name is empty for the elided record form `{ x : U64 }`.
#define H_ConDef_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, SEQ, args, TYPE) F(T, SEQ, fields, FIELDTYPE) \
  F(T, FLAG, is_record, NONE)
#define H_FieldType_FIELDS(F, T) F(T, NAME, name, NONE) F(T, NODE, type, TYPE)
#define H_OpSig_FIELDS(F, T) F(T, NAME, name, NONE) F(T, NODE, type, TYPE)
#define H_ForeignMember_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, TEXT, symbol, NONE) F(T, NODE, type, TYPE)
// paren records `(+)` so the printer re-derives the brackets from the fact.
#define H_SigName_FIELDS(F, T) F(T, NAME, name, NONE) F(T, FLAG, paren, NONE)

#define L_Prefix_FIELDS(F, T) \
  F(T, NAME, name, NONE) F(T, FLAG, paren, NONE) F(T, SEQ, args, PAT)
#define L_Infix_FIELDS(F, T) \
  F(T, NODE, left, PAT) F(T, NAME, op, NONE) F(T, FLAG, backtick, NONE) \
  F(T, NODE, right, PAT)

// types ---------------------------------------------------------------------
#define T_Var_FIELDS(F, T) F(T, NAME, name, NONE)
#define T_Con_FIELDS(F, T) F(T, NODE, path, PATH)
#define T_App_FIELDS(F, T) F(T, NODE, fn, TYPE) F(T, NODE, arg, TYPE)
#define T_Fun_FIELDS(F, T) F(T, NODE, from, TYPE) F(T, NODE, to, TYPE)
#define T_Qual_FIELDS(F, T) F(T, NODE, ctx, TYPE) F(T, NODE, body, TYPE)
#define T_With_FIELDS(F, T) F(T, NODE, body, TYPE) F(T, SEQ, row, ROWENTRY)
#define T_List_FIELDS(F, T) F(T, NODE, elem, TYPE)
#define T_Tuple_FIELDS(F, T) F(T, SEQ, items, TYPE)
#define T_Unit_FIELDS(F, T)
#define T_RowArg_FIELDS(F, T) F(T, NAME, name, NONE)
#define T_Transfer_FIELDS(F, T) F(T, INT, mode, NONE) F(T, NODE, body, TYPE)
// label is empty for a slot obligation; kind is one of WOK_ROW_*.
#define H_RowEntry_FIELDS(F, T) \
  F(T, INT, kind, NONE) F(T, NAME, label, NONE) F(T, OPT, type, TYPE)

// patterns ------------------------------------------------------------------
#define P_Var_FIELDS(F, T) F(T, NAME, name, NONE)
#define P_Wild_FIELDS(F, T)
#define P_Int_FIELDS(F, T) F(T, INT, value, NONE) F(T, FLAG, negative, NONE)
#define P_Str_FIELDS(F, T) F(T, TEXT, text, NONE)
#define P_Char_FIELDS(F, T) F(T, TEXT, text, NONE)
#define P_Con_FIELDS(F, T) F(T, NODE, path, PATH) F(T, SEQ, args, PAT)
#define P_Cons_FIELDS(F, T) F(T, NODE, head, PAT) F(T, NODE, tail, PAT)
#define P_Tuple_FIELDS(F, T) F(T, SEQ, items, PAT)
#define P_List_FIELDS(F, T) F(T, SEQ, items, PAT)
#define P_Unit_FIELDS(F, T)
#define P_As_FIELDS(F, T) F(T, NODE, pat, PAT) F(T, NAME, name, NONE)
// rest is empty unless `..name` was written; open records also set is_open.
#define P_Record_FIELDS(F, T) \
  F(T, NODE, path, PATH) F(T, SEQ, fields, FIELDPAT) F(T, FLAG, is_open, NONE) \
  F(T, NAME, rest, NONE)
#define H_FieldPat_FIELDS(F, T) F(T, NAME, name, NONE) F(T, NODE, pat, PAT)

// expressions ---------------------------------------------------------------
#define E_Var_FIELDS(F, T) F(T, NAME, name, NONE)
#define E_Con_FIELDS(F, T) F(T, NAME, name, NONE)
#define E_Int_FIELDS(F, T) F(T, INT, value, NONE)
#define E_Str_FIELDS(F, T) F(T, TEXT, text, NONE)
#define E_Char_FIELDS(F, T) F(T, TEXT, text, NONE)
#define E_Unit_FIELDS(F, T)
#define E_OpRef_FIELDS(F, T) F(T, NAME, name, NONE)
#define E_App_FIELDS(F, T) F(T, NODE, fn, EXPR) F(T, NODE, arg, EXPR)
// FLAT: precedence and associativity are a later pass's job, exactly as
// src/Wok/Reordering.hs already expects. No fixity table lives in the parser.
#define E_Chain_FIELDS(F, T) F(T, NODE, head, EXPR) F(T, SEQ, ops, CHAINOP)
#define H_ChainOp_FIELDS(F, T) \
  F(T, NAME, op, NONE) F(T, FLAG, backtick, NONE) F(T, NODE, rhs, EXPR)
// ONE Dot node for `M.f`, `st.get` and `p.x`: spec 1.5 resolves qualifier /
// label / projection later, and its collision rule needs them undistinguished
// at parse time.
#define E_Dot_FIELDS(F, T) \
  F(T, NODE, recv, EXPR) F(T, NAME, name, NONE) F(T, FLAG, upper, NONE)
#define E_Neg_FIELDS(F, T) F(T, NODE, body, EXPR)
#define E_List_FIELDS(F, T) F(T, SEQ, items, EXPR)
#define E_Tuple_FIELDS(F, T) F(T, SEQ, items, EXPR)
#define E_Lambda_FIELDS(F, T) F(T, SEQ, params, PAT) F(T, NODE, body, EXPR)
#define E_LetIn_FIELDS(F, T) F(T, NODE, bind, BIND) F(T, NODE, body, EXPR)
// label is empty when elided -- legal only in this delimited inline form
// (D13 two-tier); the statement form S_Handle always writes one.
#define E_HandleIn_FIELDS(F, T) \
  F(T, NAME, label, NONE) F(T, NODE, handler, EXPR) F(T, NODE, body, EXPR)
#define E_UseIn_FIELDS(F, T) F(T, SEQ, binds, USEBIND) F(T, NODE, body, EXPR)
#define E_If_FIELDS(F, T) \
  F(T, NODE, cond, EXPR) F(T, NODE, then_, EXPR) F(T, NODE, else_, EXPR)
#define E_Case_FIELDS(F, T) F(T, NODE, scrut, EXPR) F(T, SEQ, alts, ALT)
// `handler E` names its effect MANDATORILY (C3).
#define E_Handler_FIELDS(F, T) \
  F(T, NAME, effect, NONE) F(T, SEQ, clauses, CLAUSE)
#define E_Assign_FIELDS(F, T) F(T, NODE, target, EXPR) F(T, NODE, value, EXPR)
#define E_Record_FIELDS(F, T) \
  F(T, NODE, path, EXPR) F(T, OPT, spread, EXPR) F(T, SEQ, fields, FIELD)
#define E_Block_FIELDS(F, T) F(T, SEQ, stmts, STMT)
#define E_Error_FIELDS(F, T) F(T, TEXT, text, NONE)

#define S_Let_FIELDS(F, T) F(T, NODE, bind, BIND)
#define S_Handle_FIELDS(F, T) F(T, NAME, label, NONE) F(T, NODE, handler, EXPR)
#define S_Use_FIELDS(F, T) F(T, SEQ, binds, USEBIND)
#define S_Discard_FIELDS(F, T) F(T, NODE, body, EXPR)

#define H_Bind_FIELDS(F, T) F(T, NODE, lhs, BINDLHS) F(T, NODE, body, EXPR)
#define H_UseBind_FIELDS(F, T) F(T, NAME, from, NONE) F(T, NAME, to, NONE)
#define H_Alt_FIELDS(F, T) \
  F(T, NODE, pat, PAT) F(T, NODE, body, EXPR) F(T, SEQ, wheres, DECL)
// `once` splits its binders: the LAST is the continuation, stored separately,
// so E-ARITY can compare pattern count against op arity directly (D14).
#define H_Clause_FIELDS(F, T) \
  F(T, INT, kind, NONE) F(T, NAME, name, NONE) F(T, SEQ, pats, PAT) \
  F(T, NAME, k, NONE) F(T, NODE, body, EXPR)
#define H_Field_FIELDS(F, T) F(T, NAME, name, NONE) F(T, NODE, value, EXPR)

#define W_File_FIELDS(F, T) F(T, SEQ, decls, DECL)

// ------------------------------------------------------------ derived: tags

typedef enum : u16 {
#define WOK_X(tag, fam) tag,
  WOK_NODES(WOK_X)
#undef WOK_X
      WOK_TAG_COUNT
} WokTag;

// ------------------------------------------------- derived: slot indices

#define WOK_SLOT_INDEX(T, cls, name, fam) T##__##name,
#define WOK_DECLARE_SLOTS(T, fam) \
  enum { T##_FIELDS(WOK_SLOT_INDEX, T) T##__NSLOTS };
WOK_NODES(WOK_DECLARE_SLOTS)
#undef WOK_DECLARE_SLOTS

// ------------------------------------------- derived: accessors and setters

#define WOK_CT_NODE WokNode *
#define WOK_CT_OPT WokNode *
#define WOK_CT_SEQ WokSeq
#define WOK_CT_NAME WokSpan
#define WOK_CT_TEXT WokSpan
#define WOK_CT_INT u64
#define WOK_CT_FLAG bool

#define WOK_GET_NODE(s) ((s).node)
#define WOK_GET_OPT(s) ((s).node)
#define WOK_GET_SEQ(s) wok_seq_unpack((s).seq)
#define WOK_GET_NAME(s) ((s).span)
#define WOK_GET_TEXT(s) ((s).span)
#define WOK_GET_INT(s) ((s).num)
#define WOK_GET_FLAG(s) ((s).flag)

#define WOK_MK_NODE(v) ((WokSlot){.node = (v)})
#define WOK_MK_OPT(v) ((WokSlot){.node = (v)})
#define WOK_MK_SEQ(v) ((WokSlot){.seq = (v).items})
#define WOK_MK_NAME(v) ((WokSlot){.span = (v)})
#define WOK_MK_TEXT(v) ((WokSlot){.span = (v)})
#define WOK_MK_INT(v) ((WokSlot){.num = (v)})
#define WOK_MK_FLAG(v) ((WokSlot){.flag = (v)})

#define WOK_SLOT_ACCESS(T, cls, name, fam)                                 \
  static inline WOK_CT_##cls T##_##name(const WokNode *n) {           \
    assert(n->tag == T);                                              \
    return WOK_GET_##cls(n->slot[T##__##name]);                       \
  }                                                                   \
  static inline void T##_set_##name(WokNode *n, WOK_CT_##cls v) {     \
    assert(n->tag == T);                                              \
    n->slot[T##__##name] = WOK_MK_##cls(v);                           \
  }
#define WOK_DECLARE_ACCESS(T, fam) T##_FIELDS(WOK_SLOT_ACCESS, T)
WOK_NODES(WOK_DECLARE_ACCESS)
#undef WOK_DECLARE_ACCESS

// --------------------------------------------------- derived: descriptors

typedef struct {
  const char *name;
  WokFieldClass cls;
  WokFamily family;  // WFAM_NONE unless the field holds a child
} WokFieldDesc;

typedef struct {
  const char *tag;
  const WokFieldDesc *fields;
  u16 nfields;
  WokFamily family;  // the family this node BELONGS to
} WokNodeDesc;

extern const WokNodeDesc wok_node_desc[WOK_TAG_COUNT];

WOK_READONLY const char *wok_family_name(WokFamily);

// ------------------------------------------------------------ construction

// Allocates a node with the slot count its tag declares, zeroed. The parser
// never states an arity: the schema does.
WokNode *wok_node(WokArena *, WokTag, u32 off, u32 len);
WokSeq wok_seq(WokArena *, WokNode *const *restrict items, u32 n);


static inline WokSpan wok_span(u32 off, u32 len) {
  return (WokSpan){.off = off, .len = len};
}
static inline bool wok_span_empty(WokSpan s) { return s.len == 0; }

// A growable node list for the parser, backed by the arena.
// The fields are named to be awkward on purpose: index 0 is RESERVED for the
// inline count so wok_buf_seq can hand out the buffer without copying, which
// means `raw`/`raw_n` do not mean what `items`/`n` used to. Reading them
// directly is how a tree gets silently corrupted -- use the accessors.
typedef struct {
  WokNode **raw;
  u32 raw_n, cap;
  WokArena *arena;
} WokNodeBuf;

static inline u32 wok_buf_count(const WokNodeBuf *b) {
  return b->raw_n > 0 ? b->raw_n - 1u : 0u;
}
static inline WokNode *wok_buf_at(const WokNodeBuf *b, u32 i) {
  return b->raw[i + 1u];
}

void wok_buf_init(WokNodeBuf *, WokArena *);
void wok_buf_push(WokNodeBuf *, WokNode *);
WokSeq wok_buf_seq(WokNodeBuf *);

// --------------------------------------------------------------- coverage
//
// Production coverage, not line coverage. Every parse* function marks its tag
// on entry; the corpus must reach 100%, and a form no file reaches names
// itself rather than sitting silently uncovered.

void wok_cover_mark(WokTag);
void wok_cover_reset(void);
bool wok_cover_seen(WokTag);
usize wok_cover_missing(const WokTag **out);

