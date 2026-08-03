// wok_sexpr round-trip and strictness tests.
//
// The tree below is not a valid wok program (D_Error inside a W_File next to
// an H_RowEntry reached through a made-up T_With, for instance) -- it does
// not need to be. It only needs to put at least one instance of every field
// class (and a nullary node) somewhere in the tree the generic walker sees.

#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_diag.h"
#include "../wok_sexpr.h"
#include "check.h"

static WokSpan span_in(const char *src, const char *needle) {
  const char *p = strstr(src, needle);
  return wok_span((u32)(p - src), (u32)strlen(needle));
}

static WokNode *mk_name(WokArena *a, const char *src, const char *word,
                        bool upper) {
  WokNode *n = wok_node(a, N_Name, 0, 0);
  N_Name_set_text(n, span_in(src, word));
  N_Name_set_upper(n, upper);
  return n;
}

// The source buffer every NAME/TEXT span in the tree points into. The tail
// after "err:" is deliberately full of bytes the dumper must escape: a
// backslash, a double quote, a newline, a tab and a low control byte.
static const char SRC[] =
    "Data List L map filter a x foo "
    "err:contains\na newline\tand \"quotes\" and \\backslash and \x01 control";

static WokNode *build_tree(WokArena *a) {
  const char *src = SRC;

  // D_Import: path is a NODE, names is an empty SEQ, alias is a non-null OPT.
  WokNode *modpath = wok_node(a, N_ModPath, 0, 0);
  WokNode *modparts[2] = {mk_name(a, src, "Data", true),
                          mk_name(a, src, "List", true)};
  N_ModPath_set_parts(modpath, wok_seq(a, modparts, 2));

  WokNode *imp = wok_node(a, D_Import, 0, 0);
  D_Import_set_path(imp, modpath);
  D_Import_set_names(imp, wok_seq_empty());
  D_Import_set_alias(imp, mk_name(a, src, "L", true));

  // D_Equation: an INT field (E_Int.value) and another empty SEQ (wheres).
  WokNode *pvar = wok_node(a, P_Var, 0, 0);
  P_Var_set_name(pvar, span_in(src, "x"));

  WokNode *eint = wok_node(a, E_Int, 0, 0);
  E_Int_set_value(eint, 42);

  WokNode *eqn = wok_node(a, D_Equation, 0, 0);
  D_Equation_set_lhs(eqn, pvar);
  D_Equation_set_body(eqn, eint);
  D_Equation_set_wheres(eqn, wok_seq_empty());

  // D_Alias: a non-empty SEQ (params), and a body that reaches a null OPT
  // (H_RowEntry.type) and a nullary node (T_Unit).
  WokNode *hrow = wok_node(a, H_RowEntry, 0, 0);
  H_RowEntry_set_kind(hrow, WOK_ROW_SLOT);
  H_RowEntry_set_label(hrow, span_in(src, "foo"));
  H_RowEntry_set_type(hrow, nullptr);  // OPT, null

  WokNode *tunit = wok_node(a, T_Unit, 0, 0);  // nullary node

  WokNode *twith = wok_node(a, T_With, 0, 0);
  T_With_set_body(twith, tunit);
  WokNode *rowitems[1] = {hrow};
  T_With_set_row(twith, wok_seq(a, rowitems, 1));  // SEQ, non-empty

  WokNode *tparam = wok_node(a, H_TyParam, 0, 0);
  H_TyParam_set_name(tparam, span_in(src, "a"));
  H_TyParam_set_is_row(tparam, false);  // a FLAG that is #f, for variety

  WokNode *alias = wok_node(a, D_Alias, 0, 0);
  D_Alias_set_name(alias, span_in(src, "foo"));
  WokNode *aliasparams[1] = {tparam};
  D_Alias_set_params(alias, wok_seq(a, aliasparams, 1));
  D_Alias_set_body(alias, twith);

  // D_Error: a TEXT field, deliberately loaded with bytes that must be
  // escaped on dump and unescaped exactly on read.
  WokNode *derr = wok_node(a, D_Error, 0, 0);
  D_Error_set_text(
      derr, span_in(src,
                    "contains\na newline\tand \"quotes\" and \\backslash "
                    "and \x01 control"));

  WokNode *decls[4] = {imp, eqn, alias, derr};
  WokNode *file = wok_node(a, W_File, 0, 0);
  W_File_set_decls(file, wok_seq(a, decls, 4));
  return file;
}

