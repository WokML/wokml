// wok_ast -- THE SCHEMA. Every node's fields are written exactly once, here.
//
// From this one list the build derives: the tag enum, the per-node slot
// indices, typed accessors and setters, and a descriptor table that the dump,
// the reader and the coverage bitmap all walk generically. Adding a node means
// adding one line; forgetting to teach the dump about it is impossible,
// because the dump does not know about nodes individually.
//
// Nodes are UNIFORM: a header plus a flexible array of slots. That trades a
// little static typing for a schema a machine can walk, so the setters carry
// a debug-build check that a slot receives the family it was declared with.

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
  u16 tag;
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
// One line per node. The FIELDS macro takes the field-emitting macro F and
// the tag T, so the generated names can be prefixed per node.

#define WOK_NODES(X)                                                        \
  /* names and paths */                                                     \
  X(N_Name) X(N_ModPath)                                                    \
  /* declarations */                                                        \
  X(D_Module) X(D_Import) X(D_Type) X(D_Alias) X(D_Effect) X(D_Class)       \
  X(D_Instance) X(D_Foreign) X(D_ExternType) X(D_Sig) X(D_Equation)         \
  X(D_Error)                                                                \
  /* declaration helpers */                                                 \
  X(H_TyParam) X(H_ConDef) X(H_FieldType) X(H_OpSig) X(H_ForeignMember)     \
  X(H_SigName) X(L_Prefix) X(L_Infix)                                       \
  /* types */                                                               \
  X(T_Var) X(T_Con) X(T_App) X(T_Fun) X(T_Qual) X(T_With) X(T_List)         \
  X(T_Tuple) X(T_Unit) X(T_RowArg) X(T_Transfer) X(H_RowEntry)              \
  /* patterns */                                                            \
  X(P_Var) X(P_Wild) X(P_Int) X(P_Str) X(P_Char) X(P_Con) X(P_Cons)         \
  X(P_Tuple) X(P_List) X(P_Unit) X(P_As) X(P_Record) X(H_FieldPat)          \
  /* expressions */                                                         \
  X(E_Var) X(E_Con) X(E_Int) X(E_Str) X(E_Char) X(E_Unit) X(E_OpRef)        \
  X(E_App) X(E_Chain) X(E_Dot) X(E_Neg) X(E_List) X(E_Tuple) X(E_Lambda)    \
  X(E_LetIn) X(E_HandleIn) X(E_UseIn) X(E_If) X(E_Case) X(E_Handler)        \
  X(E_Assign) X(E_Record) X(E_Block) X(E_Error)                             \
  /* statements (D11: an indented block is a SEQUENCE) */                   \
  X(S_Let) X(S_Handle) X(S_Use) X(S_Discard)                                \
  /* expression helpers */                                                  \
  X(H_ChainOp) X(H_Bind) X(H_UseBind) X(H_Alt) X(H_Clause) X(H_Field)       \
  /* the file */                                                            \
  X(W_File)

// names ---------------------------------------------------------------------
#define N_Name_FIELDS(F, T)    F(T, NAME, text) F(T, FLAG, upper)
#define N_ModPath_FIELDS(F, T) F(T, SEQ, parts)

// declarations --------------------------------------------------------------
#define D_Module_FIELDS(F, T) F(T, NODE, path)
// names is empty for a plain import; alias is null unless `as A` was written.
#define D_Import_FIELDS(F, T) F(T, NODE, path) F(T, SEQ, names) F(T, OPT, alias)
#define D_Type_FIELDS(F, T)   F(T, NAME, name) F(T, SEQ, params) F(T, SEQ, cons)
#define D_Alias_FIELDS(F, T)  F(T, NAME, name) F(T, SEQ, params) F(T, NODE, body)
#define D_Effect_FIELDS(F, T) F(T, NAME, name) F(T, SEQ, params) F(T, SEQ, ops)
#define D_Class_FIELDS(F, T)  F(T, NAME, name) F(T, SEQ, params) F(T, SEQ, body)
#define D_Instance_FIELDS(F, T) \
  F(T, OPT, ctx) F(T, NAME, name) F(T, SEQ, args) F(T, SEQ, body)
#define D_Foreign_FIELDS(F, T) \
  F(T, NAME, name) F(T, TEXT, lib) F(T, SEQ, members)
#define D_ExternType_FIELDS(F, T) F(T, NAME, name) F(T, SEQ, params)
// `extern` marks a compiler hole: analyses trust the MARKER, never a name.
#define D_Sig_FIELDS(F, T) \
  F(T, SEQ, names) F(T, NODE, type) F(T, FLAG, is_extern)
