/*
 * Module:  egtm_worker -- EGTM NIF library
 * Created: 05-APR-2012 20:11
 * Author:  tmr
 *
 * Copyright 2012 Tomas Morstein, IDEA Systems.
 *
 * This program is free software: you can redistribute
 * it and/or modify it under the terms of the GNU Affero
 * General Public License as published by the Free Software
 * Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * This program is distributed in the hope that it will
 * be useful, but WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Affero General
 * Public License for more details.
 *
 * You should have received a copy of the GNU Affero
 * General Public License along with this program.
 * If not, see <http://www.gnu.org/licenses/>.
 */

#include <termios.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#include "erl_nif.h"
#include <gtmxc_types.h>

#define EGTM$BUFLEN        512
#define EGTM$BUFLENBIG   65536

#define NIFARGS \
  ErlNifEnv * env, int argc, const ERL_NIF_TERM argv []
#define NIF(name) \
  ERL_NIF_TERM (name) (NIFARGS)

/* C stack of the YottaDB thread, in kilowords (8 MB on 64-bit) */
#define EGTM$STACK_KW    1024

ERL_NIF_TERM    c_AtomOK;
ERL_NIF_TERM    c_AtomError;

struct termios m_StderrOrig, m_StdinOrig, m_StdoutOrig;

/*
 * All GT.M/YottaDB calls (gtm_init, every call-in, gtm_zstatus and
 * gtm_exit) run on one dedicated thread with a large stack. The NIFs
 * (dirty I/O, so a long M routine never blocks a normal scheduler)
 * hand it one job at a time and wait. Dirty scheduler stacks are far
 * too small for M code, and the call-in API is not thread-safe.
 */
typedef enum { JOB_INIT, JOB_CI, JOB_EXIT, JOB_STOP } job_kind;

typedef struct {
  job_kind     kind;
  const char * name;        /* call-in name */
  const char * sig;         /* argument kinds: 'p'ointer or 'i'nt */
  union { void * p; int i; } a [4];
  gtm_status_t status;
  char       * msg;         /* $ZSTATUS on failure */
  int          msglen;
  int          stage;       /* JOB_INIT: 1 = gtm_init, 2 = m_init failed */
} ydb_job;

ErlNifMutex * m_Lock;       /* serializes callers */
ErlNifMutex * m_JobLock;
ErlNifCond  * m_JobCond;
ydb_job     * m_Job;
bool          m_JobDone;
ErlNifTid     m_Thread;
bool          m_ThreadUp;

static gtm_status_t run_ci (ydb_job * j) {

  const char * s = j->sig;
  if (!strcmp (s, ""))     return gtm_ci (j->name);
  if (!strcmp (s, "p"))    return gtm_ci (j->name, j->a[0].p);
  if (!strcmp (s, "pp"))   return gtm_ci (j->name, j->a[0].p, j->a[1].p);
  if (!strcmp (s, "ppi"))  return gtm_ci (j->name, j->a[0].p, j->a[1].p,
                                          j->a[2].i);
  if (!strcmp (s, "ppip")) return gtm_ci (j->name, j->a[0].p, j->a[1].p,
                                          j->a[2].i, j->a[3].p);
  if (!strcmp (s, "pipp")) return gtm_ci (j->name, j->a[0].p, j->a[1].i,
                                          j->a[2].p, j->a[3].p);
  return -1;  /* unknown signature: programming error */
}

static void run_job (ydb_job * j) {

  switch (j->kind) {
    case JOB_INIT:
      j->stage = 1;
      j->status = gtm_init ();
      if (j->status == 0) {
        j->stage = 2;
        j->status = gtm_ci ("m_init");
      }
      break;
    case JOB_CI:
      j->status = run_ci (j);
      break;
    case JOB_EXIT:
      j->status = gtm_exit ();
      break;
    case JOB_STOP:
      j->status = 0;
      break;
  }
  if (j->status != 0 && j->msg != NULL)
    gtm_zstatus (j->msg, j->msglen);
}

static void * ydb_thread (void * arg) {

  enif_mutex_lock (m_JobLock);
  for (;;) {
    while (m_Job == NULL || m_JobDone)
      enif_cond_wait (m_JobCond, m_JobLock);
    ydb_job * j = m_Job;
    run_job (j);
    m_JobDone = true;
    enif_cond_broadcast (m_JobCond);
    if (j->kind == JOB_EXIT || j->kind == JOB_STOP) break;
  }
  enif_mutex_unlock (m_JobLock);
  return NULL;
}

/* Run `j' on the YottaDB thread and wait for it. */
static void ydb_submit (ydb_job * j) {

  enif_mutex_lock (m_Lock);
  enif_mutex_lock (m_JobLock);
  m_Job = j; m_JobDone = false;
  enif_cond_broadcast (m_JobCond);
  while (!m_JobDone)
    enif_cond_wait (m_JobCond, m_JobLock);
  m_Job = NULL;
  enif_mutex_unlock (m_JobLock);
  enif_mutex_unlock (m_Lock);
}