// CHECK/TEST_DONE (test/check.h) return out of the enclosing function on
// too many failures, so every check below runs directly in main, in its own
// scoped block, rather than in helper functions.

int main(void) {
  // --- round trip: Dump(Read(Dump(t))) == Dump(t), byte for byte ---------
  {
    WokArena *a = wok_arena_new(1 << 16);
    WokNode *tree = build_tree(a);

    char *dump1 = wok_sexpr_dump_string(tree, SRC, a);
    CHECK(dump1 != nullptr, "dump_string returned null");

    WokDiagSink *diag = wok_diag_new(a, "<sexpr>", dump1, strlen(dump1));
    const char *pool_src = nullptr;
    WokNode *reread = wok_sexpr_read(dump1, strlen(dump1), a, diag, &pool_src);
    CHECK(reread != nullptr, "round-trip read failed: %s",
          wok_diag_count(diag) ? wok_diag_at(diag, 0)->msg
                                : "(no diagnostic)");
    CHECK(pool_src != nullptr, "out_src must be set once the read succeeds");

    if (reread != nullptr && pool_src != nullptr) {
      char *dump2 = wok_sexpr_dump_string(reread, pool_src, a);
      CHECK(dump2 != nullptr, "second dump_string returned null");
      CHECK(
          strcmp(dump1, dump2) == 0,
          "Dump(Read(Dump(t))) != Dump(t):\n--- dump1 ---\n%s\n--- dump2 ---\n%s",
          dump1, dump2);
    }

    wok_arena_free(a);
  }

  // --- strictness: unknown head tag ---------------------------------------
  {
    static const char bad[] = "(Not_A_Real_Tag)";
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *diag = wok_diag_new(a, "<t>", bad, strlen(bad));
    const char *out_src = nullptr;
    WokNode *n = wok_sexpr_read(bad, strlen(bad), a, diag, &out_src);
    CHECK(n == nullptr, "an unknown head tag must be rejected");
    CHECK(wok_diag_count(diag) >= 1,
          "an unknown head tag must report at least one diagnostic");
    wok_arena_free(a);
  }

  // --- strictness: wrong field count --------------------------------------
  {
    // T_Unit is nullary; one extra atom in the list is a wrong field count.
    static const char bad[] = "(T_Unit extra)";
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *diag = wok_diag_new(a, "<t>", bad, strlen(bad));
    const char *out_src = nullptr;
    WokNode *n = wok_sexpr_read(bad, strlen(bad), a, diag, &out_src);
    CHECK(n == nullptr, "a wrong field count must be rejected");
    CHECK(wok_diag_count(diag) >= 1,
          "a wrong field count must report at least one diagnostic");
    wok_arena_free(a);
  }

  // --- strictness: bare word where (seq ...) is required ------------------
  {
    // D_Import's second field (names) is a SEQ; a bare word there is the
    // wrong shape.
    static const char bad[] = "(D_Import (N_ModPath (seq)) foo (none))";
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *diag = wok_diag_new(a, "<t>", bad, strlen(bad));
    const char *out_src = nullptr;
    WokNode *n = wok_sexpr_read(bad, strlen(bad), a, diag, &out_src);
    CHECK(n == nullptr,
          "a bare word where (seq ...) is required must be rejected");
    CHECK(wok_diag_count(diag) >= 1,
          "wrong field shape must report at least one diagnostic");
    wok_arena_free(a);
  }

  // --- strictness: unterminated list ---------------------------------------
  {
    static const char bad[] = "(E_Int 42";  // missing closing paren
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *diag = wok_diag_new(a, "<t>", bad, strlen(bad));
    const char *out_src = nullptr;
    WokNode *n = wok_sexpr_read(bad, strlen(bad), a, diag, &out_src);
    CHECK(n == nullptr, "an unterminated list must be rejected");
    CHECK(wok_diag_count(diag) >= 1,
          "an unterminated list must report at least one diagnostic");
    wok_arena_free(a);
  }

  // --- strictness: unterminated string (bonus, alongside the list case) --
  {
    static const char bad[] = "(D_Error \"never closes)";
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *diag = wok_diag_new(a, "<t>", bad, strlen(bad));
    const char *out_src = nullptr;
    WokNode *n = wok_sexpr_read(bad, strlen(bad), a, diag, &out_src);
    CHECK(n == nullptr, "an unterminated string literal must be rejected");
    CHECK(wok_diag_count(diag) >= 1,
          "an unterminated string literal must report at least one diagnostic");
    wok_arena_free(a);
  }

  TEST_DONE();
}