#define D_Equation_FIELDS(F, T) \
  F(T, NODE, lhs) F(T, NODE, body) F(T, SEQ, wheres)
#define D_Error_FIELDS(F, T) F(T, TEXT, text)

#define H_TyParam_FIELDS(F, T) F(T, NAME, name) F(T, FLAG, is_row)
// name is empty for the elided record form `{ x : U64 }`.
#define H_ConDef_FIELDS(F, T) \
  F(T, NAME, name) F(T, SEQ, args) F(T, SEQ, fields) F(T, FLAG, is_record)
#define H_FieldType_FIELDS(F, T) F(T, NAME, name) F(T, NODE, type)
#define H_OpSig_FIELDS(F, T)     F(T, NAME, name) F(T, NODE, type)
#define H_ForeignMember_FIELDS(F, T) \
  F(T, NAME, name) F(T, TEXT, symbol) F(T, NODE, type)
// paren records `(+)` so the printer re-derives the brackets from the fact.
#define H_SigName_FIELDS(F, T) F(T, NAME, name) F(T, FLAG, paren)

#define L_Prefix_FIELDS(F, T) \
  F(T, NAME, name) F(T, FLAG, paren) F(T, SEQ, args)
#define L_Infix_FIELDS(F, T) \
  F(T, NODE, left) F(T, NAME, op) F(T, FLAG, backtick) F(T, NODE, right)

// types ---------------------------------------------------------------------
#define T_Var_FIELDS(F, T)   F(T, NAME, name)
#define T_Con_FIELDS(F, T)   F(T, NODE, path)
#define T_App_FIELDS(F, T)   F(T, NODE, fn) F(T, NODE, arg)
#define T_Fun_FIELDS(F, T)   F(T, NODE, from) F(T, NODE, to)
#define T_Qual_FIELDS(F, T)  F(T, NODE, ctx) F(T, NODE, body)
#define T_With_FIELDS(F, T)  F(T, NODE, body) F(T, SEQ, row)
#define T_List_FIELDS(F, T)  F(T, NODE, elem)
#define T_Tuple_FIELDS(F, T) F(T, SEQ, items)
#define T_Unit_FIELDS(F, T)
#define T_RowArg_FIELDS(F, T)  F(T, NAME, name)
#define T_Transfer_FIELDS(F, T) F(T, INT, mode) F(T, NODE, body)
// label is empty for a slot obligation; kind is one of WOK_ROW_*.
#define H_RowEntry_FIELDS(F, T) \
  F(T, INT, kind) F(T, NAME, label) F(T, OPT, type)

// patterns ------------------------------------------------------------------
#define P_Var_FIELDS(F, T)  F(T, NAME, name)
#define P_Wild_FIELDS(F, T)
#define P_Int_FIELDS(F, T)  F(T, INT, value) F(T, FLAG, negative)
#define P_Str_FIELDS(F, T)  F(T, TEXT, text)
#define P_Char_FIELDS(F, T) F(T, TEXT, text)
#define P_Con_FIELDS(F, T)  F(T, NODE, path) F(T, SEQ, args)
#define P_Cons_FIELDS(F, T) F(T, NODE, head) F(T, NODE, tail)
#define P_Tuple_FIELDS(F, T) F(T, SEQ, items)
#define P_List_FIELDS(F, T)  F(T, SEQ, items)
#define P_Unit_FIELDS(F, T)
#define P_As_FIELDS(F, T)    F(T, NODE, pat) F(T, NAME, name)
// rest is empty unless `..name` was written; open records also set is_open.
#define P_Record_FIELDS(F, T) \
  F(T, NODE, path) F(T, SEQ, fields) F(T, FLAG, is_open) F(T, NAME, rest)
#define H_FieldPat_FIELDS(F, T) F(T, NAME, name) F(T, NODE, pat)

// expressions ---------------------------------------------------------------
#define E_Var_FIELDS(F, T)   F(T, NAME, name)
#define E_Con_FIELDS(F, T)   F(T, NAME, name)
#define E_Int_FIELDS(F, T)   F(T, INT, value)
#define E_Str_FIELDS(F, T)   F(T, TEXT, text)
#define E_Char_FIELDS(F, T)  F(T, TEXT, text)
#define E_Unit_FIELDS(F, T)
#define E_OpRef_FIELDS(F, T) F(T, NAME, name)
#define E_App_FIELDS(F, T)   F(T, NODE, fn) F(T, NODE, arg)
// FLAT: precedence and associativity are a later pass's job, exactly as
// src/Wok/Reordering.hs already expects. No fixity table lives in the parser.
#define E_Chain_FIELDS(F, T) F(T, NODE, head) F(T, SEQ, ops)
#define H_ChainOp_FIELDS(F, T) \
  F(T, NAME, op) F(T, FLAG, backtick) F(T, NODE, rhs)
