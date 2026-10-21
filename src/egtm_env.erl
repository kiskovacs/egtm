%%
%% $Id: $
%%
%% Module:  egtm_env -- description
%% Created: 30-DEC-2012 03:56
%% Author:  tmr
%%

-module (egtm_env).
-export ([init/0, setup_env/0, get_priv_dir/1, syscmd/1, syscmd/2]).

-include_lib ("egtm.hrl").

%% @doc Load the GT.M/YottaDB environment from `priv/listenv'.
%% Returns `[{Name, Value | false}]' for the NIF loader:
%% since OTP 21, `os:putenv' only updates the emulator's own copy
%% of the environment, so the NIF has to `setenv' these itself
%% before `gtm_init'. `false' means the variable is to be unset.
init () ->
  RawEnv = syscmd (get_cmd (listenv)),
  Env = parse_env (binary:split (list_to_binary (RawEnv),
    ?EGTM_ENV_DELIM_REC, [global])),
  [ os:putenv (K, V) || {K, V} <- Env ],
  Unset = [ {K, false} || K <- ?EGTM_ENV_UNSET,
                          not lists:keymember (K, 1, Env) ],
  Env ++ Unset.

%% @doc Export the `db_dir' and `routines' application envs as
%% `EGTM_GBLS' and `EGTM_ROUTINES', for the priv/ scripts, the NIF
%% and pool workers. In Elixir, for example:
%% ```
%% config :egtm,
%%   db_dir: "/var/lib/myapp/egtm",
%%   routines: [Application.app_dir(:myapp, "priv/m")]
%% '''
%% Without `db_dir', `EGTM_GBLS' or `priv/gbls' is used. Compiled
%% routines go to `<db_dir>/o', so routine sources may be read-only.
setup_env () ->
  case application:get_env (?EGTM_APPNAME, db_dir) of
    {ok, Dir} -> os:putenv ("EGTM_GBLS", abs_dir (Dir));
    undefined -> ok
  end,
  case application:get_env (?EGTM_APPNAME, routines) of
    {ok, Dirs} -> os:putenv ("EGTM_ROUTINES", routine_dirs (Dirs));
    undefined  -> ok
  end.

%% A single directory or a list of them
routine_dirs ([C|_] = Dir) when is_integer (C) -> abs_dir (Dir);
routine_dirs (Dir) when is_binary (Dir) -> abs_dir (Dir);
routine_dirs (Dirs) when is_list (Dirs) ->
  string:join ([ abs_dir (D) || D <- Dirs ], " ").

abs_dir (Dir) -> filename:absname (unicode:characters_to_list (Dir)).

get_cmd (listenv) -> get_priv_dir ("listenv").

%% XXX: May be used by egtm_admin too?
get_priv_dir (Name) ->
  case code:priv_dir (?EGTM_APPNAME) of
    {error, bad_name} ->
      case filelib:is_dir (filename:join (["..", priv])) of
        true -> filename:join (["..", priv, Name]);
        _    -> filename:join ([priv, Name])
      end;
    Dir -> filename:join (Dir, Name)
  end.

parse_env (Lines) ->
  [ {binary_to_list (K), binary_to_list (V)}
    || L <- Lines, [K, V] <- [binary:split (L, ?EGTM_ENV_DELIM_KV)] ].

%% XXX: To be moved somewhere else
syscmd (Cmd, Args) -> syscmd (string:join ([Cmd|Args], " ")).
syscmd (Cmd) ->
  Port = erlang:open_port ({spawn, Cmd}, [exit_status]),
  loop (Port, [], 5000).

loop (Port, Data, Timeout) ->
  receive
    {Port, {data, NewData}} ->
      loop (Port, Data++NewData, Timeout);
    {Port, {exit_status, 0}} ->
      Data;
    {Port, {exit_status, S}} ->
      throw ({commandfailed, S})
  after Timeout ->
    throw (timeout)
  end.

%% vim: fdm=syntax:fdn=3:tw=74:ts=2:syn=erlang
