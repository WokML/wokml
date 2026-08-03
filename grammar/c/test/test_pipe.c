// `wokfmt --pipe` -- source on stdin, canonical form on stdout.
//
// The property that matters is EQUIVALENCE: `wokfmt --pipe < f` must produce
// byte-identical output to `wokfmt f`, and agree on the exit code, for every
// file in the corpus. Two code paths that can disagree are two formatters, and
// an agent using the fast one would be checking its work against a different
// standard from CI.
//
// This drives the real binary through popen rather than calling the library,
// because the thing under test is the CLI contract: which stream carries the
// payload, which carries the diagnostics, and what the exit code means.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sys/wait.h>

#include "check.h"

#define MAXOUT (1 << 20)

// Runs a command, captures stdout, returns the exit status.
static int run(const char *cmd, char *out, usize cap) {
  FILE *fp = popen(cmd, "r");
  if (!fp) return -1;
  usize n = fread(out, 1, cap - 1, fp);
  out[n] = '\0';
  int st = pclose(fp);
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static char buf_pipe[MAXOUT];
static char buf_file[MAXOUT];

int main(void) {
  // The binary must exist; `make test` depends on it.
  if (run("test -x ./wokfmt && echo y", buf_pipe, sizeof buf_pipe) != 0 ||
      buf_pipe[0] != 'y') {
    fprintf(stderr, "  SKIP: ./wokfmt not built\n");
    return 0;
  }

  const char *dirs[] = {"../../docs/redesign/examples/accept",
                        "../../docs/redesign/examples/reject",
                        "testdata/tour", "testdata/fill"};
  int files = 0;
  for (usize di = 0; di < sizeof dirs / sizeof *dirs; di++) {
    DIR *dp = opendir(dirs[di]);
    if (!dp) continue;
    struct dirent *e;
    while ((e = readdir(dp)) != nullptr) {
      usize len = strlen(e->d_name);
      if (len < 5 || strcmp(e->d_name + len - 4, ".wok") != 0) continue;
      char path[1024], cmd[2048];
      snprintf(path, sizeof path, "%s/%s", dirs[di], e->d_name);

      // EQUIVALENCE: the same bytes out, whichever way the source went in.
      snprintf(cmd, sizeof cmd, "./wokfmt --pipe < '%s' 2>/dev/null", path);
      int rc_pipe = run(cmd, buf_pipe, sizeof buf_pipe);
      snprintf(cmd, sizeof cmd, "./wokfmt '%s' 2>/dev/null", path);
      int rc_file = run(cmd, buf_file, sizeof buf_file);

      CHECK(rc_pipe == rc_file, "%s: exit %d via pipe, %d via file", path,
            rc_pipe, rc_file);
      CHECK(strcmp(buf_pipe, buf_file) == 0,
            "%s: pipe and file produced DIFFERENT text -- two formatters",
            path);

      // --check must agree too. In pipe mode the name is not printed (stdout
      // is the payload channel), so only the code is compared.
      snprintf(cmd, sizeof cmd, "./wokfmt --pipe --check < '%s' 2>/dev/null",
               path);
      int chk_pipe = run(cmd, buf_pipe, sizeof buf_pipe);
      snprintf(cmd, sizeof cmd, "./wokfmt --check '%s' 2>/dev/null", path);
      int chk_file = run(cmd, buf_file, sizeof buf_file);
      CHECK(chk_pipe == chk_file, "%s: --check says %d via pipe, %d via file",
            path, chk_pipe, chk_file);
      CHECK(buf_pipe[0] == '\0',
            "%s: --pipe --check wrote to stdout; the exit code is the answer",
            path);

      // IDEMPOTENCE through the pipe: formatting the formatted text is a
      // no-op, which is what lets an agent apply it without a fixed point.
      snprintf(cmd, sizeof cmd,
               "./wokfmt --pipe < '%s' 2>/dev/null | ./wokfmt --pipe "
               "2>/dev/null",
               path);
      int rc_twice = run(cmd, buf_file, sizeof buf_file);
      snprintf(cmd, sizeof cmd, "./wokfmt --pipe < '%s' 2>/dev/null", path);
      run(cmd, buf_pipe, sizeof buf_pipe);
      CHECK(rc_twice == 0 && strcmp(buf_pipe, buf_file) == 0,
            "%s: formatting twice through the pipe is not a no-op", path);

      files++;
    }
    closedir(dp);
  }
  CHECK(files >= 20, "only %d corpus files exercised", files);

  // ---- the CLI contract -------------------------------------------------
  struct {
    const char *cmd;
    int want;
    bool stdout_empty;
    const char *why;
  } cases[] = {
      {"printf 'module M\\nf x = 1\\n' | ./wokfmt --pipe 2>/dev/null", 0, false,
       "canonical input formats and exits 0"},
      {"printf 'module M\\nf x=1\\n' | ./wokfmt --pipe --check 2>/dev/null", 1,
       true, "gap 0 vs gap 1 is operator spacing, which --check enforces"},
      {"printf 'module M\\nf x = 1\\n' | ./wokfmt --pipe --check 2>/dev/null", 0,
       true, "canonical input passes --check"},
      {"printf 'module M\\nf   x   =   1\\n' | ./wokfmt --pipe --check "
       "2>/dev/null",
       0, true,
       "runs of >=2 spaces are invisible: the alignment exemption, by design"},
      {"printf 'module M\\nf x := 1\\n' | ./wokfmt --pipe 2>/dev/null", 1, true,
       "input that does not parse: nothing on stdout, diagnostics on stderr"},
      {"printf 'module M\\n' | ./wokfmt --pipe -w 2>/dev/null", 2, true,
       "--pipe has no file to write"},
      {"./wokfmt --pipe nosuch.wok 2>/dev/null", 2, true,
       "--pipe reads stdin; naming files too is a mistake"},
      {"printf '' | ./wokfmt --pipe 2>/dev/null", 0, true,
       "empty input is empty output, not a crash"},
  };
  for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
    int rc = run(cases[i].cmd, buf_pipe, sizeof buf_pipe);
    CHECK(rc == cases[i].want, "%s: exit %d, expected %d", cases[i].why, rc,
          cases[i].want);
    if (cases[i].stdout_empty)
      CHECK(buf_pipe[0] == '\0', "%s: stdout should be empty, got %.40s",
            cases[i].why, buf_pipe);
  }

  TEST_DONE();
}