// ONE Dot node for `M.f`, `st.get` and `p.x`: spec 1.5 resolves qualifier /
// label / projection later, and its collision rule needs them undistinguished
// at parse time.
#define E_Dot_FIELDS(F, T) F(T, NODE, recv) F(T, NAME, name) F(T, FLAG, upper)
#define E_Neg_FIELDS(F, T)   F(T, NODE, body)
#define E_List_FIELDS(F, T)  F(T, SEQ, items)
#define E_Tuple_FIELDS(F, T) F(T, SEQ, items)
#define E_Lambda_FIELDS(F, T) F(T, SEQ, params) F(T, NODE, body)
#define E_LetIn_FIELDS(F, T)  F(T, NODE, bind) F(T, NODE, body)
// label is empty when elided -- legal only in this delimited inline form
// (D13 two-tier); the statement form S_Handle always writes one.
#define E_HandleIn_FIELDS(F, T) \
  F(T, NAME, label) F(T, NODE, handler) F(T, NODE, body)
#define E_UseIn_FIELDS(F, T) F(T, SEQ, binds) F(T, NODE, body)
#define E_If_FIELDS(F, T) F(T, NODE, cond) F(T, NODE, then_) F(T, NODE, else_)
#define E_Case_FIELDS(F, T) F(T, NODE, scrut) F(T, SEQ, alts)
// `handler E` names its effect MANDATORILY (C3).
#define E_Handler_FIELDS(F, T) F(T, NAME, effect) F(T, SEQ, clauses)
#define E_Assign_FIELDS(F, T)  F(T, NODE, target) F(T, NODE, value)
#define E_Record_FIELDS(F, T) \
  F(T, NODE, path) F(T, OPT, spread) F(T, SEQ, fields)
#define E_Block_FIELDS(F, T) F(T, SEQ, stmts)
#define E_Error_FIELDS(F, T) F(T, TEXT, text)

#define S_Let_FIELDS(F, T)     F(T, NODE, bind)
#define S_Handle_FIELDS(F, T)  F(T, NAME, label) F(T, NODE, handler)
#define S_Use_FIELDS(F, T)     F(T, SEQ, binds)
#define S_Discard_FIELDS(F, T) F(T, NODE, body)

#define H_Bind_FIELDS(F, T)    F(T, NODE, lhs) F(T, NODE, body)
#define H_UseBind_FIELDS(F, T) F(T, NAME, from) F(T, NAME, to)
#define H_Alt_FIELDS(F, T) F(T, NODE, pat) F(T, NODE, body) F(T, SEQ, wheres)
// `once` splits its binders: the LAST is the continuation, stored separately,
// so E-ARITY can compare pattern count against op arity directly (D14).
#define H_Clause_FIELDS(F, T)                                        \
  F(T, INT, kind) F(T, NAME, name) F(T, SEQ, pats) F(T, NAME, k)     \
  F(T, NODE, body)
#define H_Field_FIELDS(F, T) F(T, NAME, name) F(T, NODE, value)

#define W_File_FIELDS(F, T) F(T, SEQ, decls)

// ------------------------------------------------------------ derived: tags

typedef enum : u16 {
#define WOK_X(tag) tag,
  WOK_NODES(WOK_X)
#undef WOK_X
      WOK_TAG_COUNT
} WokTag;

// ------------------------------------------------- derived: slot indices

#define WOK_SLOT_INDEX(T, cls, name) T##__##name,
#define WOK_DECLARE_SLOTS(T) \
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

#define WOK_SLOT_ACCESS(T, cls, name)                                 \
  static inline WOK_CT_##cls T##_##name(const WokNode *n) {           \
    assert(n->tag == T);                                              \
    return WOK_GET_##cls(n->slot[T##__##name]);                       \
  }                                                                   \
  static inline void T##_set_##name(WokNode *n, WOK_CT_##cls v) {     \
    assert(n->tag == T);                                              \
    n->slot[T##__##name] = WOK_MK_##cls(v);                           \
  }
#define WOK_DECLARE_ACCESS(T) T##_FIELDS(WOK_SLOT_ACCESS, T)
WOK_NODES(WOK_DECLARE_ACCESS)
#undef WOK_DECLARE_ACCESS

// --------------------------------------------------- derived: descriptors

typedef struct {
  const char *name;
  WokFieldClass cls;
} WokFieldDesc;

typedef struct {
  const char *tag;
  const WokFieldDesc *fields;
  u16 nfields;
} WokNodeDesc;

extern const WokNodeDesc wok_node_desc[WOK_TAG_COUNT];

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

