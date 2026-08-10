// G1 -- the metamorphic properties over the SPACE of trees, not over a corpus.
//
// test_metamorphic runs the round-trip over 25 files somebody thought to
// write. This runs it over the space those files are drawn from: every tree is
// BUILT rather than read, so it is valid by construction and every case
// exercises the printer and the parser against each other instead of
// re-testing recovery. It is the difference between "every node was built
// once", which the production-coverage roster already asserts, and "every
// COMBINATION was tried", which nothing else asserts.
//
// The seven properties, for every generated tree t:
//
//   1. Dump(Parse(Print(t))) == Dump(t)       the printer and the parser agree
//   2. Print(Parse(Print(t))) == Print(t)     the formatter is a fixed point
//   3. Print(t) parses with ZERO diagnostics
//   4. Print(t) satisfies every layout invariant, in its strict form
//   5. the printer's safety latch never fires
//   6. Dump(Read(Dump(t))) == Dump(t), through the STRICT reader
//   7. no node in t is one the printer refuses to write
//
// The first is load-bearing, and is the reason dumps are compared rather than
// text: under an offside rule a misplaced break is not a syntax error, so the
// output still parses and only the tree shows the damage.
//
// SCOPE. The whole schema: 80 of its 82 tags are reached by generation alone,
// with no corpus. The two that are not are the ERROR nodes, which mark damage
// -- no well-formed program holds one, and the printer refuses them by design.
//
// The cost of that reach is the list of implicit invariants at the foot of
// this file. Each is a rule that lives in wok_parse.c and nowhere else, and
// writing them down is the real output of these slices: the schema records a
// field's CLASS, and none of it records these.
//
// THE TABLES ARE READ AS WELL AS WRITTEN. Generation builds trees the tables
// describe by construction; SHRINKING rewrites finished slots, so it can write
// something they forbid. node_valid asks the tables the same questions the
// builder asked, every shrink candidate is checked against it BEFORE the
// printer sees it, and shrink_audit applies every move the shrinker could make
// to prove none of them is illegal. That gap is not hypothetical: emptying an
// option a shape declares always present segfaulted wok_print.
//
// DETERMINISM. Tree i is a pure function of its seed. A failure is MINIMISED
// before it is reported -- a hundred-node counterexample is a puzzle, and
// nobody acts on one -- and what is printed is the reduced tree's dump, which
// wok_sexpr_read reads straight back. `./test_generative <seed>` rebuilds and
// re-reports one tree. A property test that cannot reproduce its own
// counterexample is a rumour.

// First, and deliberately: this suite uses dup2 for the hush below, and
// wok_base.h carries the POSIX feature-test macros. See the ordering rule
// there.
#include "wok_base.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_diag.h"
#include "../wok_layout.h"
#include "../wok_parse.h"
#include "../wok_print.h"
#include "../wok_sexpr.h"
#include "../wok_token.h"

enum {
  GEN_TREES = 5000,  // per invocation; this must stay inside `make test`
  GEN_SEED = 0x5EED,
  GEN_DEPTH = 5,  // the budget a tree starts with, in generations of children
};

// ------------------------------------------------------------------- rng
//
// splitmix64. Small, seekable and stateless apart from the counter the caller
// owns, so tree i is reproducible from its seed alone.

typedef struct {
  u64 s;
} Rng;