/*
 * gtm_ci (Name, ...) on the YottaDB thread. `Sig' gives the kind of
 * each argument ('p' pointer, 'i' int); on failure, `Msg' receives
 * $ZSTATUS.
 */
static gtm_status_t ydb_call (char * msg, size_t msglen,
                              const char * name, const char * sig, ...) {

  ydb_job j = { .kind = JOB_CI, .name = name, .sig = sig,
                .msg = msg, .msglen = (int) msglen };
  msg [0] = '\0';

  va_list ap;
  va_start (ap, sig);
  for (int i = 0; sig [i] && i < 4; i++) {
    if (sig [i] == 'i') j.a [i].i = va_arg (ap, int);
    else                j.a [i].p = va_arg (ap, void *);
  }
  va_end (ap);

  ydb_submit (&j);
  return j.status;
}

int check_status (gtm_status_t status, char msg []) {

  return status != 0 ? -10 : 0;
}

static void destroy_sync (void) {

  enif_cond_destroy (m_JobCond);
  enif_mutex_destroy (m_JobLock);
  enif_mutex_destroy (m_Lock);
}

/* Start the YottaDB thread (non-zero on failure). */
static int start_ydb_thread (void) {

  m_Lock    = enif_mutex_create ("egtm_lock");
  m_JobLock = enif_mutex_create ("egtm_job_lock");
  m_JobCond = enif_cond_create ("egtm_job_cond");
  m_Job = NULL; m_JobDone = false;

  ErlNifThreadOpts * opts = enif_thread_opts_create ("egtm_ydb_opts");
  opts->suggested_stack_size = EGTM$STACK_KW;
  int rc = enif_thread_create ("egtm_ydb", &m_Thread, ydb_thread, NULL, opts);
  enif_thread_opts_destroy (opts);

  if (rc != 0) { destroy_sync (); return -1; }
  m_ThreadUp = true;
  return 0;
}

/* Stop the YottaDB thread, calling gtm_exit when `exit_ydb'. */
static void stop_ydb_thread (bool exit_ydb) {

  if (!m_ThreadUp) return;
  /* no gtm_exit after a failed gtm_init */
  ydb_job j = { .kind = exit_ydb ? JOB_EXIT : JOB_STOP };
  ydb_submit (&j);
  enif_thread_join (m_Thread, NULL);
  m_ThreadUp = false;
  destroy_sync ();
}

/* Copy an iolist term into a freshly allocated C string. */
static char * term_to_cstr (ErlNifEnv * env, ERL_NIF_TERM term) {

  ErlNifBinary bin;
  if (!enif_inspect_iolist_as_binary (env, term, &bin))
    return NULL;

  char * str = enif_alloc (bin.size + 1);
  if (str == NULL) return NULL;
  memcpy (str, bin.data, bin.size);
  str [bin.size] = '\0';

  return str;
}

/*
 * Apply `[{Name, Value | false}]' from egtm_env:init/0 to the real
 * process environment. Since OTP 21, os:putenv/2 only changes the
 * emulator's private copy, which gtm_init() never sees.
 */
static int apply_env (ErlNifEnv * env, ERL_NIF_TERM list) {

  ERL_NIF_TERM head, tail = list;
  while (enif_get_list_cell (env, tail, &head, &tail)) {

    int arity; const ERL_NIF_TERM * kv;
    if (!enif_get_tuple (env, head, &arity, &kv) || arity != 2)
      return -1;

    char * name = term_to_cstr (env, kv [0]);
    if (name == NULL) return -1;

    int rc;
    if (enif_is_atom (env, kv [1]))
      rc = unsetenv (name);
    else {
      char * value = term_to_cstr (env, kv [1]);
      if (value == NULL) { enif_free (name); return -1; }
      rc = setenv (name, value, 1);
      enif_free (value);
    }
    enif_free (name);

    if (rc != 0) return -1;
  }

  return enif_is_empty_list (env, tail) ? 0 : -1;
}

