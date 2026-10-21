IDEA EGTM: Erlang binding for GT.M database engine
==================================================

Software product description and documentation for application
developers is to be found on [http://labs.idea.cz/egtm](http://labs.idea.cz/egtm "IDEA EGTM Technology").

Installation
------------

- `git clone http://github.com/ztmr/egtm`
- ensure a current Erlang/OTP and `rebar3` are installed
- ensure YottaDB is installed; its location is taken from
  `pkg-config yottadb`, or set `EGTM_DIST` to override it
  (used by both `priv/gtmenv` and `c_src/Makefile`)
- `rebar3 compile` (also builds the NIF in `priv/egtm_worker.so`)
- initialize database with `./priv/initdb`
- run the console `./priv/egtm_console` (or `rebar3 shell`)
- run the tests with `rebar3 eunit`
- enjoy!

Notes
-----

- **YottaDB compatibility**
  - EGTM runs on YottaDB through its GT.M call-in compatibility
    layer (`libgtmshr.so`, `gtm_ci`); tested with YottaDB r2.07
    and Erlang/OTP 29.
  - `priv/gtmenv` mirrors every `gtm_*` setting into its `ydb_*`
    name, because YottaDB prefers `ydb_*` and a shell prepared
    by `ydb_env_set` would otherwise point EGTM at another
    database.
- **GT.M compatibility** (historical)
  - EGTM is known to not work with GT.M V5.5-000 Linux x86\_64
    because of [call-in bug](https://groups.google.com/d/topic/comp.lang.mumps/R_GvkUUZaq0/discussion "Call-in bug").
  - EGTM compiled against GT.M V6.0-000 is production ready
    as well as with the version of 5.4-002B.
- **Erlang compatibility**
  - tested with Erlang/OTP 29 (originally written for R15B)
  - logging goes through OTP `logger`; the only runtime
    dependency is `deepprops` (`folsom` is optional, for metrics)
  - the `$Get` cache (`[egtm, optimize, get_cache]`) is
    built-in (`egtm_cache`)
- **database location:** `priv/gbls` by default; set the
  `db_dir` application env (or `EGTM_GBLS`) to keep it outside
  the application directory -- always do so when EGTM is a
  dependency, otherwise the database lives in `deps/` and is
  packaged into releases
- **performance:**
  - per-operation debug logging (disabled by default)
    means around ~2000 microseconds overhead on reference machine,
  - metrics (disabled by default) costs around
    ~30 additional microseconds on reference machine,
  - both can be enabled using `EGTM_METRICS` and
    `EGTM_TRACE` compile-time macros,
  - unless `EGTM_METRICS` is defined, the `egtm_metrics`
    configuration (in `priv/egtm.conf`) is ignored.
- **transaction processing:**
  - since _GT.M call-in interface does not allow us to call
    standalone `TS`/`TC`/`TRO` commands_, we had to implement
    TP emulation. This is done by storing all write/lock operations
    within a virtual transaction buffer that is evaluated
    at the time of commit.
  - this has _some limitations_, for example:
    <pre>
    %% Expect the ^ZTMR to hold value of 0.
    DataProcessing = fun () ->
    &nbsp;&nbsp;io:put\_chars (egtm:get ("^ZTMR")),
    &nbsp;&nbsp;egtm:set ("^ZTMR", 1), %% when in transaction, this is not done immediatelly but at the commit-time!!!
    &nbsp;&nbsp;io:put\_chars (egtm:get ("^ZTMR")),
    &nbsp;&nbsp;false   %% Rollback!
    end,
    egtm\_util:transaction (DataProcessing), %% outputs 00{ok,rollback,unknown}
    egtm\_util:transaction (DataProcessing), %% outputs 00{ok,rollback,unknown}
    DataProcessing (),                      %% outputs 01false
    DataProcessing ().                      %% outputs 11false
    </pre>
  - _operations supported by TP_:
    `set`, `setp`, `kill`, `zkill`, `lock`, `unlock`.
  - To get _full-featured GT.M TP_, feel free to _write your own_
    `priv/rtns/MyRoutine.m` with any TP processing code and
    call it using `egtm:do/2` or `egtm:call/2`.
- **clustering and multi-site configurations:** EGTM HAC
  is a separate and paid add-on product.
- **consulting and support services, non-public/non-free add-ons**:
  Support and consulting services and non-public add-ons may
  be delivered individually under conditions specified in
  a valid support/license contract in context of one or more
  of these products:
  - FIS GT.M and FIS PIP/DATA-QWIK framework,
  - Erlang and ChicagoBoss framework,
  - IDEA EGTM,
  - IDEA Object Database (IODB),
  - IDEA EGTM High-Available Cluster (EGTM HAC),
  - IDEA CloudOS (ICOS).
    Feel free to contact IDEA Systems via e-mail or
    [www.idea.cz](http://www.idea.cz "IDEA Systems")
    in any case of interest!

Using EGTM from Elixir
---------------------

```elixir
# mix.exs
{:egtm, git: "https://github.com/kiskovacs/egtm.git", branch: "master"}

# config/runtime.exs
config :egtm, db_dir: System.get_env("EGTM_DB_DIR", "/var/lib/myapp/egtm")
```

Arguments may be Elixir strings or charlists. Results are
charlists of the stored bytes, so convert them with
`:erlang.list_to_binary/1` (not `List.to_string/1`, which would
double-encode UTF-8):

```elixir
:ok = :egtm.set("^Users", ["42", "name"], "Žofie")
:egtm.get("^Users", ["42", "name"]) |> :erlang.list_to_binary()
```

Failed operations are logged and return `[]`.

M code runs through `:egtm.xecute/1` (inline code), `:egtm.call/2`
(extrinsic functions, returning a charlist) and `:egtm.do/2`. Put
the application's own routines in e.g. `priv/m` and point EGTM at
them; their objects are compiled into `<db_dir>/o`:

```elixir
# config/runtime.exs
config :egtm,
  db_dir: System.get_env("EGTM_DB_DIR", "/var/lib/myapp/egtm"),
  routines: [Application.app_dir(:myapp, "priv/m")]

:egtm.call("greet^Hello", ["World"])   #=> ~c"Hello, World!"
:egtm.do("store^Hello", ["k", "v"])    #=> :ok
:egtm.xecute("set ^X=1+2")             #=> :ok
```

EGTM serializes all calls through one database thread, so a
long-running routine delays other EGTM calls (use pool mode for
concurrent M work); it does not block the rest of the VM.

TODO
----

- NIF upgrade/reload functinality -- GT.M call-ins
  are limited to a single `gtm_init`/`gtm_exit` call
  per each process, so we simply cannot unload GT.M
  shared library and load its new version gracefully :-(
- documentation: some `egtm` functions exists in more
  overloaded variants resolved by guards and well
  documented in source code itself.
  The standard edoc generator works only with the first
  match of all these variants, so the resulting HTML
  documentation may not be complete! :-(
- `init^%egtmapi` and error trapping
- `egtm:lock` timeout support
- EGTM NIF stores strings in static char array limited
  by `EGTM$BUFLEN` constant although each string has
  different lenght requirements on different places.
  This should be changed in future releases!
  Use the following:
  - `MAXCODE = 8192`
    (maximum length of a line of code for
    the compiler / variable name)
  - `MAXMSG = 2048`
    (maximum length of a GT.M message)
  - `MAXNAME = 32`
    (one more than the maximum length of a GT.M name)
  - `MAXSTR = 1048576`
    (maximum length of a value that GT.M can return)
- UTF-8 or Erlang-agnostic Latin-1 support without complicated
  encoding/decoding!!
  This is partially supported by `egtm_string` `encode`/`decode`,
  but currenly only for VALUES in `set`/`setp` and `get`/`getp`,
  thus NOT for: global names, subscripts, `do`/`call` arguments.
- Counters for intercluster load distribution purposes
  as well as for a common SNMP monitoring purposes.
  SNMP data may be based on Folsom metrics.
- WebAdmin (at least global browser) -- as ICOS Application?

Architecture Schema Design
--------------------------

<pre>
......................................
: Erlang/OTP Application Server #1   :
:                                    :..
:  +----------------------------+      :
:  | Application that uses EGTM |      :
:  +--------------+-------------+      :
:                 |                    :
:    +------------+-----------------+  :
:    | EGTM Master Broker Server    |  :
:    |..............................|  :
:    | does request routing logic   |  :
:    | based on deployment setup    | (A) single standalone worker
:    | (standalone, pool, cluster)  | (B) pool of local workers
:    |..............................| (C) cluster of A/B-mode servers
:    |      (A)(B)(C)               |  :
:    +-------+--+--+----------------+  :
:           /   |   \                  :.......
:          /    |    \                        :
:         /    /   +--+--------------------+  :
:        /    /    | EGTM Cluster Manager  |  :
:       /    /     | with IntelliRoute     |  :
:      /    /      +----------+------------+  :
:     /    /                  | ..............:
:    /     |        +---------+------------+
:   /      |        |          .:          |
:   |   +--+--------+-------+  :   +-------+---------------------+
:   |   | EGTM Worker Pool  |  :   | EGTM Cluster Neighbour Pool |
:   |   | egtm1, egtm2, ... |  :   +---------+-------------------+
:   |   +-----------+-------+  :           |
:   |               |  ........:           |
:   |               |  :                   |
:   |               |  :   +---------------+-------------+
: +--+----------+   |  :   | EGTM Slave Broker Server    |
: | Standalone  |   |  :   | another worker/pool/cluster |
: | EGTM Worker |   |  :   | SCHEMA RECURSION GOES HERE  |
: +------+------+   |  :   +---------------+-------------+
:        |          |  :                   |
:  +-----+--------+-+  :                +--+------------+
:  | GT.M master DB |===(replication)===| GT.M slave DB |
:  +----------------+  :                +---------------+
:......................:
</pre>

Licensing
=========

Copyright (C) 2012 IDEA Systems (www.idea.cz)

This program is free software: you can redistribute
it and/or modify it under the terms of the GNU Affero
General Public License as published by the Free Software
Foundation, either version 3 of the License,
or (at your option) any later version.

This program is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY; without even
the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU Affero General
Public License for more details.

You should have received a copy of the GNU Affero
General Public License along with this program.
If not, see [http://www.gnu.org/licenses/](http://www.gnu.org/licenses/ "GNU Licensing Overview").