static u64 rng_next(Rng *r) {
  r->s += UINT64_C(0x9E3779B97F4A7C15);
  u64 z = r->s;
  z = (z ^ (z >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
  z = (z ^ (z >> 27)) * UINT64_C(0x94D049BB133111EB);
  return z ^ (z >> 31);
}

static u32 rng_below(Rng *r, u32 n) { return (u32)(rng_next(r) % n); }

static bool rng_bool(Rng *r) { return (rng_next(r) & 1u) != 0; }

// ----------------------------------------------------------------- atoms
//
// Every NAME and TEXT span in a generated tree points into ONE buffer, exactly
// as a parsed tree's spans point into its source file. The atoms are CHOSEN,
// not generated: random bytes would spend the whole budget rediscovering the
// scanner, which test_utf8 and the two fuzzers already own. What is under test
// here is the combination of nodes, so the leaves are held still.

static const char *const A_LOWER[] = {"a", "b", "x", "xs", "val", "step"};
static const char *const A_UPPER[] = {"A", "Cons", "Maybe", "St"};
// Symbolic operator runs. No reserved run (`=`, `:`, `->`, `=>`, `::`, `:=`,
// `|`) and no run of two or more dashes, which scans as a comment.
static const char *const A_OPSYM[] = {"+", "*", "<>", "<+>", "-"};
// Alphabetic operators, which can only ever have been written in backticks.
static const char *const A_OPWORD[] = {"add", "mod"};
static const char *const A_STRING[] = {"\"s\"", "\"a b\"", "\"q\\n\""};
static const char *const A_CHAR[] = {"'c'", "'\\n'"};

static const u64 A_INT[] = {0, 1, 7, 42, 1000, UINT64_MAX};

typedef struct {
  const WokSpan *span;
  u32 n;
} Atoms;

typedef struct {
  const char *src;
  Atoms lower, upper, opsym, opword, string, chr;
} Pool;

typedef struct {
  char *buf;
  usize len;
  WokArena *arena;
} PoolBuild;

static WokSpan pool_intern(PoolBuild *b, const char *text) {
  usize n = strlen(text);
  memcpy(b->buf + b->len, text, n);
  WokSpan s = wok_span((u32)b->len, (u32)n);
  b->len += n;
  b->buf[b->len++] = ' ';  // atoms never abut, so no span can be widened
  return s;
}

static Atoms pool_atoms(PoolBuild *b, const char *const *text, u32 n) {
  WokSpan *s = WOK_NEW_N(b->arena, WokSpan, n);
  for (u32 i = 0; i < n; i++) s[i] = pool_intern(b, text[i]);
  return (Atoms){.span = s, .n = n};
}

#define COUNT(a) ((u32)(sizeof(a) / sizeof *(a)))

WOK_READONLY static usize pool_bytes(const char *const *text, u32 n) {
  usize total = 0;
  for (u32 i = 0; i < n; i++) total += strlen(text[i]) + 1;
  return total;
}

static Pool pool_build(WokArena *arena) {
  usize cap = pool_bytes(A_LOWER, COUNT(A_LOWER)) +
              pool_bytes(A_UPPER, COUNT(A_UPPER)) +
              pool_bytes(A_OPSYM, COUNT(A_OPSYM)) +
              pool_bytes(A_OPWORD, COUNT(A_OPWORD)) +
              pool_bytes(A_STRING, COUNT(A_STRING)) +
              pool_bytes(A_CHAR, COUNT(A_CHAR)) + 1;
  PoolBuild b = {.buf = WOK_NEW_N(arena, char, cap), .len = 0, .arena = arena};
  Pool p = {.src = b.buf,
            .lower = pool_atoms(&b, A_LOWER, COUNT(A_LOWER)),
            .upper = pool_atoms(&b, A_UPPER, COUNT(A_UPPER)),
            .opsym = pool_atoms(&b, A_OPSYM, COUNT(A_OPSYM)),
            .opword = pool_atoms(&b, A_OPWORD, COUNT(A_OPWORD)),
            .string = pool_atoms(&b, A_STRING, COUNT(A_STRING)),
            .chr = pool_atoms(&b, A_CHAR, COUNT(A_CHAR))};
  b.buf[b.len] = '\0';
  return p;
}

// --------------------------------------------------------- the field rules
//
// THE FAMILY TABLE. Since G4 the schema carries families of its own, and this
// table REFINES them: `wok_ast.h` says D_Equation.body takes an EXPR, and this
// says which expressions may stand there -- E_Block only where layout is live,
// no bare negation where parse_lhs would read one as an operator. check_refines
// cross-checks the two at startup, so the pair can narrow but never disagree.
//
// What stays here is what a per-field annotation cannot express: cardinality
// (E_Chain needs an operator), dependency (H_Clause's kind governs three of its
// own fields), and reachability (a shape legal in one caller's slot and not in
// another's). Those are the invariants listed at the foot of the file.
//
// A rule byte is read through the field's declared class, so each class has
// its own small roster and the three can never be confused.

// NODE, OPT and SEQ fields: which family fills them.
typedef enum : u8 {
  FAM_EXPR,       // any expression; the printer re-derives every bracket
  FAM_BODY,       // the same, plus E_Block -- see THE BLOCK RULE below
  FAM_TYPE,       // any type
  FAM_FTYPE,      // a type in a foreign member, where a transfer may stand
  FAM_PAT,        // any pattern
  FAM_LHSPAT,     // a pattern that cannot BEGIN with a lowercase name
  FAM_INFIXLHS,   // the left of an infix equation: that, or a BARE variable
  FAM_CONPATH,    // an expression the parser will accept as a record head
  FAM_MODPATH,    // N_ModPath
  FAM_CONNAME,    // one uppercase N_Name, a module-path part
  FAM_ANYNAME,    // one N_Name of either case, as an import list writes them
  FAM_CHAINOP,    // H_ChainOp
  FAM_ROWENTRY,   // H_RowEntry
  FAM_FIELD,      // H_Field
  FAM_FIELDPAT,   // H_FieldPat
  FAM_USEBIND,    // H_UseBind
  FAM_STMT,       // a block item: S_* or a bare expression
  FAM_ALT,        // H_Alt
  FAM_CLAUSE,     // H_Clause
  FAM_BIND,       // H_Bind
  FAM_BINDLHS,    // what parse_bind accepts on the left of `=`
  FAM_LHS,        // what parse_lhs accepts: L_Prefix or L_Infix
  FAM_SIGNAME,    // H_SigName
  FAM_TYPARAM,    // H_TyParam
  FAM_CONDEF,     // H_ConDef
  FAM_FIELDTYPE,  // H_FieldType
  FAM_OPSIG,      // H_OpSig
  FAM_FIXREL,     // H_FixRel
  FAM_FOREIGNMEM, // H_ForeignMember
  FAM_SIGEQ,      // what a `where`, a class body and an instance body hold
  FAM_DECL,       // any top-level declaration
  FAM_FILE,       // W_File
  FAM_COUNT
} Fam;

// NAME and TEXT fields.
typedef enum : u8 {
  NR_LOWER,      // a lowercase identifier
  NR_UPPER,      // an uppercase identifier
  NR_ANY,        // either case, never empty
  NR_LABEL,      // either case, or elided
  NR_EMPTY,      // always elided: a field this node's form does not use
  NR_OPTNAME,    // a lowercase name, or elided
  NR_DEFNAME,    // a name being DEFINED: lowercase, or an operator in brackets
  NR_OPERATOR,   // an infix operator, symbolic or alphabetic
  NR_OPSYM,      // strictly symbolic: an operator section `(+)`
  NR_STRING,     // a string literal, quotes and escapes included
  NR_OPTSTRING,  // a string literal, or elided
  NR_CHAR,       // a character literal
} NameRule;

// INT fields. IR_CONST takes its value from the slot's `lo`, which is what
// lets a node with a KIND field be split into one shape per kind -- so the
// fields a kind governs are constants beside it rather than a rule that has
// to go and read it.
typedef enum : u8 {
  IR_VALUE,
  IR_TRANSFER,
  IR_CONST,
} IntRule;

// FLAG fields. The two DERIVED ones re-read the spelling in `dep`, exactly as
// the printer does, so a bit that disagrees with its own spelling is a tree no
// round trip survives. See invariant 9 at the bottom.
typedef enum : u8 {
  FR_UPPER_OF,
  FR_BACKTICK_OF,
  FR_PAREN_OF,
  FR_RANDOM,
  FR_FALSE,
  FR_TRUE,
} FlagRule;

// OPT fields: whether the option is taken. Most are a coin toss, but a form
// that is DEFINED by carrying (or not carrying) its option says so.
typedef enum : u8 {
  OPT_MAYBE,
  OPT_ALWAYS,
  OPT_NEVER,
} OptMode;

typedef struct {
  u8 rule;    // Fam, NameRule, IntRule or FlagRule, per the field's class
  u8 lo, hi;  // SEQ length bounds inclusive; IR_CONST's value; OPT's OptMode
  u8 dep;     // the slot a derived rule reads
  // THE BLOCK RULE. An indented block exists only where layout is live, and
  // layout is suspended inside brackets (L2). `flat` marks a slot the printer
  // writes inside a bracket group, or bracketed by precedence; it INHERITS, so
  // one such slot puts its whole subtree out of reach of E_Block. Every
  // expression slot is either a body slot -- where parse_body is called, and
  // the only place an E_Block can stand -- or flat.
  u8 flat;
  // This SEQ is an indented block of its own. Inside brackets the parser can
  // only have built a ONE-item block, because L2 suppressed every layout token
  // between them, and p_seq_block says so.
  u8 blk;
} Slot;

// One shape: a tag, and one Slot per declared field IN DECLARATION ORDER. A
// tag may appear under two families with two shapes -- E_Dot is an ordinary
// expression, and, with its name forced uppercase, a record head.
typedef struct {
  u16 tag;
  const Slot *slot;
  u8 nslot;
} Shape;

// Shapes that need no budget come FIRST, so the depth floor is just a shorter
// roster rather than a second table.
//
// `fallback` is how one family CONTAINS another without restating its roster:
// a block item is an S_* or any expression, and a binding's left side is an
// L_Prefix or a pattern that cannot begin with a name.
typedef struct {
  const Shape *shape;
  u8 nshape;
  u8 nleaf;
  u8 fallback;  // FAM_COUNT for none
} Family;

// names ---------------------------------------------------------------------
static const Slot SL_ConName[] = {{.rule = NR_UPPER}, {.rule = FR_UPPER_OF, .dep = 0}};
static const Slot SL_ModPath[] = {{.rule = FAM_CONNAME, .lo = 1, .hi = 2}};

// types ---------------------------------------------------------------------
static const Slot SL_TVar[] = {{.rule = NR_LOWER}};
static const Slot SL_TCon[] = {{.rule = FAM_MODPATH}};
static const Slot SL_TRowArg[] = {{.rule = NR_LOWER}};
static const Slot SL_TApp[] = {{.rule = FAM_TYPE}, {.rule = FAM_TYPE}};
static const Slot SL_TFun[] = {{.rule = FAM_TYPE}, {.rule = FAM_TYPE}};
static const Slot SL_TQual[] = {{.rule = FAM_TYPE}, {.rule = FAM_TYPE}};
static const Slot SL_TWith[] = {{.rule = FAM_TYPE},
                                {.rule = FAM_ROWENTRY, .lo = 1, .hi = 3}};
static const Slot SL_TList[] = {{.rule = FAM_TYPE}};
static const Slot SL_TTuple[] = {{.rule = FAM_TYPE, .lo = 2, .hi = 3}};
// One shape per row-entry KIND, so the two fields the kind governs are
// constants beside it: a slot obligation is unlabelled, a row variable carries
// no type, a role carries both.
static const Slot SL_RowSlot[] = {{.rule = IR_CONST, .lo = WOK_ROW_SLOT},
                                  {.rule = NR_EMPTY},
                                  {.rule = FAM_TYPE, .lo = OPT_ALWAYS}};
static const Slot SL_RowRole[] = {{.rule = IR_CONST, .lo = WOK_ROW_ROLE},
                                  {.rule = NR_LOWER},
                                  {.rule = FAM_TYPE, .lo = OPT_ALWAYS}};
static const Slot SL_RowVar[] = {{.rule = IR_CONST, .lo = WOK_ROW_VAR},
                                 {.rule = NR_LOWER},
                                 {.rule = FAM_TYPE, .lo = OPT_NEVER}};
// parse_typeapp reads a transfer only inside a foreign member's signature, and
// only at the TOP of one: `own` swallows the whole application to its right,
// exactly as `-` does in an expression, so a nested one would re-associate.
static const Slot SL_TTransfer[] = {{.rule = IR_TRANSFER}, {.rule = FAM_TYPE}};
static const Slot SL_TFunF[] = {{.rule = FAM_FTYPE}, {.rule = FAM_FTYPE}};

// expressions ---------------------------------------------------------------
static const Slot SL_EVar[] = {{.rule = NR_LOWER}};
static const Slot SL_ECon[] = {{.rule = NR_UPPER}};
static const Slot SL_EInt[] = {{.rule = IR_VALUE}};
static const Slot SL_EStr[] = {{.rule = NR_STRING}};
static const Slot SL_EChar[] = {{.rule = NR_CHAR}};
static const Slot SL_EOpRef[] = {{.rule = NR_OPSYM}};
#define FLAT .flat = 1
static const Slot SL_EApp[] = {{.rule = FAM_EXPR, FLAT},
                               {.rule = FAM_EXPR, FLAT}};
static const Slot SL_EChain[] = {{.rule = FAM_EXPR, FLAT},
                                 {.rule = FAM_CHAINOP, .lo = 1, .hi = 3, FLAT}};
static const Slot SL_ChainOp[] = {{.rule = NR_OPERATOR},
                                  {.rule = FR_BACKTICK_OF, .dep = 0},
                                  {.rule = FAM_EXPR, FLAT}};
static const Slot SL_EDot[] = {{.rule = FAM_EXPR, FLAT},
                               {.rule = NR_ANY},
                               {.rule = FR_UPPER_OF, .dep = 1}};
static const Slot SL_ENeg[] = {{.rule = FAM_EXPR, FLAT}};
static const Slot SL_EList[] = {{.rule = FAM_EXPR, .lo = 0, .hi = 3, FLAT}};
static const Slot SL_ETuple[] = {{.rule = FAM_EXPR, .lo = 2, .hi = 3, FLAT}};
// `if` and `case` read their head with parse_expr, so no E_Block can stand
// there -- but a LAMBDA whose body is a block can, and p_if/p_node's `split`
// arm is what exists to write it. So the head is not flat: it is an ordinary
// expression slot that happens to reject E_Block by roster.
static const Slot SL_EIf[] = {{.rule = FAM_EXPR},
                              {.rule = FAM_BODY},
                              {.rule = FAM_BODY}};
static const Slot SL_EAssign[] = {{.rule = FAM_EXPR, FLAT},
                                  {.rule = FAM_BODY}};
static const Slot SL_ERecord[] = {{.rule = FAM_CONPATH, FLAT},
                                  {.rule = FAM_EXPR, .lo = OPT_MAYBE, FLAT},
                                  {.rule = FAM_FIELD, .lo = 0, .hi = 3, FLAT}};
static const Slot SL_Field[] = {{.rule = NR_LOWER},
                                {.rule = FAM_EXPR, FLAT}};
static const Slot SL_EHandleIn[] = {{.rule = NR_LABEL},
                                    {.rule = FAM_EXPR},
                                    {.rule = FAM_BODY}};
static const Slot SL_EUseIn[] = {{.rule = FAM_USEBIND, .lo = 1, .hi = 2},
                                 {.rule = FAM_BODY}};
static const Slot SL_UseBind[] = {{.rule = NR_ANY}, {.rule = NR_ANY}};
static const Slot SL_ELambda[] = {{.rule = FAM_PAT, .lo = 0, .hi = 2},
                                  {.rule = FAM_BODY}};
static const Slot SL_ELetIn[] = {{.rule = FAM_BIND}, {.rule = FAM_BODY}};
static const Slot SL_ECase[] = {{.rule = FAM_EXPR},
                                {.rule = FAM_ALT, .lo = 1, .hi = 3, .blk = 1}};
static const Slot SL_EHandler[] = {
    {.rule = NR_UPPER}, {.rule = FAM_CLAUSE, .lo = 1, .hi = 3, .blk = 1}};
static const Slot SL_EBlock[] = {
    {.rule = FAM_STMT, .lo = 1, .hi = 3, .blk = 1}};

// A record head must be a constructor atom (parse_atom's is_con_atom), so its
// E_Dot shape forces the projected name uppercase.
static const Slot SL_EDotCon[] = {{.rule = FAM_EXPR, FLAT},
                                  {.rule = NR_UPPER},
                                  {.rule = FR_UPPER_OF, .dep = 1}};

// patterns ------------------------------------------------------------------
static const Slot SL_PVar[] = {{.rule = NR_LOWER}};
static const Slot SL_PInt[] = {{.rule = IR_VALUE}, {.rule = FR_RANDOM}};
static const Slot SL_PStr[] = {{.rule = NR_STRING}};
static const Slot SL_PChar[] = {{.rule = NR_CHAR}};
static const Slot SL_PCon[] = {{.rule = FAM_MODPATH},
                               {.rule = FAM_PAT, .lo = 0, .hi = 2}};
static const Slot SL_PCons[] = {{.rule = FAM_PAT}, {.rule = FAM_PAT}};
static const Slot SL_PTuple[] = {{.rule = FAM_PAT, .lo = 2, .hi = 3}};
static const Slot SL_PList[] = {{.rule = FAM_PAT, .lo = 0, .hi = 3}};
static const Slot SL_PAs[] = {{.rule = FAM_PAT}, {.rule = NR_LOWER}};
// `rest` is empty unless the record is OPEN, so the two forms are two shapes
// rather than one shape and a rule that reads its own sibling.
static const Slot SL_PRecord[] = {{.rule = FAM_MODPATH},
                                  {.rule = FAM_FIELDPAT, .lo = 0, .hi = 3},
                                  {.rule = FR_FALSE},
                                  {.rule = NR_EMPTY}};
static const Slot SL_PRecordOpen[] = {{.rule = FAM_MODPATH},
                                      {.rule = FAM_FIELDPAT, .lo = 0, .hi = 2},
                                      {.rule = FR_TRUE},
                                      {.rule = NR_OPTNAME}};
static const Slot SL_FieldPat[] = {{.rule = NR_LOWER}, {.rule = FAM_PAT}};
// The left-hand-side rosters differ from FAM_PAT in exactly one entry each:
// P_Cons and P_As keep their HEAD out of name-leading territory.
static const Slot SL_PConsL[] = {{.rule = FAM_LHSPAT}, {.rule = FAM_PAT}};
static const Slot SL_PAsL[] = {{.rule = FAM_LHSPAT}, {.rule = NR_LOWER}};

// statements ----------------------------------------------------------------
static const Slot SL_SLet[] = {{.rule = FAM_BIND}};
// A `handle` STATEMENT must write its label; only the delimited inline form
// may elide it (P1/D13), which is why NR_ANY and not NR_LABEL.
static const Slot SL_SHandle[] = {{.rule = NR_ANY}, {.rule = FAM_EXPR}};
static const Slot SL_SUse[] = {{.rule = FAM_USEBIND, .lo = 1, .hi = 2}};
static const Slot SL_SDiscard[] = {{.rule = FAM_BODY}};

// binders, alternatives and clauses ------------------------------------------
static const Slot SL_Bind[] = {{.rule = FAM_BINDLHS}, {.rule = FAM_BODY}};
static const Slot SL_Alt[] = {{.rule = FAM_PAT},
                              {.rule = FAM_BODY},
                              {.rule = FAM_SIGEQ, .lo = 0, .hi = 2, .blk = 1}};
// One shape per clause KIND. A CONTROL clause is the one that holds a
// continuation, so `k` is non-empty there and empty everywhere else -- a
// control clause without one is unprintable, and a `k` on any other kind
// would print a comma the parser would then read as a control clause.
// `abort` takes patterns and no continuation; `return` takes exactly one
// pattern and no name; `var` is headed by `=` and takes neither.
static const Slot SL_ClausePlain[] = {{.rule = IR_CONST, .lo = WOK_CLAUSE_PLAIN},
                                      {.rule = NR_LOWER},
                                      {.rule = FAM_PAT, .lo = 0, .hi = 2},
                                      {.rule = NR_EMPTY},
                                      {.rule = FAM_BODY}};
static const Slot SL_ClauseControl[] = {
    {.rule = IR_CONST, .lo = WOK_CLAUSE_CONTROL},
    {.rule = NR_LOWER},
    {.rule = FAM_PAT, .lo = 0, .hi = 2},
    {.rule = NR_LOWER},
    {.rule = FAM_BODY}};
static const Slot SL_ClauseAbort[] = {{.rule = IR_CONST, .lo = WOK_CLAUSE_ABORT},
                                      {.rule = NR_LOWER},
                                      {.rule = FAM_PAT, .lo = 0, .hi = 2},
                                      {.rule = NR_EMPTY},
                                      {.rule = FAM_BODY}};
static const Slot SL_ClauseReturn[] = {
    {.rule = IR_CONST, .lo = WOK_CLAUSE_RETURN},
    {.rule = NR_EMPTY},
    {.rule = FAM_PAT, .lo = 1, .hi = 1},
    {.rule = NR_EMPTY},
    {.rule = FAM_BODY}};
static const Slot SL_ClauseVar[] = {{.rule = IR_CONST, .lo = WOK_CLAUSE_VAR},
                                    {.rule = NR_LOWER},
                                    {.rule = FAM_PAT, .lo = 0, .hi = 0},
                                    {.rule = NR_EMPTY},
                                    {.rule = FAM_BODY}};

// declaration helpers ---------------------------------------------------------
static const Slot SL_SigName[] = {{.rule = NR_DEFNAME},
                                  {.rule = FR_PAREN_OF, .dep = 0}};
static const Slot SL_LPrefix[] = {{.rule = NR_DEFNAME},
                                  {.rule = FR_PAREN_OF, .dep = 0},
                                  {.rule = FAM_PAT, .lo = 0, .hi = 2}};
static const Slot SL_LInfix[] = {{.rule = FAM_INFIXLHS},
                                 {.rule = NR_OPERATOR},
                                 {.rule = FR_BACKTICK_OF, .dep = 1},
                                 {.rule = FAM_PAT}};
static const Slot SL_TyParam[] = {{.rule = NR_LOWER}, {.rule = FR_RANDOM}};
static const Slot SL_FieldType[] = {{.rule = NR_LOWER}, {.rule = FAM_TYPE}};
static const Slot SL_OpSig[] = {{.rule = NR_LOWER}, {.rule = FAM_TYPE}};
static const Slot SL_ForeignMem[] = {{.rule = NR_LOWER},
                                     {.rule = NR_OPTSTRING},
                                     {.rule = FAM_FTYPE}};
// The three constructor forms. A name with no braces takes ATOM types; a name
// with braces takes fields; and the ELIDED record form -- `type T = { x : U64 }`
// -- has no name at all, which is the only thing that empty name means.
static const Slot SL_ConDef[] = {{.rule = NR_UPPER},
                                 {.rule = FAM_TYPE, .lo = 0, .hi = 2},
                                 {.rule = FAM_FIELDTYPE, .lo = 0, .hi = 0},
                                 {.rule = FR_FALSE}};
static const Slot SL_ConDefRec[] = {{.rule = NR_UPPER},
                                    {.rule = FAM_TYPE, .lo = 0, .hi = 0},
                                    {.rule = FAM_FIELDTYPE, .lo = 0, .hi = 3},
                                    {.rule = FR_TRUE}};
static const Slot SL_ConDefElided[] = {{.rule = NR_EMPTY},
                                       {.rule = FAM_TYPE, .lo = 0, .hi = 0},
                                       {.rule = FAM_FIELDTYPE, .lo = 1, .hi = 3},
                                       {.rule = FR_TRUE}};
static const Slot SL_AnyName[] = {{.rule = NR_ANY},
                                  {.rule = FR_UPPER_OF, .dep = 0}};

// declarations ----------------------------------------------------------------
static const Slot SL_DModule[] = {{.rule = FAM_MODPATH}};
static const Slot SL_DImport[] = {{.rule = FAM_MODPATH},
                                  {.rule = FAM_ANYNAME, .lo = 0, .hi = 2},
                                  {.rule = FAM_ANYNAME, .lo = OPT_MAYBE}};
static const Slot SL_DType[] = {{.rule = NR_UPPER},
                                {.rule = FAM_TYPARAM, .lo = 0, .hi = 2},
                                {.rule = FAM_CONDEF, .lo = 1, .hi = 3}};
static const Slot SL_DAlias[] = {{.rule = NR_UPPER},
                                 {.rule = FAM_TYPARAM, .lo = 0, .hi = 2},
                                 {.rule = FAM_TYPE}};
static const Slot SL_DEffect[] = {{.rule = NR_UPPER},
                                  {.rule = FAM_TYPARAM, .lo = 0, .hi = 2},
                                  {.rule = FAM_OPSIG, .lo = 1, .hi = 3,
                                   .blk = 1}};
static const Slot SL_DClass[] = {{.rule = NR_UPPER},
                                 {.rule = FAM_TYPARAM, .lo = 0, .hi = 2},
                                 {.rule = FAM_SIGEQ, .lo = 1, .hi = 3,
                                  .blk = 1}};
static const Slot SL_DInstance[] = {{.rule = FAM_TYPE, .lo = OPT_MAYBE},
                                    {.rule = NR_UPPER},
                                    {.rule = FAM_TYPE, .lo = 0, .hi = 2},
                                    {.rule = FAM_SIGEQ, .lo = 1, .hi = 3,
                                     .blk = 1}};
static const Slot SL_DForeign[] = {{.rule = NR_UPPER},
                                   {.rule = NR_STRING},
                                   {.rule = FAM_FOREIGNMEM, .lo = 1, .hi = 3,
                                    .blk = 1}};
static const Slot SL_DExternType[] = {{.rule = NR_UPPER},
                                      {.rule = FAM_TYPARAM, .lo = 0, .hi = 2}};
// `alpha` is derived from the operator's spelling exactly as H_ChainOp's
// backtick flag is: a name can only have been written as an alphabetic
// operator, a symbol run only as a symbolic one, so a tree carrying the other
// combination prints something that does not read back.
// One shape per associativity and per relation SENSE, in the style the row
// entries and the clause kinds already use: an INT field that selects a
// spelling is a different form, not a random number.
static const Slot SL_DFixityL[] = {{.rule = NR_OPERATOR},
                                   {.rule = FR_BACKTICK_OF, .dep = 0},
                                   {.rule = IR_CONST, .lo = WOK_ASSOC_LEFT},
                                   {.rule = FAM_FIXREL, .lo = 0, .hi = 2}};
static const Slot SL_DFixityR[] = {{.rule = NR_OPERATOR},
                                   {.rule = FR_BACKTICK_OF, .dep = 0},
                                   {.rule = IR_CONST, .lo = WOK_ASSOC_RIGHT},
                                   {.rule = FAM_FIXREL, .lo = 0, .hi = 2}};
static const Slot SL_FixRelT[] = {{.rule = IR_CONST, .lo = WOK_FIXREL_TIGHTER},
                                  {.rule = NR_OPERATOR},
                                  {.rule = FR_BACKTICK_OF, .dep = 1}};
static const Slot SL_FixRelL[] = {{.rule = IR_CONST, .lo = WOK_FIXREL_LOOSER},
                                  {.rule = NR_OPERATOR},
                                  {.rule = FR_BACKTICK_OF, .dep = 1}};
static const Slot SL_DSig[] = {{.rule = FAM_SIGNAME, .lo = 1, .hi = 2},
                               {.rule = FAM_TYPE},
                               {.rule = FR_RANDOM}};
// `extern` is read by parse_decl and nowhere else, so a signature inside a
// `where`, a class body or an instance body can never carry the marker.
static const Slot SL_DSigLocal[] = {{.rule = FAM_SIGNAME, .lo = 1, .hi = 2},
                                    {.rule = FAM_TYPE},
                                    {.rule = FR_FALSE}};
static const Slot SL_DEquation[] = {{.rule = FAM_LHS},
                                    {.rule = FAM_BODY},
                                    {.rule = FAM_SIGEQ, .lo = 0, .hi = 2,
                                     .blk = 1}};
static const Slot SL_WFile[] = {{.rule = FAM_DECL, .lo = 1, .hi = 3}};

#define SHAPE(t, s) {.tag = (t), .slot = (s), .nslot = COUNT(s)}
#define SHAPE0(t) {.tag = (t), .slot = nullptr, .nslot = 0}

static const Shape SH_EXPR[] = {
    // leaves
    SHAPE(E_Var, SL_EVar),   SHAPE(E_Con, SL_ECon),
    SHAPE(E_Int, SL_EInt),   SHAPE(E_Str, SL_EStr),
    SHAPE(E_Char, SL_EChar), SHAPE0(E_Unit),
    SHAPE(E_OpRef, SL_EOpRef),
    // branches
    SHAPE(E_App, SL_EApp),   SHAPE(E_Chain, SL_EChain),
    SHAPE(E_Dot, SL_EDot),   SHAPE(E_Neg, SL_ENeg),
    SHAPE(E_List, SL_EList), SHAPE(E_Tuple, SL_ETuple),
    SHAPE(E_If, SL_EIf),     SHAPE(E_Assign, SL_EAssign),
    SHAPE(E_Record, SL_ERecord), SHAPE(E_HandleIn, SL_EHandleIn),
    SHAPE(E_UseIn, SL_EUseIn), SHAPE(E_Lambda, SL_ELambda),
    SHAPE(E_LetIn, SL_ELetIn), SHAPE(E_Case, SL_ECase),
    SHAPE(E_Handler, SL_EHandler),
    // E_Block is LAST, and FAM_EXPR stops one short of it: an indented block
    // exists only where layout is live. FAM_BODY takes the whole roster.
    SHAPE(E_Block, SL_EBlock),
};
enum { SH_EXPR_LEAF = 7, SH_EXPR_NO_BLOCK = COUNT(SH_EXPR) - 1 };

static const Shape SH_TYPE[] = {
    // leaves
    SHAPE(T_Var, SL_TVar), SHAPE(T_Con, SL_TCon), SHAPE0(T_Unit),
    SHAPE(T_RowArg, SL_TRowArg),
    // branches
    SHAPE(T_App, SL_TApp), SHAPE(T_Fun, SL_TFun), SHAPE(T_Qual, SL_TQual),
    SHAPE(T_With, SL_TWith), SHAPE(T_List, SL_TList),
    SHAPE(T_Tuple, SL_TTuple),
};
enum { SH_TYPE_LEAF = 4 };

// A foreign member's type, which is the only place a transfer may stand.
static const Shape SH_FTYPE[] = {SHAPE(T_Transfer, SL_TTransfer),
                                 SHAPE(T_Fun, SL_TFunF)};

static const Shape SH_PAT[] = {
    // leaves
    SHAPE(P_Var, SL_PVar), SHAPE0(P_Wild), SHAPE(P_Int, SL_PInt),
    SHAPE(P_Str, SL_PStr), SHAPE(P_Char, SL_PChar), SHAPE0(P_Unit),
    // branches
    SHAPE(P_Con, SL_PCon), SHAPE(P_Cons, SL_PCons), SHAPE(P_Tuple, SL_PTuple),
    SHAPE(P_List, SL_PList), SHAPE(P_As, SL_PAs),
    SHAPE(P_Record, SL_PRecord), SHAPE(P_Record, SL_PRecordOpen),
};
enum { SH_PAT_LEAF = 6 };

// A binding's left side is read by parse_bind, which takes the L_Prefix arm on
// ANY leading lowercase name -- so a pattern there must not begin with one.
static const Shape SH_LHSPAT[] = {
    SHAPE0(P_Wild), SHAPE(P_Int, SL_PInt), SHAPE(P_Str, SL_PStr),
    SHAPE(P_Char, SL_PChar), SHAPE0(P_Unit),
    SHAPE(P_Con, SL_PCon), SHAPE(P_Cons, SL_PConsL), SHAPE(P_Tuple, SL_PTuple),
    SHAPE(P_List, SL_PList), SHAPE(P_As, SL_PAsL),
    SHAPE(P_Record, SL_PRecord), SHAPE(P_Record, SL_PRecordOpen),
};
enum { SH_LHSPAT_LEAF = 5 };

static const Shape SH_STMT[] = {
    SHAPE(S_Let, SL_SLet), SHAPE(S_Handle, SL_SHandle),
    SHAPE(S_Use, SL_SUse), SHAPE(S_Discard, SL_SDiscard),
};
static const Shape SH_CLAUSE[] = {
    SHAPE(H_Clause, SL_ClausePlain), SHAPE(H_Clause, SL_ClauseControl),
    SHAPE(H_Clause, SL_ClauseReturn), SHAPE(H_Clause, SL_ClauseVar),
    SHAPE(H_Clause, SL_ClauseAbort),
};
static const Shape SH_CONDEF[] = {SHAPE(H_ConDef, SL_ConDef),
                                  SHAPE(H_ConDef, SL_ConDefRec),
                                  SHAPE(H_ConDef, SL_ConDefElided)};
static const Shape SH_LHS[] = {SHAPE(L_Prefix, SL_LPrefix),
                               SHAPE(L_Infix, SL_LInfix)};
// D_Sig FIRST and alone in the leaf roster: D_Equation's `wheres` is itself a
// FAM_SIGEQ, so a roster that offered it at the depth floor would recurse with
// no budget left to stop it. check_grounded proves the point rather than
// trusting this comment.
static const Shape SH_SIGEQ[] = {SHAPE(D_Sig, SL_DSigLocal),
                                 SHAPE(D_Equation, SL_DEquation)};
static const Shape SH_DECL[] = {
    SHAPE(D_Sig, SL_DSig),           SHAPE(D_Equation, SL_DEquation),
    SHAPE(D_Module, SL_DModule),     SHAPE(D_Import, SL_DImport),
    SHAPE(D_ExternType, SL_DExternType),
    SHAPE(D_Type, SL_DType),         SHAPE(D_Alias, SL_DAlias),
    SHAPE(D_Effect, SL_DEffect),     SHAPE(D_Class, SL_DClass),
    SHAPE(D_Instance, SL_DInstance), SHAPE(D_Foreign, SL_DForeign),
    SHAPE(D_Fixity, SL_DFixityL), SHAPE(D_Fixity, SL_DFixityR),
};
enum { SH_DECL_LEAF = 5 };

static const Shape SH_FIXREL[] = {SHAPE(H_FixRel, SL_FixRelT),
                                  SHAPE(H_FixRel, SL_FixRelL)};

static const Shape SH_CONPATH[] = {SHAPE(E_Con, SL_ECon),
                                   SHAPE(E_Dot, SL_EDotCon)};
static const Shape SH_MODPATH[] = {SHAPE(N_ModPath, SL_ModPath)};
static const Shape SH_CONNAME[] = {SHAPE(N_Name, SL_ConName)};
static const Shape SH_ANYNAME[] = {SHAPE(N_Name, SL_AnyName)};
static const Shape SH_CHAINOP[] = {SHAPE(H_ChainOp, SL_ChainOp)};
static const Shape SH_ROWENTRY[] = {SHAPE(H_RowEntry, SL_RowSlot),
                                    SHAPE(H_RowEntry, SL_RowRole),
                                    SHAPE(H_RowEntry, SL_RowVar)};
static const Shape SH_FIELD[] = {SHAPE(H_Field, SL_Field)};
static const Shape SH_FIELDPAT[] = {SHAPE(H_FieldPat, SL_FieldPat)};
static const Shape SH_USEBIND[] = {SHAPE(H_UseBind, SL_UseBind)};
static const Shape SH_ALT[] = {SHAPE(H_Alt, SL_Alt)};
static const Shape SH_BIND[] = {SHAPE(H_Bind, SL_Bind)};
// parse_bind takes the L_Prefix arm on a bare lowercase name only: the
// bracketed operator form `(+) x = e` is read by parse_lhs, which is the
// EQUATION's left side and not a binding's, so `let (+) = e` is unwritable.
static const Slot SL_BindLhs[] = {{.rule = NR_LOWER},
                                  {.rule = FR_FALSE},
                                  {.rule = FAM_PAT, .lo = 0, .hi = 2}};
static const Shape SH_BINDLHS[] = {SHAPE(L_Prefix, SL_BindLhs)};
// parse_lhs takes the PREFIX arm whenever a lowercase name is followed by
// anything but an operator, so `a as b + c` is read as a prefix equation named
// `a` and never as an infix one. A bare variable is the only name-leading
// pattern that survives on the left of an operator.
static const Shape SH_INFIXLHS[] = {SHAPE(P_Var, SL_PVar)};
static const Shape SH_SIGNAME[] = {SHAPE(H_SigName, SL_SigName)};
static const Shape SH_TYPARAM[] = {SHAPE(H_TyParam, SL_TyParam)};
static const Shape SH_FIELDTYPE[] = {SHAPE(H_FieldType, SL_FieldType)};
static const Shape SH_OPSIG[] = {SHAPE(H_OpSig, SL_OpSig)};
static const Shape SH_FOREIGNMEM[] = {SHAPE(H_ForeignMember, SL_ForeignMem)};
static const Shape SH_FILE[] = {SHAPE(W_File, SL_WFile)};

#define NOFB .fallback = FAM_COUNT

// The helper families carry no recursion of their own: their expression and
// type children are drawn one generation down like any other, so listing them
// as leaves is what keeps the depth floor reachable.
static const Family family[FAM_COUNT] = {
    [FAM_EXPR] = {SH_EXPR, SH_EXPR_NO_BLOCK, SH_EXPR_LEAF, NOFB},
    [FAM_BODY] = {SH_EXPR, COUNT(SH_EXPR), SH_EXPR_LEAF, NOFB},
    [FAM_TYPE] = {SH_TYPE, COUNT(SH_TYPE), SH_TYPE_LEAF, NOFB},
    [FAM_FTYPE] = {SH_FTYPE, COUNT(SH_FTYPE), 1, .fallback = FAM_TYPE},
    [FAM_PAT] = {SH_PAT, COUNT(SH_PAT), SH_PAT_LEAF, NOFB},
    [FAM_LHSPAT] = {SH_LHSPAT, COUNT(SH_LHSPAT), SH_LHSPAT_LEAF, NOFB},
    [FAM_INFIXLHS] = {SH_INFIXLHS, 1, 1, .fallback = FAM_LHSPAT},
    [FAM_CONPATH] = {SH_CONPATH, COUNT(SH_CONPATH), 1, NOFB},
    [FAM_MODPATH] = {SH_MODPATH, 1, 1, NOFB},
    [FAM_CONNAME] = {SH_CONNAME, 1, 1, NOFB},
    [FAM_ANYNAME] = {SH_ANYNAME, 1, 1, NOFB},
    [FAM_CHAINOP] = {SH_CHAINOP, 1, 1, NOFB},
    [FAM_ROWENTRY] = {SH_ROWENTRY, COUNT(SH_ROWENTRY), 1, NOFB},
    [FAM_FIXREL] = {SH_FIXREL, COUNT(SH_FIXREL), COUNT(SH_FIXREL), NOFB},
    [FAM_FIELD] = {SH_FIELD, 1, 1, NOFB},
    [FAM_FIELDPAT] = {SH_FIELDPAT, 1, 1, NOFB},
    [FAM_USEBIND] = {SH_USEBIND, 1, 1, NOFB},
    [FAM_STMT] = {SH_STMT, COUNT(SH_STMT), COUNT(SH_STMT),
                  .fallback = FAM_EXPR},
    [FAM_ALT] = {SH_ALT, 1, 1, NOFB},
    [FAM_CLAUSE] = {SH_CLAUSE, COUNT(SH_CLAUSE), COUNT(SH_CLAUSE), NOFB},
    [FAM_BIND] = {SH_BIND, 1, 1, NOFB},
    [FAM_BINDLHS] = {SH_BINDLHS, 1, 1, .fallback = FAM_LHSPAT},
    [FAM_LHS] = {SH_LHS, COUNT(SH_LHS), COUNT(SH_LHS), NOFB},
    [FAM_SIGNAME] = {SH_SIGNAME, 1, 1, NOFB},
    [FAM_TYPARAM] = {SH_TYPARAM, 1, 1, NOFB},
    [FAM_CONDEF] = {SH_CONDEF, COUNT(SH_CONDEF), COUNT(SH_CONDEF), NOFB},
    [FAM_FIELDTYPE] = {SH_FIELDTYPE, 1, 1, NOFB},
    [FAM_OPSIG] = {SH_OPSIG, 1, 1, NOFB},
    [FAM_FOREIGNMEM] = {SH_FOREIGNMEM, 1, 1, NOFB},
    [FAM_SIGEQ] = {SH_SIGEQ, COUNT(SH_SIGEQ), 1, NOFB},
    [FAM_DECL] = {SH_DECL, COUNT(SH_DECL), SH_DECL_LEAF, NOFB},
    [FAM_FILE] = {SH_FILE, 1, 1, NOFB},
};

// ------------------------------------------------------------- the builder

typedef struct {
  WokArena *a;
  const Pool *p;
  Rng rng;
  // MINIMUM mode: take the first choice at every decision, so `gen(fam, 0)`
  // yields the smallest well-formed node of that family -- shape 0, atom 0,
  // sequences at their floor, every option absent. That node is what the
  // shrinker puts in a slot it wants to empty, and having the generator
  // produce it means the shrinker cannot invent a shape the tables forbid.
  bool min;
} Gen;

static WokNode *gen(Gen *g, Fam fam, u32 depth, bool flat);

// The three decision points, so MINIMUM mode is stated once rather than at
// every call. `choose` picks an index, `chance` a 1-in-n option, `omit` an
// absent OPT -- and a minimum tree takes 0, false and absent.
static u32 choose(Gen *g, u32 n) { return g->min ? 0u : rng_below(&g->rng, n); }
static bool chance(Gen *g, u32 n) {
  return !g->min && rng_below(&g->rng, n) == 0;
}
static bool omit(Gen *g) { return g->min || rng_below(&g->rng, 3) == 0; }

static WokSpan pick(Gen *g, Atoms a) { return a.span[choose(g, a.n)]; }

static WokSpan gen_name(Gen *g, const Slot *sl, const WokNode *n) {
  switch ((NameRule)sl->rule) {
    case NR_LOWER: return pick(g, g->p->lower);
    case NR_UPPER: return pick(g, g->p->upper);
    case NR_ANY: return choose(g, 2) == 0 ? pick(g, g->p->lower)
                                          : pick(g, g->p->upper);
    case NR_LABEL:
      // The delimited inline `handle` MAY elide its label (D13 two-tier), and
      // an elided one is the smaller tree, so MINIMUM mode takes it.
      if (g->min || rng_below(&g->rng, 3) == 0) return wok_span(0, 0);
      return rng_bool(&g->rng) ? pick(g, g->p->lower) : pick(g, g->p->upper);
    case NR_OPERATOR:
      return chance(g, 4) ? pick(g, g->p->opword) : pick(g, g->p->opsym);
    case NR_OPSYM: return pick(g, g->p->opsym);
    case NR_STRING: return pick(g, g->p->string);
    case NR_CHAR: return pick(g, g->p->chr);
    case NR_EMPTY: return wok_span(0, 0);
    case NR_OPTNAME:
      if (g->min || rng_below(&g->rng, 3) == 0) return wok_span(0, 0);
      return pick(g, g->p->lower);
    case NR_OPTSTRING:
      if (g->min || rng_below(&g->rng, 3) == 0) return wok_span(0, 0);
      return pick(g, g->p->string);
    case NR_DEFNAME:
      // A name being defined may be an OPERATOR, which is written in brackets
      // on both sides of the `=`. The bracket is not grouping, so it IS stored
      // -- and the flag beside it is derived from this spelling.
      return chance(g, 4) ? pick(g, g->p->opsym) : pick(g, g->p->lower);
  }
  (void)n;
  WOK_UNREACHABLE();
}

static const u64 TRANSFERS[] = {WOK_TRANSFER_OWN, WOK_TRANSFER_LEND,
                                WOK_TRANSFER_COPY};

static u64 gen_int(Gen *g, const Slot *sl) {
  switch ((IntRule)sl->rule) {
    case IR_VALUE: return A_INT[choose(g, COUNT(A_INT))];
    case IR_TRANSFER: return TRANSFERS[choose(g, COUNT(TRANSFERS))];
    case IR_CONST: return sl->lo;
  }
  WOK_UNREACHABLE();
}

// The three DERIVED flags re-read the spelling beside them exactly as the
// printer does (decision 5), so a bit that disagrees with its own spelling is
// a tree no round trip can survive. See invariant 9.
// A flag with no freedom in it: what the spelling in `dep` forces it to be.
// Split out so the VALIDATOR can ask the same question of a finished tree that
// the builder asked when it filled the slot.
WOK_READONLY static bool derived_flag(const Pool *p, const Slot *sl,
                                      const WokNode *n) {
  WokSpan s = n->slot[sl->dep].span;
  unsigned char c0 = s.len != 0 ? (unsigned char)p->src[s.off] : 0;
  bool alpha = (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') ||
               c0 == '_' || c0 >= 0x80;
  switch ((FlagRule)sl->rule) {
    case FR_UPPER_OF: return c0 >= 'A' && c0 <= 'Z';
    case FR_BACKTICK_OF: return alpha;
    case FR_PAREN_OF: return !alpha;  // an operator name wears its brackets
    case FR_RANDOM:
    case FR_FALSE:
    case FR_TRUE:
      break;
  }
  WOK_UNREACHABLE();
}

WOK_READONLY static bool flag_is_derived(const Slot *sl) {
  FlagRule r = (FlagRule)sl->rule;
  return r == FR_UPPER_OF || r == FR_BACKTICK_OF || r == FR_PAREN_OF;
}

static bool gen_flag(Gen *g, const Slot *sl, const WokNode *n) {
  // The undecided three answer without looking at a sibling at all, and MUST
  // be answered first: `dep` is meaningless for them, so slot 0 -- which for
  // most nodes is a CHILD POINTER -- would be read as a span.
  switch ((FlagRule)sl->rule) {
    case FR_RANDOM: return !g->min && rng_bool(&g->rng);
    case FR_FALSE: return false;
    case FR_TRUE: return true;
    case FR_UPPER_OF:
    case FR_BACKTICK_OF:
    case FR_PAREN_OF:
      break;
  }
  return derived_flag(g->p, sl, n);
}

enum { GEN_SEQ_MAX = 3, SHR_DEPTH_MAX = 64 };

static WokSeq gen_seq(Gen *g, const Slot *sl, u32 depth, bool flat) {
  u32 hi = sl->hi;
  // Inside brackets an indented block has no items to hold but one: L2
  // suppressed every layout token between them, so the parser could only ever
  // have built a one-item block there, and p_seq_block says so.
  u32 lo = sl->lo;
  if (flat && sl->blk != 0) {
    // At most ONE item -- but a sequence whose floor is zero may still be
    // empty: no block was written at all, which is a different thing from a
    // block with one item in it.
    hi = lo > 0u ? lo : 1u;
  }
  // At the depth FLOOR a sequence takes its floor and nothing more. Without
  // this the budget bounds only NODE children: an optional sequence could
  // still draw an item, that item's leaf shape could draw another, and tree
  // depth would be a coin-flip tail rather than GEN_DEPTH. check_grounded
  // proves the floor terminates, and this is what makes the floor a floor.
  u32 n = depth == 0 ? lo : lo + choose(g, hi > lo ? hi - lo + 1u : 1u);
  if (n == 0) return wok_seq_empty();
  WokNode *items[GEN_SEQ_MAX];
  for (u32 i = 0; i < n && i < COUNT(items); i++)
    items[i] = gen(g, (Fam)sl->rule, depth, flat);
  return wok_seq(g->a, items, n < COUNT(items) ? n : COUNT(items));
}

static WokNode *build(Gen *g, const Shape *s, u32 depth, bool flat) {
  WokNode *n = wok_node(g->a, (WokTag)s->tag, 0, 0);
  u32 cd = depth != 0 ? depth - 1 : 0;
  const WokNodeDesc *d = &wok_node_desc[s->tag];
  // Fields are filled in DECLARATION order, which is what lets a derived flag
  // read the spelling the schema already declared before it.
  for (u16 i = 0; i < d->nfields; i++) {
    const Slot *sl = &s->slot[i];
    bool cf = flat || sl->flat != 0;  // the block rule; `flat` only ever spreads
    switch (d->fields[i].cls) {
      case WFC_NODE:
        n->slot[i] = WOK_MK_NODE(gen(g, (Fam)sl->rule, cd, cf));
        break;
      case WFC_OPT: {
        bool take = sl->lo == OPT_ALWAYS ||
                    (sl->lo == OPT_MAYBE && !omit(g));
        n->slot[i] = WOK_MK_OPT(take ? gen(g, (Fam)sl->rule, cd, cf) : nullptr);
        break;
      }
      case WFC_SEQ:
        n->slot[i] = WOK_MK_SEQ(gen_seq(g, sl, cd, cf));
        break;
      case WFC_NAME:
        n->slot[i] = WOK_MK_NAME(gen_name(g, sl, n));
        break;
      case WFC_TEXT:
        n->slot[i] = WOK_MK_TEXT(gen_name(g, sl, n));
        break;
      case WFC_INT:
        n->slot[i] = WOK_MK_INT(gen_int(g, sl));
        break;
      case WFC_FLAG:
        n->slot[i] = WOK_MK_FLAG(gen_flag(g, sl, n));
        break;
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  return n;
}

// Where a family CONTAINS another, the two rosters are drawn from together: a
// block item is an S_* or any expression, and the choice is made once over the
// whole chain rather than by tossing at each link.
static Fam fam_last(Fam fam) {
  while (family[fam].fallback != FAM_COUNT) fam = (Fam)family[fam].fallback;
  return fam;
}

// Is anything drawn for `child` also legal where `slot` is demanded? Two ways
// to be, and the second is why this is not just a fallback walk: FAM_BODY
// contains FAM_EXPR by sharing its ROSTER and taking more of it (the extra is
// E_Block), not by naming it as a fallback. Read from the table, so a family
// that later gains that relation gets it here for free.
//
// The shrinker's HOIST needs this. Without it an `if` buried in the scrutinee
// of a `case` that sits in a BODY slot cannot come out -- the case's scrutinee
// slot says EXPR, the body slot says BODY, and an equality test calls them
// unrelated. That leaves a counterexample bigger than the one the reader gets
// shown, which is the one thing the shrinker exists to prevent.
static bool fam_accepts(Fam slot, Fam child) {
  for (Fam f = slot; f != FAM_COUNT; f = (Fam)family[f].fallback)
    if (f == child) return true;
  return family[slot].shape == family[child].shape &&
         family[slot].nshape >= family[child].nshape;
}

static const Shape *pick_shape(Gen *g, Fam fam, u32 depth) {
  // The MINIMUM of a chain lives at its far end: a block item's smallest form
  // is not the smallest STATEMENT but the smallest expression it falls back to.
  if (g->min) return &family[fam_last(fam)].shape[0];
  const Shape *chain[64];
  u32 nchain = 0;
  for (Fam f = fam; f != FAM_COUNT; f = (Fam)family[f].fallback) {
    u32 n = depth == 0 ? family[f].nleaf : family[f].nshape;
    for (u32 i = 0; i < n && nchain < COUNT(chain); i++)
      chain[nchain++] = &family[f].shape[i];
  }
  return chain[choose(g, nchain)];
}

static WokNode *gen(Gen *g, Fam fam, u32 depth, bool flat) {
  // An indented block stands only where layout is live, so a slot the printer
  // writes inside brackets takes the expression roster without E_Block.
  if (fam == FAM_BODY && flat) fam = FAM_EXPR;
  return build(g, pick_shape(g, fam, depth), depth, flat);
}

// The smallest well-formed node of `fam`. It runs on a Gen of its own so that
// asking for one never advances the sweep's rng: tree i must stay a pure
// function of its seed however many minimums the shrinker asks for.
static WokNode *gen_min(WokArena *a, const Pool *p, Fam fam) {
  Gen g = {.a = a, .p = p, .rng = {.s = 0}, .min = true};
  return gen(&g, fam, 0, true);
}

// Which shape built this node. A tag is unique WITHIN a family, so knowing the
// family a slot demands is enough to recover the rules its occupant was built
// under -- which is what lets the shrinker walk a finished tree and still know
// what each slot will accept. Null for the wrapper nodes, which no family
// lists and the shrinker leaves alone.
// A tag is NOT unique within a family once a node has several forms -- four
// clause kinds, three row entries, three constructor forms, an open and a
// closed record. They are told apart by the very fields that define them: the
// constants the shape fixes must be the ones the node carries.
static bool shape_fits(const Shape *s, const WokNode *n) {
  const WokNodeDesc *d = &wok_node_desc[s->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    const Slot *sl = &s->slot[i];
    switch (d->fields[i].cls) {
      case WFC_INT:
        if (sl->rule == IR_CONST && n->slot[i].num != sl->lo) return false;
        break;
      case WFC_FLAG:
        if (sl->rule == FR_TRUE && !n->slot[i].flag) return false;
        if (sl->rule == FR_FALSE && n->slot[i].flag) return false;
        break;
      case WFC_NAME:
      case WFC_TEXT: {
        // Both directions. H_ConDef's record form and its ELIDED record form
        // differ only in whether the name is there, so a rule that demands a
        // name must reject an absent one or the elided form matches the wrong
        // shape and the shrinker then works from the wrong slot rules.
        bool may_be_empty = sl->rule == NR_EMPTY || sl->rule == NR_LABEL ||
                            sl->rule == NR_OPTNAME || sl->rule == NR_OPTSTRING;
        bool empty = n->slot[i].span.len == 0;
        if (sl->rule == NR_EMPTY && !empty) return false;
        if (!may_be_empty && empty) return false;
        break;
      }
      case WFC_NODE:
      case WFC_OPT:
      case WFC_SEQ:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  return true;
}

static const Shape *shape_of(Fam fam, const WokNode *n) {
  for (Fam f = fam; f != FAM_COUNT; f = (Fam)family[f].fallback)
    for (u32 i = 0; i < family[f].nshape; i++)
      if (family[f].shape[i].tag == n->tag && shape_fits(&family[f].shape[i], n))
        return &family[f].shape[i];
  return nullptr;
}

// ------------------------------------------------------------ the validator
//
// Is this tree one the TABLES describe? Generation produces such trees by
// construction, but SHRINKING rewrites finished slots, and a move that writes
// something the tables forbid hands the printer a shape it was never built to
// meet. That is not hypothetical: emptying an OPT the shape declares always
// present segfaulted wok_print's H_RowEntry arm, which writes the field
// unconditionally.
//
// So the tables get a reader as well as a writer, and the shrinker checks
// itself against it before the printer ever sees a candidate. Everything the
// builder decides is something this can re-ask:
//
//   - the slot holds a node of a family the shape accepts;
//   - an option is present exactly when its OptMode says it must be;
//   - a sequence is within the bounds the table records;
//   - a constant field carries its constant, an empty name is empty, and a
//     name that must be spelled is spelled;
//   - a DERIVED flag still agrees with the spelling beside it (invariant 9);
//   - and THE BLOCK RULE: `flat` spreads downward exactly as it does in
//     build(), so an E_Block in a bracketed body slot is refused here too.

static bool node_valid(const Pool *p, const WokNode *n, Fam fam, bool flat,
                       char *why, usize why_n, u32 depth);

static bool bad(char *why, usize why_n, const WokNode *n, const char *field,
                const char *what) {
  snprintf(why, why_n, "%s.%s %s", wok_node_desc[n->tag].tag, field, what);
  return false;
}

static bool node_valid(const Pool *p, const WokNode *n, Fam fam, bool flat,
                       char *why, usize why_n, u32 depth) {
  if (depth >= SHR_DEPTH_MAX) return true;  // deeper than any table can build
  // THE BLOCK RULE, asked of a finished tree exactly as gen() asks it of a
  // slot about to be filled. An E_Block inside brackets is a tree the printer
  // flattens and the parser can never rebuild, so a move that relocated one
  // into a bracketed position would be a silent corruption rather than a
  // caught one.
  if (fam == FAM_BODY && flat) fam = FAM_EXPR;
  const Shape *sh = shape_of(fam, n);
  if (sh == nullptr) {
    snprintf(why, why_n, "%s stands where %s is wanted, and no shape fits it",
             wok_node_desc[n->tag].tag, wok_family_name(
                 wok_node_desc[family[fam_last(fam)].shape[0].tag].family));
    return false;
  }
  const WokNodeDesc *d = &wok_node_desc[n->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    const Slot *sl = &sh->slot[i];
    const char *fname = d->fields[i].name;
    bool cf = flat || sl->flat != 0;  // `flat` only ever spreads, as in build()
    switch (d->fields[i].cls) {
      case WFC_NODE:
        if (n->slot[i].node == nullptr)
          return bad(why, why_n, n, fname, "is null, and NODE is required");
        if (!node_valid(p, n->slot[i].node, (Fam)sl->rule, cf, why, why_n,
                        depth + 1))
          return false;
        break;
      case WFC_OPT: {
        bool have = n->slot[i].node != nullptr;
        if (!have && (OptMode)sl->lo == OPT_ALWAYS)
          return bad(why, why_n, n, fname, "is absent, and this form needs it");
        if (have && (OptMode)sl->lo == OPT_NEVER)
          return bad(why, why_n, n, fname, "is present, and this form has none");
        if (have && !node_valid(p, n->slot[i].node, (Fam)sl->rule, cf, why,
                                why_n, depth + 1))
          return false;
        break;
      }
      case WFC_SEQ: {
        WokSeq q = wok_seq_unpack(n->slot[i].seq);
        if (q.n < sl->lo || q.n > sl->hi)
          return bad(why, why_n, n, fname, "is outside the bounds it declares");
        for (u32 k = 0; k < q.n; k++)
          if (!node_valid(p, q.items[k], (Fam)sl->rule, cf, why, why_n,
                          depth + 1))
            return false;
        break;
      }
      case WFC_NAME:
      case WFC_TEXT: {
        bool empty = n->slot[i].span.len == 0;
        NameRule r = (NameRule)sl->rule;
        if (r == NR_EMPTY && !empty)
          return bad(why, why_n, n, fname, "is spelled, and this form elides it");
        bool optional = r == NR_EMPTY || r == NR_LABEL || r == NR_OPTNAME ||
                        r == NR_OPTSTRING;
        if (!optional && empty)
          return bad(why, why_n, n, fname, "is empty, and this form spells it");
        break;
      }
      case WFC_INT:
        if ((IntRule)sl->rule == IR_CONST && n->slot[i].num != sl->lo)
          return bad(why, why_n, n, fname, "does not carry its form's constant");
        break;
      case WFC_FLAG:
        if (flag_is_derived(sl) && n->slot[i].flag != derived_flag(p, sl, n))
          return bad(why, why_n, n, fname,
                     "disagrees with the spelling it is derived from");
        break;
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  return true;
}

static bool tree_valid(const Pool *p, const WokNode *file, char *why,
                       usize why_n) {
  return node_valid(p, file, FAM_FILE, false, why, why_n, 0);
}


// The whole file is one family now -- W_File holds declarations like any other
// node holds children -- so there is no hand-written wrapper left. Layout is
// live at the top level, so the root is not flat.
static WokNode *gen_file(Gen *g, u32 depth) {
  return gen(g, FAM_FILE, depth, false);
}

// ------------------------------------------------------------- properties

// Property 4. The output is known to be well formed, so the bracket invariant
// is checked in its strict form, exactly as test_print checks it.
static bool layout_ok(const char *text, usize n, WokArena *a, char *err,
                      usize err_n) {
  WokDiagSink *d = wok_diag_new(a, "<generated>", text, n);
  WokScanResult scanned = wok_scan(text, n, a, d);
  WokTokens out = wok_layout(scanned.tokens, a, d);
  return wok_layout_check(out, scanned.tokens.n, true, err, err_n);
}

// What one tree exercised, whatever the verdict.
typedef struct {
  unsigned overflow;  // over-width lines the printer reported
  unsigned wrapped;   // 1 when the line filler broke a line at all
} Reach;

// WHICH property failed, rather than a message about it. The shrinker needs
// this: a minimiser that accepts any failure at all will happily drift from
// the bug you found to a different one and report a counterexample for
// neither, so every candidate has to reproduce the SAME property.
typedef enum : u8 {
  PROP_OK = 0,
  PROP_NO_DUMP,
  PROP_LATCH,     // 5 -- a break that would have changed the tree
  PROP_DIAG,      // 3 -- the printed text does not parse cleanly
  PROP_TREE,      // 1 -- the load-bearing one
  PROP_FIXPOINT,  // 2
  PROP_LAYOUT,    // 4
  PROP_READBACK,      // 6 -- the dump does not survive the STRICT reader
  PROP_UNPRINTABLE,   // 7 -- a node the printer says has no canonical form
  PROP_COUNT
} Prop;

static const char *const prop_text[PROP_COUNT] = {
    [PROP_OK] = "every property holds",
    [PROP_NO_DUMP] = "the generated tree has no dump",
    [PROP_LATCH] = "the printer's safety latch fired",
    [PROP_DIAG] = "the printed text does not parse cleanly",
    [PROP_TREE] = "PRINTING CHANGED THE TREE",
    [PROP_FIXPOINT] = "the formatter is not a fixed point",
    [PROP_LAYOUT] = "a layout invariant is broken",
    [PROP_READBACK] = "the dump did not read back",
    [PROP_UNPRINTABLE] = "the printer found a node with no canonical form",
};

// `verbose` renders the diagnostics and the texts; the sweep runs quiet so a
// failure at tree 4000 is not buried under 4000 lines of nothing.
static Prop check_tree(const WokNode *file, const Pool *p, WokArena *a,
                       bool verbose, Reach *reach) {
  char *dump1 = wok_sexpr_dump_string(file, p->src, a);
  if (dump1 == nullptr) return PROP_NO_DUMP;

  wok_print_reports_reset();
  char *text = wok_print_string_named(file, p->src, a, "<generated>");
  usize text_n = strlen(text);

  // One declaration takes exactly one line unless the FILLER broke it, so this
  // is the whole of "line filling was reached", which is what this slice is
  // scoped around in the first place.
  reach->wrapped =
      (text_n > 1 && memchr(text, '\n', text_n - 1) != nullptr) ? 1u : 0u;

  // Property 7 -- every generated tree is one the printer can WRITE. The two
  // error nodes are the only shapes that fail this, and generation cannot
  // build them by construction, so this asserts the refusal is reserved for
  // them: any other unprintable node is a table that has drifted from the
  // printer.
  if (wok_print_unprintable_count() != 0) {
    if (verbose) fprintf(stderr, "--- printed ---\n%s---\n", text);
    return PROP_UNPRINTABLE;
  }

  // Property 5 -- a fill break that would have changed the tree rather than
  // the text. The latch is process-wide, so it is read before anything else
  // prints.
  if (wok_print_fault_count() != 0) {
    if (verbose) fprintf(stderr, "--- printed ---\n%s---\n", text);
    return PROP_LATCH;
  }

  WokDiagSink *d = wok_diag_new(a, "<generated>", text, text_n);
  WokNode *back = wok_parse_source(text, text_n, a, d);

  // Property 3.
  if (wok_diag_count(d) != 0) {
    if (verbose) {
      wok_diag_render(d, stderr);
      fprintf(stderr, "--- printed ---\n%s---\n", text);
    }
    return PROP_DIAG;
  }

  // Property 1 -- the load-bearing one.
  char *dump2 = wok_sexpr_dump_string(back, text, a);
  if (dump2 == nullptr || strcmp(dump1, dump2) != 0) {
    if (verbose)
      fprintf(stderr, "--- printed ---\n%s--- want ---\n%s\n--- got ---\n%s\n",
              text, dump1, dump2 ? dump2 : "(none)");
    return PROP_TREE;
  }

  // Property 2.
  char *text2 = wok_print_string_named(back, text, a, "<generated>");
  if (strcmp(text, text2) != 0) {
    if (verbose)
      fprintf(stderr, "--- first ---\n%s--- second ---\n%s---\n", text, text2);
    return PROP_FIXPOINT;
  }

  // Property 4.
  char err[256] = {0};
  if (!layout_ok(text, text_n, a, err, sizeof err)) {
    if (verbose)
      fprintf(stderr, "%s\n--- printed ---\n%s---\n", err, text);
    return PROP_LAYOUT;
  }

  // Property 6 -- the dump survives the reader, which since G4 checks the
  // FAMILY of every child against the schema. That makes this sweep the thing
  // that exercises the 96 family annotations: a wrong one is a tree the
  // generator builds happily and the reader then refuses.
  WokDiagSink *rd = wok_diag_new(a, "<dump>", dump1, strlen(dump1));
  const char *pool = nullptr;
  WokNode *reread = wok_sexpr_read(dump1, strlen(dump1), a, rd, &pool);
  if (reread == nullptr) {
    if (verbose) {
      wok_diag_render(rd, stderr);
      fprintf(stderr, "--- the dump ---\n%s\n", dump1);
    }
    return PROP_READBACK;
  }
  char *dump3 = wok_sexpr_dump_string(reread, pool, a);
  if (dump3 == nullptr || strcmp(dump1, dump3) != 0) {
    if (verbose)
      fprintf(stderr, "--- want ---\n%s\n--- got ---\n%s\n", dump1,
              dump3 ? dump3 : "(none)");
    return PROP_READBACK;
  }
  return PROP_OK;
}

// ---------------------------------------------------------- tag coverage
//
// A table typo silently narrows the space rather than failing, so what the
// sweep actually REACHED is counted -- generically, off the descriptors, the
// same walk the dump and the reader use.

static void mark_tags(const WokNode *n, bool *seen) {
  seen[n->tag] = true;
  const WokNodeDesc *d = &wok_node_desc[n->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    switch (d->fields[i].cls) {
      case WFC_NODE:
        mark_tags(n->slot[i].node, seen);
        break;
      case WFC_OPT:
        if (n->slot[i].node != nullptr) mark_tags(n->slot[i].node, seen);
        break;
      case WFC_SEQ: {
        WokSeq s = wok_seq_unpack(n->slot[i].seq);
        for (u32 k = 0; k < s.n; k++) mark_tags(s.items[k], seen);
        break;
      }
      case WFC_NAME:
      case WFC_TEXT:
      case WFC_INT:
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
}

static u32 count_nodes(const WokNode *n) {
  u32 total = 1;
  const WokNodeDesc *d = &wok_node_desc[n->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    switch (d->fields[i].cls) {
      case WFC_NODE:
        total += count_nodes(n->slot[i].node);
        break;
      case WFC_OPT:
        if (n->slot[i].node != nullptr) total += count_nodes(n->slot[i].node);
        break;
      case WFC_SEQ: {
        WokSeq s = wok_seq_unpack(n->slot[i].seq);
        for (u32 k = 0; k < s.n; k++) total += count_nodes(s.items[k]);
        break;
      }
      case WFC_NAME:
      case WFC_TEXT:
      case WFC_INT:
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  return total;
}

// --------------------------------------------------------------- shrinking
//
// A forty-node counterexample is a puzzle; nobody acts on one. Minimising
// first turns it into a bug report.
//
// Shrinking works on the TREE and never on the text. That is not a
// convenience: a text-level minimiser would drop a bracket, and dropping a
// bracket does not make a program smaller, it makes it a DIFFERENT program.
// `(-a) b` and `-a b` are both four nodes and only one of them reproduces.
// Every move below rewrites one slot with something the family table already
// permits, so no move can re-associate anything.
//
// The moves, in the order they are tried -- biggest reduction first, and the
// walk is pre-order so shallow slots are reached before deep ones:
//
//   1. empty an OPT
//   2. HOIST: replace a node with one of its own children of the same family
//   3. replace a node with the family's MINIMUM
//   4. drop one element of a sequence, down to the floor the table records
//   5. step an atom back to the first in its pool
//
// Move 5 keeps to the pool the atom already came from -- a lowercase name
// shrinks to a lowercase name -- because E_Dot.upper and H_ChainOp.backtick
// are derived from the spelling beside them (invariant 9). Staying inside the
// pool keeps those bits true without the shrinker having to know about them.

typedef bool (*StillFails)(const WokNode *file, void *ctx);

typedef enum : u8 { SITE_NODE, SITE_SEQ, SITE_NAME, SITE_INT } SiteKind;

typedef struct {
  WokNode *owner;
  u8 slot;
  u8 kind;  // SiteKind
  u8 rule;  // Fam for NODE and SEQ, NameRule for NAME, IntRule for INT
  u8 lo;    // the sequence floor, from the family table
} Site;

enum {
  SHR_SITES_MAX = 1024,
  SHR_STEPS_MAX = 20000,  // property checks per counterexample
};

typedef struct {
  Site site[SHR_SITES_MAX];
  u32 n;
} Sites;

// One pre-order walk, carrying the family each node belongs to -- which is
// what makes its shape, and so its slots' rules, recoverable.
static void collect(Sites *s, WokNode *owner, Fam fam, u32 depth) {
  if (depth >= SHR_DEPTH_MAX) return;
  const Shape *sh = shape_of(fam, owner);
  if (sh == nullptr) return;
  const WokNodeDesc *d = &wok_node_desc[owner->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    const Slot *sl = &sh->slot[i];
    if (s->n >= SHR_SITES_MAX) return;
    Site site = {.owner = owner, .slot = (u8)i, .rule = sl->rule, .lo = sl->lo};
    switch (d->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT:
        site.kind = SITE_NODE;
        s->site[s->n++] = site;
        if (owner->slot[i].node != nullptr)
          collect(s, owner->slot[i].node, (Fam)sl->rule, depth + 1);
        break;
      case WFC_SEQ: {
        site.kind = SITE_SEQ;
        s->site[s->n++] = site;
        WokSeq q = wok_seq_unpack(owner->slot[i].seq);
        for (u32 k = 0; k < q.n; k++)
          collect(s, q.items[k], (Fam)sl->rule, depth + 1);
        break;
      }
      case WFC_NAME:
      case WFC_TEXT:
        site.kind = SITE_NAME;
        s->site[s->n++] = site;
        break;
      case WFC_INT:
        site.kind = SITE_INT;
        s->site[s->n++] = site;
        break;
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;  // derived from a sibling; never shrunk on its own
    }
  }
}

// The whole file is a family now, so the root walk is the ordinary one.
static void collect_root(Sites *s, WokNode *file) {
  s->n = 0;
  collect(s, file, FAM_FILE, 0);
}

// A sequence with one element removed. Bounded by the longest the tables can
// ask for, which check_tables pins.
static WokSeq seq_without(WokArena *a, WokSeq q, u32 drop) {
  WokNode *items[GEN_SEQ_MAX];
  u32 m = 0;
  for (u32 i = 0; i < q.n; i++)
    if (i != drop && m < COUNT(items)) items[m++] = q.items[i];
  return wok_seq(a, items, m);
}

// The first atom of the pool this one already came from. Staying inside the
// pool is what keeps the derived flags true without the shrinker knowing they
// exist: a lowercase name shrinks to a lowercase name, a symbolic operator to
// a symbolic one.
static WokSpan atom_min(const Pool *p, NameRule rule, WokSpan cur) {
  unsigned char c0 = cur.len != 0 ? (unsigned char)p->src[cur.off] : 0;
  bool upper = c0 >= 'A' && c0 <= 'Z';
  switch (rule) {
    case NR_LOWER: return p->lower.span[0];
    case NR_UPPER: return p->upper.span[0];
    case NR_ANY: return upper ? p->upper.span[0] : p->lower.span[0];
    case NR_LABEL: return wok_span(0, 0);  // an elided label is legal here
    case NR_EMPTY: return cur;             // already the smallest there is
    case NR_OPTNAME: return wok_span(0, 0);
    case NR_OPTSTRING: return wok_span(0, 0);
    case NR_DEFNAME:
      // A defined name wears brackets exactly when it is symbolic, and the
      // flag beside it is derived from that, so the two pools do not mix.
      return c0 == 0 || upper || (c0 >= 'a' && c0 <= 'z') || c0 == '_'
                 ? p->lower.span[0]
                 : p->opsym.span[0];
    case NR_OPERATOR: {
      bool alpha = (c0 >= 'a' && c0 <= 'z') || upper || c0 == '_' || c0 >= 0x80;
      return alpha ? p->opword.span[0] : p->opsym.span[0];
    }
    case NR_OPSYM: return p->opsym.span[0];
    case NR_STRING: return p->string.span[0];
    case NR_CHAR: return p->chr.span[0];
  }
  WOK_UNREACHABLE();
}

// Two tiers, and picking the wrong one is what -Wformat-truncation keeps
// catching:
//
//   WHY_CAP     -- a raw explanation, as tree_valid writes it.
//   SHR_WHY_CAP -- a SHRINKER REPORT: one of those plus the wrapper below.
//
// Anything that receives Shr::why, directly or through shrink()'s out-param,
// needs the second. Sizing such a buffer at WHY_CAP is not a near miss; it
// silently loses the tail of the only text that explains the failure.
enum { WHY_CAP = 192 };

// The wrapper Shr puts around a quoted explanation. Spelled once, as a macro,
// and pasted into the format string at the use site -- so the size below and
// the text actually written can never disagree.
#define SHR_WHY_WRAP "a tree the tables forbid: "

// Sized from the wrapper plus a FULL inner explanation, rather than a round
// number picked by hand: at 192 the tail was silently dropped, in precisely
// the report that exists to explain a failure. `sizeof` on the literal counts
// its NUL, which is the byte the result needs anyway.
enum { SHR_WHY_CAP = WHY_CAP + sizeof SHR_WHY_WRAP };

typedef struct {
  const Pool *pool;
  WokArena *a;
  StillFails fails;
  void *ctx;
  unsigned steps;
  // AUDIT mode: apply every candidate, check it, keep none. It reuses the move
  // generation below rather than restating it, so the audit cannot drift from
  // the shrinker it is auditing.
  bool audit;
  unsigned audited;
  int broke;
  // The FIRST breakage, reported by the caller once the printer's own chatter
  // is out of the way.
  char why[SHR_WHY_CAP];
} Shr;

// The other message Shr writes is a bare literal, so it cannot be truncated
// by a long argument -- but it can be made longer by an editor. Pin it.
static_assert(sizeof "a candidate that trips the latch" <= SHR_WHY_CAP,
              "Shr::why must hold every message written into it");


// Writes `v` into the slot, tests, and keeps it only if the failure survived.
static bool try_slot(Shr *s, WokNode *file, WokNode *owner, u8 slot,
                     WokSlot v) {
  if (s->steps >= SHR_STEPS_MAX) return false;
  WokSlot saved = owner->slot[slot];
  owner->slot[slot] = v;
  s->steps++;

  // The tables get the first look, ALWAYS. A move that writes something they
  // forbid is a shrinker bug, and handing it to the printer is how that bug
  // becomes a segfault inside the very pass that was meant to explain a
  // failure. Checked in both modes: in audit it is the whole point, and in a
  // real shrink it is the guard that keeps a report from becoming a crash.
  char why[WHY_CAP];
  bool ok = tree_valid(s->pool, file, why, sizeof why);
  if (!ok) {
    if (s->broke == 0)
      snprintf(s->why, sizeof s->why, SHR_WHY_WRAP "%s", why);
    s->broke++;
  }
  if (s->audit) {
    s->audited++;
    if (ok) {
      // A well-formed tree must also PRINT without tripping the safety latch;
      // that is property 5, asked of a shape the shrinker invented rather than
      // one the generator chose.
      wok_print_reports_reset();
      (void)wok_print_string_named(file, s->pool->src, s->a, "<audit>");
      if (wok_print_fault_count() != 0) {
        if (s->broke == 0)
          snprintf(s->why, sizeof s->why, "a candidate that trips the latch");
        s->broke++;
      }
    }
    owner->slot[slot] = saved;
    return false;  // keep nothing, so the walk reaches every candidate
  }
  if (ok && s->fails(file, s->ctx)) return true;
  owner->slot[slot] = saved;
  return false;
}

// Every accepted move strictly reduces either the node count or an atom's
// distance from the front of its pool, so this terminates on its own; the step
// cap is a backstop, not the argument.
static bool shrink_site(Shr *s, WokNode *file, const Site *st) {
  WokNode *owner = st->owner;
  u8 i = st->slot;
  switch ((SiteKind)st->kind) {
    case SITE_NODE: {
      WokNode *cur = owner->slot[i].node;
      if (cur == nullptr) return false;
      // Emptying an OPT is legal only where the SHAPE says the option is a
      // choice. H_RowEntry.type is declared OPT by the schema and OPT_ALWAYS
      // by the slot obligation and the role, and the printer writes it
      // unconditionally -- so nulling it segfaults the very pass the shrinker
      // is running. The Site already carries the mode; read it.
      bool droppable = wok_node_desc[owner->tag].fields[i].cls == WFC_OPT &&
                       (OptMode)st->lo == OPT_MAYBE;
      if (droppable && try_slot(s, file, owner, i, WOK_MK_OPT(nullptr)))
        return true;

      // HOIST: any child of `cur` that the same family accepts can stand in
      // its place, which keeps the failing sub-structure and drops everything
      // around it. This is the move that carries an `if` down to its condition.
      const Shape *sh = shape_of((Fam)st->rule, cur);
      if (sh != nullptr) {
        const WokNodeDesc *d = &wok_node_desc[cur->tag];
        for (u16 k = 0; k < d->nfields; k++) {
          if (!fam_accepts((Fam)st->rule, (Fam)sh->slot[k].rule)) continue;
          switch (d->fields[k].cls) {
            case WFC_NODE:
            case WFC_OPT:
              if (cur->slot[k].node != nullptr &&
                  try_slot(s, file, owner, i, WOK_MK_NODE(cur->slot[k].node)))
                return true;
              break;
            case WFC_SEQ: {
              WokSeq q = wok_seq_unpack(cur->slot[k].seq);
              for (u32 e = 0; e < q.n; e++)
                if (try_slot(s, file, owner, i, WOK_MK_NODE(q.items[e])))
                  return true;
              break;
            }
            case WFC_NAME:
            case WFC_TEXT:
            case WFC_INT:
            case WFC_FLAG:
            case WOK_FIELD_CLASS_COUNT:
              break;
          }
        }
      }

      // The family's MINIMUM. Taken when it is smaller, and also when it is
      // the same size under a different tag -- `'c'` and `a` are both one
      // node, but a reader of `-a a` does not have to wonder whether the
      // literal mattered. The tag test is what stops that swap repeating.
      WokNode *small = gen_min(s->a, s->pool, (Fam)st->rule);
      u32 ns = count_nodes(small), nc = count_nodes(cur);
      if ((ns < nc || (ns == nc && small->tag != cur->tag)) &&
          try_slot(s, file, owner, i, WOK_MK_NODE(small)))
        return true;
      return false;
    }
    case SITE_SEQ: {
      WokSeq q = wok_seq_unpack(owner->slot[i].seq);
      if (q.n <= st->lo) return false;
      for (u32 k = 0; k < q.n; k++)
        if (try_slot(s, file, owner, i,
                     WOK_MK_SEQ(seq_without(s->a, q, k))))
          return true;
      return false;
    }
    case SITE_NAME: {
      WokSpan cur = owner->slot[i].span;
      WokSpan want = atom_min(s->pool, (NameRule)st->rule, cur);
      if (want.off == cur.off && want.len == cur.len) return false;
      return try_slot(s, file, owner, i, WOK_MK_NAME(want));
    }
    case SITE_INT:
      // A row kind governs its own label and type, so moving it would need
      // both re-derived. Only a literal's value shrinks.
      if ((IntRule)st->rule != IR_VALUE || owner->slot[i].num == A_INT[0])
        return false;
      return try_slot(s, file, owner, i, WOK_MK_INT(A_INT[0]));
  }
  WOK_UNREACHABLE();
}

// Greedy to a fixed point: rescan after every accepted move, because a move
// orphans the sites inside whatever it replaced.
static unsigned shrink(WokNode *file, const Pool *pool, WokArena *a,
                       StillFails fails, void *ctx, int *broke, char *why,
                       usize why_n) {
  Shr s = {.pool = pool, .a = a, .fails = fails, .ctx = ctx, .steps = 0};
  Sites sites;  // a local, so the shrinker holds no more static state than
                // the generator it was built to accompany
  for (bool moved = true; moved && s.steps < SHR_STEPS_MAX;) {
    moved = false;
    collect_root(&sites, file);
    for (u32 i = 0; i < sites.n; i++)
      if (shrink_site(&s, file, &sites.site[i])) {
        moved = true;
        break;
      }
  }
  *broke = s.broke;
  if (s.broke != 0) snprintf(why, why_n, "%s", s.why);
  return s.steps;
}

// This file's families REFINE the schema's; they may never contradict them.
// The schema says D_Equation.body takes an EXPR; this file narrows that to
// "an expression, and E_Block only where layout is live". Narrowing is the
// point. Widening -- letting a slot take a family the schema does not accept --
// would generate trees the strict reader refuses, so it is caught here, at
// startup, rather than 3,000 trees into a sweep.
//
// This is what makes adding a node to wok_ast.h safe: get the family wrong in
// either place and the two disagree out loud.
static int check_refines(const Shape *s, u16 slot, Fam local) {
  WokFamily want = wok_node_desc[s->tag].fields[slot].family;
  int bad = 0;
  for (Fam f = local; f != FAM_COUNT; f = (Fam)family[f].fallback)
    for (u32 i = 0; i < family[f].nshape; i++) {
      WokFamily got = wok_node_desc[family[f].shape[i].tag].family;
      if (wok_family_accepts(want, got)) continue;
      fprintf(stderr,
              "  FAIL %s.%s takes %s, but this file offers %s, which is %s\n",
              wok_node_desc[s->tag].tag,
              wok_node_desc[s->tag].fields[slot].name, wok_family_name(want),
              wok_node_desc[family[f].shape[i].tag].tag,
              wok_family_name(got));
      bad++;
    }
  return bad;
}

// THE DEPTH FLOOR MUST BOTTOM OUT. At depth 0 a family is drawn from its LEAF
// roster and its children are drawn at depth 0 too, so a leaf shape that
// requires a family whose own leaves require it back recurses with no budget
// left to stop it -- unbounded trees at some seeds, and green at others, which
// is the worst way for a generator to be wrong.
//
// Least fixed point: a family is GROUNDED once every one of its leaf shapes
// requires only grounded families. Anything still unmarked when that stops
// growing is a roster that cannot terminate, and it is named here rather than
// discovered by a user seed.
static int check_grounded(void) {
  bool grounded[FAM_COUNT] = {false};
  for (bool moved = true; moved;) {
    moved = false;
    for (u32 f = 0; f < FAM_COUNT; f++) {
      if (grounded[f]) continue;
      bool all = true;
      for (Fam c = (Fam)f; c != FAM_COUNT && all; c = (Fam)family[c].fallback)
        for (u32 i = 0; i < family[c].nleaf && all; i++) {
          const Shape *sh = &family[c].shape[i];
          const WokNodeDesc *d = &wok_node_desc[sh->tag];
          for (u16 k = 0; k < d->nfields && all; k++) {
            // Only the children a leaf shape CANNOT omit can hold it up.
            bool required =
                d->fields[k].cls == WFC_NODE ||
                (d->fields[k].cls == WFC_OPT && sh->slot[k].lo == OPT_ALWAYS) ||
                (d->fields[k].cls == WFC_SEQ && sh->slot[k].lo > 0);
            if (required && !grounded[sh->slot[k].rule]) all = false;
          }
        }
      if (all) grounded[f] = moved = true;
    }
  }
  int bad = 0;
  for (u32 f = 0; f < FAM_COUNT; f++)
    if (!grounded[f]) {
      fprintf(stderr, "  FAIL family %u cannot bottom out at the depth floor\n",
              f);
      bad++;
    }
  return bad;
}

// The shapes claim a slot count; the SCHEMA owns it. A field added to a node
// in wok_ast.h must fail here rather than leave a slot silently zeroed.
// ARITY FIRST, and nothing else until it holds. Every check below walks a
// shape's slot array against the SCHEMA's field list, so a shape that declares
// the wrong number of slots makes all of them read out of bounds -- including
// check_grounded, which exists to make exactly this edit (a field added to
// wok_ast.h) safe. It would be the first thing to break on the edit it guards.
static int check_arity(void) {
  int bad = 0;
  for (u32 f = 0; f < FAM_COUNT; f++)
    for (u32 i = 0; i < family[f].nshape; i++) {
      const Shape *s = &family[f].shape[i];
      if (s->tag >= WOK_TAG_COUNT) {
        fprintf(stderr, "  FAIL family %u shape %u has tag %u\n", f, i,
                (unsigned)s->tag);
        bad++;
      } else if (s->nslot != wok_node_desc[s->tag].nfields) {
        fprintf(stderr, "  FAIL %s: shape declares %u slots, schema says %u\n",
                wok_node_desc[s->tag].tag, s->nslot,
                wok_node_desc[s->tag].nfields);
        bad++;
      }
    }
  return bad;
}

static int check_tables(void) {
  // Nothing that indexes a slot array may run until the arities agree.
  int bad = check_arity();
  if (bad != 0) return bad;

  bad += check_grounded();
  // The block rule is POSITIONAL: FAM_EXPR is the expression roster one entry
  // shorter, so reordering SH_EXPR would silently exclude the wrong node.
  if (SH_EXPR[SH_EXPR_NO_BLOCK].tag != E_Block) {
    fprintf(stderr, "  FAIL the body-only roster excludes %s, not E_Block\n",
            wok_node_desc[SH_EXPR[SH_EXPR_NO_BLOCK].tag].tag);
    bad++;
  }
  // A fallback chain must terminate, and inside FAM_COUNT steps.
  for (u32 f0 = 0; f0 < FAM_COUNT; f0++) {
    u32 f = f0, steps = 0;
    while (family[f].fallback != FAM_COUNT && steps++ < FAM_COUNT)
      f = family[f].fallback;
    if (steps >= FAM_COUNT) {
      fprintf(stderr, "  FAIL family %u has a cyclic fallback chain\n", f0);
      bad++;
    }
  }
  for (u32 f = 0; f < FAM_COUNT; f++) {
    const Family *fm = &family[f];
    if (fm->nleaf == 0 || fm->nleaf > fm->nshape) {
      fprintf(stderr, "  FAIL family %u: %u leaf shapes of %u\n", f,
              fm->nleaf, fm->nshape);
      bad++;
    }
    for (u32 i = 0; i < fm->nshape; i++) {
      const Shape *s = &fm->shape[i];
      // Bounded by nfields, which check_arity has just proved equals nslot.
      for (u16 k = 0; k < wok_node_desc[s->tag].nfields; k++) {
        const WokFieldDesc *fd = &wok_node_desc[s->tag].fields[k];
        if (fd->cls == WFC_NODE || fd->cls == WFC_OPT || fd->cls == WFC_SEQ)
          bad += check_refines(s, k, (Fam)s->slot[k].rule);
        if (fd->cls == WFC_SEQ &&
            (s->slot[k].hi < s->slot[k].lo || s->slot[k].hi > GEN_SEQ_MAX)) {
          fprintf(stderr, "  FAIL %s.%s: sequence bounds %u..%u\n",
                  wok_node_desc[s->tag].tag, fd->name, s->slot[k].lo,
                  s->slot[k].hi);
          bad++;
        }
      }
    }
  }
  return bad;
}

// A sanitizer writes its report to stderr and then aborts, so under `make
// sanitize` the hush would swallow the one message worth having and leave only
// an exit code. The noise is the cheaper of the two costs there.
#if defined(__SANITIZE_ADDRESS__)
#  define WOK_GEN_HUSH 0
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer) || __has_feature(undefined_behavior_sanitizer)
#    define WOK_GEN_HUSH 0
#  else
#    define WOK_GEN_HUSH 1
#  endif
#else
#  define WOK_GEN_HUSH 1
#endif

typedef struct {
  int saved;
} Hush;

static Hush hush_begin(void) {
  Hush h = {.saved = -1};
  if (!WOK_GEN_HUSH) return h;
  int devnull = open("/dev/null", O_WRONLY);
  if (devnull < 0) return h;
  (void)fflush(stderr);
  h.saved = dup(STDERR_FILENO);
  if (h.saved >= 0) (void)dup2(devnull, STDERR_FILENO);
  (void)close(devnull);
  return h;
}

static void hush_end(Hush *h) {
  if (h->saved < 0) return;
  (void)fflush(stderr);
  (void)dup2(h->saved, STDERR_FILENO);
  (void)close(h->saved);
  h->saved = -1;
}

// ------------------------------------------------------- the shrinker's own
//
// A shrinker is only ever exercised on the day something breaks, which is the
// worst possible day to discover it has decayed into a no-op. So it is tested
// here against a SYNTHETIC property -- "this tree contains an E_If" -- which
// needs no bug to hold. The moves, the backtracking and the convergence are
// the same ones a real counterexample uses; only the predicate differs.
//
// The floor is 7 nodes: W_File, D_Equation, L_Prefix, E_If and the three
// minimum expressions the family hands back for its condition and branches.

static bool has_tag(const WokNode *n, u16 tag) {
  if (n->tag == tag) return true;
  const WokNodeDesc *d = &wok_node_desc[n->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    switch (d->fields[i].cls) {
      case WFC_NODE:
        if (has_tag(n->slot[i].node, tag)) return true;
        break;
      case WFC_OPT:
        if (n->slot[i].node != nullptr && has_tag(n->slot[i].node, tag))
          return true;
        break;
      case WFC_SEQ: {
        WokSeq s = wok_seq_unpack(n->slot[i].seq);
        for (u32 k = 0; k < s.n; k++)
          if (has_tag(s.items[k], tag)) return true;
        break;
      }
      case WFC_NAME:
      case WFC_TEXT:
      case WFC_INT:
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  return false;
}

static bool holds_an_if(const WokNode *file, void *ctx) {
  (void)ctx;
  return has_tag(file, E_If);
}

enum { SHR_SELFTEST_MAX = 10 };  // the spec's own number

// THE SECOND HALF OF THE SHRINKER'S OWN TEST. The one below checks that it
// SHRINKS; this checks that every move it could make is LEGAL -- which is the
// gap that let it empty an always-present option and segfault the printer.
// Audit mode applies each candidate, checks it against the tables, prints it,
// and puts it back, so the moves under test are the real ones.
static int shrink_audit(const Pool *pool) {
  unsigned audited = 0;
  int broke = 0;
  char why[SHR_WHY_CAP] = {0};
  Hush h = hush_begin();  // the printer reports every over-width line, and an
                          // audit prints thousands of candidates
  for (u32 i = 0; i < 200; i++) {
    WokArena *a = wok_arena_new(1 << 15);
    Gen g = {.a = a, .p = pool, .rng = {.s = (u64)GEN_SEED + i}};
    WokNode *file = gen_file(&g, GEN_DEPTH);
    Shr s = {.pool = pool, .a = a, .fails = nullptr, .ctx = nullptr,
             .steps = 0, .audit = true, .audited = 0, .broke = 0};
    Sites sites;
    collect_root(&sites, file);
    for (u32 k = 0; k < sites.n; k++) (void)shrink_site(&s, file, &sites.site[k]);
    audited += s.audited;
    if (s.broke != 0 && broke == 0)
      snprintf(why, sizeof why, "%s", s.why);
    broke += s.broke;
    wok_arena_free(a);
    if (broke) break;
  }
  hush_end(&h);
  if (broke != 0)
    fprintf(stderr, "  FAIL shrink audit: %d illegal candidate(s): %s\n",
            broke, why);
  if (broke == 0 && audited < 1000) {
    fprintf(stderr, "  FAIL shrink audit only reached %u candidates\n", audited);
    return 1;
  }
  return broke;
}

static int shrink_selftest(const Pool *pool) {
  for (u32 i = 0; i < GEN_TREES; i++) {
    WokArena *a = wok_arena_new(1 << 15);
    Gen g = {.a = a, .p = pool, .rng = {.s = (u64)GEN_SEED + i}};
    WokNode *file = gen_file(&g, GEN_DEPTH);
    u32 before = count_nodes(file);
    // Something worth shrinking: an `if` buried in a tree many times its size.
    if (!has_tag(file, E_If) || before < 25) {
      wok_arena_free(a);
      continue;
    }
    int sbroke = 0;
    char swhy[SHR_WHY_CAP] = {0};
    (void)shrink(file, pool, a, holds_an_if, nullptr, &sbroke, swhy,
                 sizeof swhy);
    u32 after = count_nodes(file);
    int bad = 0;
    if (!has_tag(file, E_If)) {
      fprintf(stderr, "  FAIL shrink dropped the very thing it minimised for\n");
      bad = 1;
    } else if (after > SHR_SELFTEST_MAX) {
      char *dump = wok_sexpr_dump_string(file, pool->src, a);
      fprintf(stderr, "  FAIL shrink stopped at %u nodes, wanted %u or fewer\n%s\n",
              after, (unsigned)SHR_SELFTEST_MAX, dump ? dump : "");
      bad = 1;
    }
    wok_arena_free(a);
    return bad;
  }
  fprintf(stderr, "  FAIL no tree big enough to shrink; the sweep is too small\n");
  return 1;
}

// ------------------------------------------------------------------- main
//
// The printer REPORTS every over-width line, and every one of them is
// legitimate: an unbreakable run -- a juxtaposition, a literal, a name -- has
// no other text, and saying so is the printer's stated contract. A sweep this
// size produces hundreds of kilobytes of them, which would bury the one line
// that matters, so the quiet pass sends them to /dev/null and COUNTS them
// instead. The re-run from a seed leaves stderr alone.

// The predicate the shrinker minimises against: the SAME property, failing
// again, on a scratch arena of its own so a candidate leaves nothing behind.
typedef struct {
  const Pool *pool;
  Prop target;
} SameFailure;

static bool same_failure(const WokNode *file, void *vctx) {
  const SameFailure *c = vctx;
  WokArena *a = wok_arena_new(1 << 14);
  Reach r = {.overflow = 0, .wrapped = 0};
  Prop p = check_tree(file, c->pool, a, false, &r);
  wok_arena_free(a);
  return p == c->target;
}

static Prop run_one(u64 seed, const Pool *pool, bool verbose, bool *seen,
                    Reach *total) {
  WokArena *a = wok_arena_new(1 << 15);
  Gen g = {.a = a, .p = pool, .rng = {.s = seed}};
  WokNode *file = gen_file(&g, GEN_DEPTH);
  if (seen != nullptr) mark_tags(file, seen);

  Reach reach = {.overflow = 0, .wrapped = 0};
  Prop prop = check_tree(file, pool, a, verbose, &reach);
  // check_tree reset the latch on entry, so it now holds this tree's total.
  reach.overflow = wok_print_overflow_count();
  total->overflow += reach.overflow;
  total->wrapped += reach.wrapped;

  if (prop != PROP_OK && verbose) {
    // MINIMISE BEFORE REPORTING. The reduced tree's dump is the durable
    // reproducer, not the seed: a seed only means anything against the exact
    // roster that produced it, and the rosters move between slices. This dump
    // reads straight back through wok_sexpr_read.
    u32 before = count_nodes(file);
    SameFailure ctx = {.pool = pool, .target = prop};
    int broke = 0;
    char bwhy[SHR_WHY_CAP] = {0};
    unsigned steps = shrink(file, pool, a, same_failure, &ctx, &broke, bwhy,
                            sizeof bwhy);
    if (broke != 0)
      fprintf(stderr, "  FAIL the shrinker proposed %d illegal move(s): %s\n",
              broke, bwhy);
    char *dump = wok_sexpr_dump_string(file, pool->src, a);
    char *text = wok_print_string_named(file, pool->src, a, "<minimal>");
    fprintf(stderr,
            "--- minimised: %u nodes -> %u, in %u candidates ---\n%s\n"
            "--- it prints as ---\n%s---\n",
            before, count_nodes(file), steps, dump ? dump : "(no dump)", text);
  }
  wok_arena_free(a);
  return prop;
}

int main(int argc, char **argv) {
  WokArena *pool_arena = wok_arena_new(1 << 12);
  Pool pool = pool_build(pool_arena);

  if (check_tables() != 0 || shrink_selftest(&pool) != 0 ||
      shrink_audit(&pool) != 0) {
    wok_arena_free(pool_arena);
    return 1;
  }

  // `./test_generative <seed>` rebuilds exactly the tree a failure named, and
  // reports it in full. This is the whole of the reproduction mechanism.
  Reach total = {.overflow = 0, .wrapped = 0};
  if (argc > 1) {
    u64 seed = strtoull(argv[1], nullptr, 0);
    Prop prop = run_one(seed, &pool, true, nullptr, &total);
    if (prop != PROP_OK) {
      fprintf(stderr, "seed %llu: %s\n", (unsigned long long)seed,
              prop_text[prop]);
      wok_arena_free(pool_arena);
      return 1;
    }
    printf("seed %llu: every property holds\n", (unsigned long long)seed);
    wok_arena_free(pool_arena);
    return 0;
  }

  bool seen[WOK_TAG_COUNT] = {false};
  unsigned long failed = 0;
  Hush h = hush_begin();
  for (u32 i = 0; i < GEN_TREES; i++) {
    u64 seed = (u64)GEN_SEED + i;
    Prop prop = run_one(seed, &pool, false, seen, &total);
    if (prop == PROP_OK) continue;
    hush_end(&h);
    fprintf(stderr, "  FAIL seed %llu: %s\n", (unsigned long long)seed,
            prop_text[prop]);
    // Minimise before reporting. Regenerating from the seed rather than
    // threading the tree out is free -- generation is a pure function of it --
    // and it keeps the shrink and its report outside the hush, where they can
    // actually be read.
    Reach ignore = {.overflow = 0, .wrapped = 0};
    (void)run_one(seed, &pool, true, nullptr, &ignore);
    fprintf(stderr, "       reproduce with: ./build/test/test_generative %llu\n",
            (unsigned long long)seed);
    if (++failed > 4) break;
    h = hush_begin();
  }
  hush_end(&h);

  // THE G3 GATE: every tag in the schema, reached by GENERATION ALONE, with no
  // corpus. The two error nodes are the exception and cannot be otherwise --
  // they mark DAMAGE, no well-formed program holds one, and the printer refuses
  // them by design ("a damaged declaration cannot be written in canonical
  // form"). 80 of 82 is the ceiling, and it is a statement about the schema
  // rather than about this test.
  unsigned missing = 0;
  for (u32 t = 0; t < WOK_TAG_COUNT; t++) {
    if (seen[t] || t == D_Error || t == E_Error) continue;
    fprintf(stderr, "  FAIL %s was never generated\n", wok_node_desc[t].tag);
    missing++;
  }

  wok_arena_free(pool_arena);

  if (failed != 0 || missing != 0) {
    fprintf(stderr, "generative: %lu failure(s), %u unreached shape(s)\n",
            failed, missing);
    return 1;
  }
  unsigned reached = 0;
  for (u32 t = 0; t < WOK_TAG_COUNT; t++)
    if (seen[t]) reached++;
  printf("generative: %d trees, seven properties hold; %u/%d tags reached from "
         "generation alone; %u wrapped, %u over-width lines\n",
         GEN_TREES, reached, WOK_TAG_COUNT, total.wrapped, total.overflow);
  return 0;
}

// ------------------------------------------- the invariants this had to know
//
// Every one of these lives in wok_parse.c today and nowhere else. The schema
// records a field's class; none of it records these. They are the real output
// of this slice, and the cost of the next one.
//
//  1. T_Tuple and E_Tuple need at least TWO items: parse_atomtype and
//     parse_atom both collapse a one-element bracket group to the element, so
//     a one-item tuple is a tree no parse produces and no print survives.
//  2. E_Chain needs at least ONE operator; parse_chain returns the bare head
//     otherwise.
//  3. T_With needs at least one row entry, E_UseIn at least one bridge,
//     N_ModPath at least one part, D_Sig at least one name.
//  4. Every N_ModPath part is a CONID: parse_modpath extends the path only
//     while the token after the dot is uppercase.
//  5. H_RowEntry is a three-way node whose other two fields are governed by
//     its kind -- a SLOT has an EMPTY label, a row VAR has a null type, and a
//     ROLE has both. Nothing in the schema ties the three together.
//  6. An E_Record head must be a constructor atom (E_Con, or an E_Dot whose
//     projected name is uppercase); parse_atom attaches `{` to nothing else.
//  7. E_OpRef holds a strictly SYMBOLIC operator: `(f)` is a parenthesised
//     variable, not a section.
//  8. An operator spelling may not be a reserved run (`=`, `:`, `|`, `->`,
//     `=>`, `::`, `:=`) nor two or more dashes, which scans as a comment.
//  9. E_Dot.upper and H_ChainOp.backtick are REDUNDANT with the spellings
//     beside them. The printer re-derives both (decision 5), so a tree whose
//     bit disagrees with its own spelling prints one way and parses back the
//     other. G4's families do NOT close this one: a family says which kind of
//     CHILD a slot takes, and this is a flag that must agree with a sibling
//     SPELLING. It stays the generator's job, in gen_flag.
// 10. A literal's TEXT span is its SPELLING, quotes and escapes included, not
//     its value.
//
// The patterns, statements, clauses and declarations added another eight, and
// six of the eight are the same shape of fact: a production the parser reaches
// only from ONE caller, so the node it builds cannot stand where an identical
// node built elsewhere can.
//
// 11. THE BLOCK RULE. E_Block stands only where parse_body is called, and only
//     where layout is live. Inside brackets L2 suppresses every layout token,
//     so the parser could never have built one there -- and a seq block that
//     IS inside brackets holds exactly one item, for the same reason.
// 12. `extern` is read by parse_decl alone, so a signature in a `where`, a
//     class body or an instance body can never carry the marker.
// 13. parse_bind takes its L_Prefix arm on a bare lowercase name only. The
//     bracketed operator form `(+) x = e` belongs to parse_lhs, which is an
//     EQUATION's left side, so `let (+) = e` is unwritable.
// 14. A binding's left side may not BEGIN with a lowercase name unless it is
//     exactly that name: parse_bind reads `x as y = e` as a prefix definition
//     of `x` and then finds no `=`.
// 15. The same rule decides an infix equation. parse_lhs takes the prefix arm
//     whenever a name is followed by anything but an operator, so a BARE
//     variable is the only name-leading pattern that survives on the left of
//     one.
// 16. H_Clause is a FIVE-way node, and `k` is what the comma buys: a CONTROL
//     clause holds its continuation there and every other kind leaves it
//     empty, `abort` included -- printing a `k` on any other kind would emit
//     a comma the parser reads straight back as a control clause. `return`
//     takes exactly one pattern and no name; `var` is headed by `=` and takes
//     neither patterns nor a continuation. Nothing in the schema ties `kind`
//     to the five, which is why this list has to.
// 17. P_Record.rest is empty unless the record is OPEN, and H_ConDef.name is
//     empty only for the elided record form `type T = { x : U64 }`.
// 18. T_Transfer stands only at the top of a foreign member's type or of an
//     arrow's sides. It swallows the whole application to its right exactly as
//     `-` does in an expression, so a nested one re-associates.
//
// Two things this list deliberately does NOT contain, because they are bugs
// wearing an invariant's clothes -- the parser builds both trees from legal
// source, so the PRINTER is what is wrong:
//
//   - `E_App.fn takes no bare negation`. Found on the first run of G1, from
//     `(-a) b`. Fixed: it became the EP_NEG rung in wok_print.c's ladder.
//   - `an equation's first argument may not begin with a minus`. Found here,
//     from `f (-1) = 2`, which printed as `f -1 = 2` and read back as the
//     infix equation `f - 1 = 2`. Fixed: needs_lead_paren now names TWO
//     positions where a leading `-` is misread, and p_args guards the second.
//
// -------------------------------------------------- what this slice cannot
//
//   - D_Error and E_Error, which mark damage. No well-formed program holds
//     one and the printer refuses them, so 80 of 82 tags is the ceiling.
//   - COMMENTS. wok_trivia attaches them to a parsed tree as side data the
//     dump cannot see, and a generated tree simply has none -- so every
//     comment-placement rule is still the corpus's job, and test_trivia's.