static int load_internal (ErlNifEnv * env, void ** priv, void ** old_priv, ERL_NIF_TERM load_info, bool upgrade) {

  c_AtomOK    = enif_make_atom (env, "ok");
  c_AtomError = enif_make_atom (env, "error");

  // XXX: not so correct in the case of upgrade!!
  tcgetattr (0, &m_StdinOrig);
  tcgetattr (1, &m_StdoutOrig);
  tcgetattr (2, &m_StderrOrig);

  /*
  * priv = malloc (sizeof (int));
  if (old_priv == NULL)
    ** (int **) priv = 0;
  else
    ** (int **) priv = (** (int **) old_priv) +1;
  fprintf (stderr, "PRIV=%d\n", (int) ** (int **) priv);
  */

  if (!upgrade) {
    char emsg [EGTM$BUFLEN];

    /*
     * A load callback can only return an int, so the GT.M/YottaDB
     * message goes to stderr; erlang:load_nif/2 then returns
     * {error, {load_failed, _}} and the on_load hook fails.
     */
    if (apply_env (env, load_info) != 0) {
      fprintf (stderr, "EGTM NIF: invalid environment in load_info\n");
      return 1;
    }

    if (start_ydb_thread () != 0) {
      fprintf (stderr, "EGTM NIF: cannot start the YottaDB thread\n");
      return 4;
    }

    // XXX: do we want it to call m_init only on init or also on upgrade?
    ydb_job j = { .kind = JOB_INIT, .msg = emsg, .msglen = sizeof (emsg) };
    emsg [0] = '\0';
    ydb_submit (&j);
    if (j.status != 0) {
      fprintf (stderr, "EGTM NIF: %s failed: %s\n",
               j.stage == 1 ? "gtm_init" : "m_init call-in", emsg);
      stop_ydb_thread (j.stage == 2);
      return j.stage == 1 ? 2 : 3;
    }
  }

  return 0;
}

static int load (ErlNifEnv * env, void ** priv, ERL_NIF_TERM load_info) {

  //fprintf (stderr, "LOAD\n");
  return load_internal (env, priv, NULL, load_info, false);
}

/*
static int upgrade (ErlNifEnv * env, void ** priv, void ** old_priv, ERL_NIF_TERM load_info) {

  //fprintf (stderr, "UPGRADE\n");
  return load_internal (env, priv, old_priv, load_info, true);
}

static int reload (ErlNifEnv * env, void ** priv, ERL_NIF_TERM load_info) {

  //fprintf (stderr, "RELOAD\n");
  return 0;
}
*/

static void unload (ErlNifEnv * env, void * priv) {

  //fprintf (stderr, "UNLOAD=%d\n", * (int *) priv);

  stop_ydb_thread (true);

  tcsetattr (0, 0, &m_StdinOrig);
  tcsetattr (1, 0, &m_StdoutOrig);
  tcsetattr (2, 0, &m_StderrOrig);
}

NIF (m_horo) {

  char val [64]; gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_horo", "p", val);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, val, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_job) {

  char val [64]; gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_job", "p", val);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, val, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_zver) {

  char val [128];
  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_zver", "p", val);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, val, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_get) {

  if (argc != 1) return enif_make_badarg (env);

  char key [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], key, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char val [EGTM$BUFLENBIG];
  gtm_status_t status;
  char emsg [EGTM$BUFLENBIG];
  status = ydb_call (emsg, sizeof (emsg), "m_get", "pp", val, key);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, val, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_getp) {

  if (argc != 3) return enif_make_badarg (env);

  char key [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], key, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  int piece;
  if (enif_get_int (env, argv [1], &piece) < 0)
    return enif_make_badarg (env);

  char delim [EGTM$BUFLEN];
  if (enif_get_string (env, argv [2], delim, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char val [EGTM$BUFLENBIG];
  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_getp", "ppip", val, key, piece, delim);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, val, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_set) {

  if (argc != 2) return enif_make_badarg (env);

  char key [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], key, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char val [EGTM$BUFLENBIG];
  if (enif_get_string (env, argv [1], val, EGTM$BUFLENBIG, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_set", "pp", key, val);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_setp) {

  if (argc != 4) return enif_make_badarg (env);

  char key [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], key, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  int piece;
  if (enif_get_int (env, argv [1], &piece) < 0)
    return enif_make_badarg (env);

  char delim [EGTM$BUFLEN];
  if (enif_get_string (env, argv [2], delim, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char val [EGTM$BUFLENBIG];
  if (enif_get_string (env, argv [3], val, EGTM$BUFLENBIG, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_setp", "pipp", key, piece, delim, val);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_order) {

  if (argc != 2) return enif_make_badarg (env);

  char gbl [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gbl, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char key [EGTM$BUFLEN];
  int dir;
  if (enif_get_int (env, argv [1], &dir) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_order", "ppi", key, gbl, dir);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, key, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_fast_order) {

  if (argc != 2) return enif_make_badarg (env);

  char gbl [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gbl, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  int dir;
  if (enif_get_int (env, argv [1], &dir) < 0)
    return enif_make_badarg (env);

  char key [EGTM$BUFLEN];
  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_fast_order", "ppi", key, gbl, dir);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, key, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_kill) {

  if (argc != 1) return enif_make_badarg (env);

  char gvn [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gvn, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_kill", "p", gvn);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_zkill) {

  if (argc != 1) return enif_make_badarg (env);

  char gvn [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gvn, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_zkill", "p", gvn);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_do) {

  if (argc != 1) return enif_make_badarg (env);

  char cmd [EGTM$BUFLENBIG];
  if (enif_get_string (env, argv [0], cmd, EGTM$BUFLENBIG, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_do", "p", cmd);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_call) {

  if (argc != 1) return enif_make_badarg (env);

  char cmd [EGTM$BUFLENBIG];
  if (enif_get_string (env, argv [0], cmd, EGTM$BUFLENBIG, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char res [EGTM$BUFLENBIG]; res[0]='\0';
  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_call", "pp", res, cmd);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, res, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_merge) {

  if (argc != 2) return enif_make_badarg (env);

  char gvn1 [EGTM$BUFLEN]; char gvn2 [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gvn1, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);
  if (enif_get_string (env, argv [1], gvn2, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_merge", "pp", gvn1, gvn2);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
      enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_xecute) {

  if (argc != 1) return enif_make_badarg (env);

  char cmd [EGTM$BUFLENBIG];
  if (enif_get_string (env, argv [0], cmd, EGTM$BUFLENBIG, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_xecute", "p", cmd);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_tstart) {

  if (argc != 1) return enif_make_badarg (env);

  char opts [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], opts, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_tstart", "p", opts);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_tcommit) {

  if (argc != 0) return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_tcommit", "");

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_trollback) {

  if (argc != 0) return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_trollback", "");

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_lock) {

  if (argc != 1) return enif_make_badarg (env);

  char gvn [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gvn, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_lock", "p", gvn);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_unlock) {

  if (argc != 1) return enif_make_badarg (env);

  char gvn [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gvn, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_unlock", "p", gvn);

  if (check_status (status, emsg) == 0)
    return c_AtomOK;
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_data) {

  if (argc != 1) return enif_make_badarg (env);

  char gvn [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], gvn, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  int ret; gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_data", "pp", &ret, gvn);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_int (env, ret));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

NIF (m_iget) {

  if (argc != 1) return enif_make_badarg (env);

  char varnam [EGTM$BUFLEN];
  if (enif_get_string (env, argv [0], varnam, EGTM$BUFLEN, ERL_NIF_LATIN1) < 0)
    return enif_make_badarg (env);

  char res [EGTM$BUFLENBIG]; res[0]='\0';
  gtm_status_t status;
  char emsg [EGTM$BUFLEN];
  status = ydb_call (emsg, sizeof (emsg), "m_iget", "pp", res, varnam);

  if (check_status (status, emsg) == 0)
    return enif_make_tuple2 (env, c_AtomOK,
        enif_make_string (env, res, ERL_NIF_LATIN1));
  else
    return enif_make_tuple2 (env, c_AtomError,
        enif_make_string (env, emsg, ERL_NIF_LATIN1));
}

/*
 * Every call-in may run arbitrary M code for as long as it likes,
 * so the NIFs run on dirty I/O schedulers (waiting for the YottaDB
 * thread there) instead of blocking a normal scheduler and the
 * timers it owns.
 */
#define DIRTY ERL_NIF_DIRTY_JOB_IO_BOUND

static ErlNifFunc nif_funcs [] = {
    {"m_set",        2, m_set, DIRTY},
    {"m_setp",       4, m_setp, DIRTY},
    {"m_get",        1, m_get, DIRTY},
    {"m_getp",       3, m_getp, DIRTY},
    {"m_order",      2, m_order, DIRTY},
    {"m_fast_order", 2, m_fast_order, DIRTY},
    {"m_kill",       1, m_kill, DIRTY},
    {"m_zkill",      1, m_zkill, DIRTY},
    {"m_do",         1, m_do, DIRTY},
    {"m_call",       1, m_call, DIRTY},
    {"m_merge",      2, m_merge, DIRTY},
    {"m_xecute",     1, m_xecute, DIRTY},
    {"m_tstart",     1, m_tstart, DIRTY},
    {"m_tcommit",    0, m_tcommit, DIRTY},
    {"m_trollback",  0, m_trollback, DIRTY},
    {"m_lock",       1, m_lock, DIRTY},
    {"m_unlock",     1, m_unlock, DIRTY},
    {"m_data",       1, m_data, DIRTY},
    {"m_horo",       0, m_horo, DIRTY},
    {"m_zver",       0, m_zver, DIRTY},
    {"m_job",        0, m_job, DIRTY},
    {"m_iget",       1, m_iget, DIRTY}
};

//ERL_NIF_INIT (egtm_worker, nif_funcs, &load, &reload, &upgrade, &unload);
ERL_NIF_INIT (egtm_worker, nif_funcs, &load, NULL, NULL, &unload);

// vim: fdm=syntax:fdn=1:tw=74:ts=2:syn=c
