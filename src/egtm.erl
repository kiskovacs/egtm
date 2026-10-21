%%
%% $Id: $
%%
%% Module:  egtm -- description
%% Created: 05-APR-2012 20:11
%% Author:  tmr
%%
%% Copyright 2012 Tomas Morstein, IDEA Systems.
%%
%% This program is free software: you can redistribute
%% it and/or modify it under the terms of the GNU Affero
%% General Public License as published by the Free Software
%% Foundation, either version 3 of the License,
%% or (at your option) any later version.
%%
%% This program is distributed in the hope that it will
%% be useful, but WITHOUT ANY WARRANTY; without even
%% the implied warranty of MERCHANTABILITY or FITNESS
%% FOR A PARTICULAR PURPOSE. See the GNU Affero General
%% Public License for more details.
%%
%% You should have received a copy of the GNU Affero
%% General Public License along with this program.
%% If not, see <http://www.gnu.org/licenses/>.

%% @doc Erlang binding for GT.M database
%%
%% Example of usage:
%% ```
%% erl> egtm:start ().
%% ok
%% erl> egtm:zversion().
%% "GT.M V5.4-002B Linux x86_64"
%% erl> egtm:job().
%% "13757"
%% erl> egtm:get ("^ZTMR").
%% []
%% erl> egtm:set ("^ZTMR", [1,2,3], egtm:zversion ()).
%% ok
%% erl>
%% egtm:get ("^ZTMR").                           
%% []
%% erl> egtm:get ("^ZTMR", [1,2,3]).
%% "GT.M V5.4-002B Linux x86_64"
%% erl> Rand = fun (N) -> random:uniform (N) end.             
%% #Fun<erl_eval.6.111823515>
%% erl> egtm:set ("^ZTMR", [Rand (10), Rand (10)], Rand (10000)).
%% ok
%% erl> egtm:set ("^ZTMR", [Rand (10), Rand (10)], Rand (10000)).
%% ok
%% erl> egtm:set ("^ZTMR", [Rand (10), Rand (10)], Rand (10000)).
%% ok
%% erl> egtm:set ("^ZTMR", [Rand (10), Rand (10)], Rand (10000)).
%% ok
%% erl> egtm:set ("^ZTMR", [Rand (10), Rand (10)], Rand (10000)).
%% ok
%% erl> egtm_util:foreach ("^ZTMR", [],
%%        fun (G, S, R) -> egtm_util:foreach (G, S), [] end).  
%% ^ZTMR["1","2"]=[]
%% ^ZTMR["2","3"]="6972"
%% ^ZTMR["2","6"]="2150"
%% ^ZTMR["4","6"]="9157"
%% ^ZTMR["7","5"]="5966"
%% ^ZTMR["8","10"]="5015"
%% {ok,[]}
%% erl> egtm:order ("^ZTMR", ["2", ""], backward). 
%% ["2","6"]
%% erl> egtm:order ("^ZTMR", ["2", ""], forward). 
%% ["2","3"]
%% erl> egtm:stop ().
%% ok
%% erl>
%% '''
-module (egtm).
-behaviour (application).

-export ([start/0, start/2, stop/0, stop/1, perform/2]).
-export ([
  set/3, set/2,
  setp/5, setp/4, setp/3, setp/2,
  get/2, get/1,
  getp/4, getp/3, getp/2, getp/1,
  gorder/0, gorder/1, order/0, order/1, order/2, order/3,
  kill/1, kill/2, zkill/1, zkill/2,
  do/1, do/2, call/1, call/2, merge/4, merge/2,
  tstart/0, tstart/1, tcommit/0, trollback/0,
  lock/1, lock/2, unlock/1, unlock/2,
  data/1, data/2, xecute/1,
  zversion/0, horolog/0, job/0, iget/1, iget/2]).
-export ([fast_order/2, call_fast_order/2, xecute_fast_order/2]).
%-compile (export_all).

-include_lib ("egtm.hrl").

%% --- Public API ---------
%% @doc application:start callback, do not use directly!
start (_Type, _Args) ->
  egtm_cache:init (),
  ?report_info ("Starting up ~p on node ~p...", [?MODULE, node ()]),
  egtm_env:setup_env (),
  case egtm_admin:ensure_db () of
    ok ->
      case operation_mode () of
        worker  -> egtm_worker_sup:start_link ();
        manager -> egtm_pool_sup:start_link ()
      end;
    Error ->
      Error
  end.

%% @doc Start EGTM application (and the applications it needs).
start () ->
  case application:ensure_all_started (?MODULE) of
    {ok, _} -> ok;
    Error   -> Error
  end.

%% @doc application:stop callback, do not use directly!
stop (_State) ->
  ?report_info ("Shutting down ~p on node ~p...", [?MODULE, node ()]),
  case operation_mode () of
    worker  -> egtm_worker:terminate (stop, []);
    manager -> egtm_pool:terminate (stop, [])
  end,
  ok.

%% @doc Stop EGTM application.
stop () -> application:stop (?MODULE).

%% @equiv get (Gvn, [])
get (Gvn) -> get (Gvn, []).

%% @doc Get value of specified node (MUMPS: `$Get(@Gvn@(Subs))').
-spec get (Gvn::global_name (), Subs::subscripts ()) -> string ().
get (Gvn, Subs) when is_list (Subs) ->
  ?trace ("get", [Gvn, Subs]),
  PerformIt = fun () ->
    egtm_string:decode (egtm_util_fmt:unescape_val (perform (get,
          [egtm_util_fmt:format_gvn (Gvn, Subs)])))
  end,
  case egtm_config:param ([egtm,optimize,get_cache,enabled]) of
    true ->
      CKey = {Gvn, Subs},
      TimeOut = egtm_config:param ([egtm,optimize,get_cache,timeout]),
      case egtm_cache:load (CKey) of
        {ok, Val} ->
          Val;
        _         ->
          X = PerformIt (), egtm_cache:store (CKey, X, TimeOut), X
      end;
    _    ->
      PerformIt ()
  end.

%% @doc Get value of specific position in specified node
%% value delimited by specified delimiter
%% (MUMPS: `$Piece($Get(@Gvn@(Subs)),Delim,Piece)').
-spec getp (Gvn::global_name (), Subs::subscripts (),
            Piece::integer (), Delim::string ()) -> string ().
getp (Gvn, Subs, Piece, Delim) when is_number (Piece) ->
  ?trace ("getp", [Gvn, Subs, Piece, Delim]),

  % Use native $GET($PIECE(@Gvn@Subs,Delim,Piece)) or
  % just $Get(@Gvn@Subs) and emulate $Piece in Erlang?
  case egtm_config:param ([egtm,optimize,native_getp]) of
    false ->
      % Use Erlang-side $Piece only if the native one
      % is explicitly disabled:
      epiece (get (Gvn, Subs), Delim, Piece);
    _     ->
      egtm_string:decode (egtm_util_fmt:unescape_val (perform (getp,
            [egtm_util_fmt:format_gvn (Gvn, Subs), Piece, Delim])))
  end.

%% @equiv getp (Gvn, Subs, Piece, Delim)
getp (Gvn, Piece, Delim) when is_number (Piece) ->
  getp (Gvn, [], Piece, Delim);
getp (Gvn, Subs, Piece) ->
  getp (Gvn, Subs, Piece,
    egtm_config:param ([egtm,defaults,piece_delim])).

%% @equiv getp (Gvn, Subs, Piece, Delim)
getp (Gvn, Piece) when is_number (Piece) ->
  getp (Gvn, [], Piece);
getp (Gvn, Subs) when is_list (Subs) ->
  getp (Gvn, Subs, 1).

%% @equiv getp (Gvn, Subs, Piece, Delim)
getp (Gvn) -> getp (Gvn, []).

%% @equiv set (Gvn, Subs, Val)
set (Gvn, Val) -> set (Gvn, [], Val).

%% @doc Set value of specified node (MUMPS `Set @Gvn@(Subs)=Val').
-spec set (Gvn::global_name (), Subs::subscripts (),
           Val::string ()) -> ok.
set (Gvn, Subs, Val) ->
  ?trace ("set", [Gvn, Subs, Val]),
  clear_cache (Gvn, Subs),
  perform (set, [egtm_util_fmt:format_gvn (Gvn, Subs),
    egtm_util_fmt:escape_val (egtm_string:encode (Val))]).

%% @doc Set value of specific position in specified node
%% value delimited by specified delimiter
%% (MUMPS: `Set $Piece($Get(@Gvn@(Subs)),Piece,Delim)=Val').
-spec setp (Gvn::global_name (), Subs::subscripts (),
            Piece::integer (), Delim::string (),
            Val::string ()) -> ok.
setp (Gvn, Subs, Piece, Delim, Val) when is_number (Piece) ->
  ?trace ("setp", [Gvn, Subs, Piece, Delim, Val]),
  clear_cache (Gvn, Subs),
  perform (setp, [egtm_util_fmt:format_gvn (Gvn, Subs), Piece, Delim,
    egtm_util_fmt:escape_val (egtm_string:encode (Val))]).

%% @equiv setp (Gvn, Subs, Piece, Delim, Val)
setp (Gvn, Piece, Delim, Val) when is_number (Piece) ->
  setp (Gvn, [], Piece, Delim, Val);
setp (Gvn, Subs, Piece, Val) ->
  setp (Gvn, Subs, Piece,
    egtm_config:param ([egtm,defaults,piece_delim]), Val).

%% @equiv setp (Gvn, Subs, Piece, Delim, Val)
setp (Gvn, Piece, Val) when is_number (Piece) ->
  setp (Gvn, [], Piece, Val);
setp (Gvn, Subs, Val) when is_list (Subs) ->
  setp (Gvn, Subs, 1, Val).

%% @equiv setp (Gvn, Subs, Piece, Delim, Val)
setp (Gvn, Val) ->
  setp (Gvn, [], Val).

%% @equiv gorder ([])
gorder () -> gorder ([]).

%% @doc A special case of `egtm:order ()' where
%% we want order not only over subscripts, but
%% over global names.
%%
%% If no `Gvn' specified, "^%" is used as it
%% is the first possible name of any global name.
%%
%% Since the use of `gorder' is limited only
%% to few cases, we support only `forward'
%% direction.
gorder ([]) -> gorder ("^%");
gorder (Gvn) ->
  ?trace ("gorder", [Gvn]),
  case perform (order, [Gvn, 1]) of
    {error, X} -> {error, X};
    Res        -> Res
  end.

%% @equiv gorder ()
order () -> gorder ().

%% @equiv gorder (Gvn)
order (Gvn) -> gorder (Gvn).

%% @equiv order (Gvn, Subs, forward)
order (Gvn, Subs) -> order (Gvn, Subs, forward).

%% @doc Obtain next/previous key from global name `Gvn'
%% and subscript index `Subs' with respect to `Direction'
%% (MUMPS: `$Order(@Gvn@(Subs),Direction)').
%%
%% Returns a next (full) subscript to use, example:
%% <ul>
%% <li>let's have global like `^X(0,1)="A",^X(0,2)="B",^X(0,3)="C"'</li>
%% <li>`egtm:order ("^X", [0, ""]) = [0,1]'</li>
%% <li>`egtm:order ("^X", [0, 1])  = [0,2]'</li>
%% <li>`egtm:order ("^X", [0, 2])  = [0,3]'</li>
%% <li>`egtm:order ("^X", [0, 3])  = [0,""]'</li>
%% </ul>
%%
%% Note that empty `Subs' list is treated XXX
-spec order (Gvn::global_name (),
             Subs::subscripts (),
             Dir::order_direction ()) -> subscripts ().
order (Gvn, [], Direction) -> order (Gvn, [""], Direction);
order (Gvn, Subs, Direction) when is_list (Subs) ->
  ?trace ("order", [Gvn, Subs, Direction]),
  D = case Direction of
    backward -> -1;
    _        -> 1
  end,
  case perform (order, [egtm_util_fmt:format_gvn (Gvn, Subs, true), D]) of
    {error, X} -> {error, X};
    Res -> [_|SubsH] = lists:reverse (Subs),
           lists:reverse ([egtm_util_fmt:unescape_key (Res)|SubsH])
  end.

%% @equiv kill (Gvn, [])
kill (Gvn) -> kill (Gvn, []).

%% @doc Kill specified node including all its
%% parents (MUMPS: `Kill @Gvn@(Subs)').
-spec kill (Gvn::global_name (), Subs::subscripts ()) -> ok.
kill (Gvn, Subs) ->
  ?trace ("kill", [Gvn, Subs]),
  clear_cache (Gvn, Subs, true),
  perform (kill, [egtm_util_fmt:format_gvn (Gvn, Subs)]).

%% @equiv zkill (Gvn, [])
zkill (Gvn) -> zkill (Gvn, []).

%% @doc ZKILL/ZWITHDRAW operation kills only specified
%% node without affecting any of subnodes
%% (MUMPS: `ZKill @Gvn@(Subs)').
-spec zkill (Gvn::global_name (), Subs::subscripts ()) -> ok.
zkill (Gvn, Subs) ->
  ?trace ("zkill", [Gvn, Subs]),
  clear_cache (Gvn, Subs),
  perform (zkill, [egtm_util_fmt:format_gvn (Gvn, Subs)]).

%% @equiv do (Gvn, [])
do (Pgm) -> do (Pgm, []).

%% @doc Extrinsic call to external routine (MUMPS: `Do @Pgm@(Args)').
-spec do (Pgm::program_name (), Args::list ()) -> ok.
do (Pgm, Args) when is_list (Args) ->
  ?trace ("do", [Pgm, Args]),
  perform (do, [egtm_util_fmt:format_pgm_call (Pgm, Args)]).

%% @equiv call (Gvn, [])
call (Pgm) -> call (Pgm, []).

%% @doc Intrinsic call to external routine (MUMPS: `$$@Pgm@(Args)').
-spec call (Pgm::program_name (), Args::list ()) -> string ().
call (Pgm, Args) when is_list (Args) ->
  ?trace ("call", [Pgm, Args]),
  perform (call, [egtm_util_fmt:format_pgm_call (Pgm, Args)]).

%% @equiv merge (SrcGvn, [], DstGvn, [])
merge (SrcGvn, DstGvn) -> merge (SrcGvn, [], DstGvn, []).

%% @doc Merge/copy one sparse array to another one
%% (MUMPS: `Merge @DstGvn@(DstSubs)=@SrcGvn@(SrcSubs)').
-spec merge (SrcGvn::global_name (), SrcSubs::subscripts (),
             DstGvn::global_name (), DstSubs::subscripts ()) -> ok.
merge (SrcGvn, SrcSubs, DstGvn, DstSubs) ->
  ?trace ("merge", [SrcGvn, SrcSubs, DstGvn, DstSubs]),
  clear_cache (DstGvn, DstSubs),
  perform (merge, [egtm_util_fmt:format_gvn (DstGvn, DstSubs),
      egtm_util_fmt:format_gvn (SrcGvn, SrcSubs)]).

%% @equiv tstart ("")
tstart () -> tstart ("").

%% @doc Start a new level of transaction
%% (MUMPS: `TStart @Opt').
-spec tstart (Opt::tp_options ()) -> ok.
tstart (Opt) ->
  ?trace ("tstart", [Opt]),
  perform (tstart, [Opt]).

%% @doc Commit the current transaction level and
%% clear the transaction buffer (MUMPS: `TCommit').
-spec tcommit () -> ok.
tcommit () ->
  ?trace ("tcommit"),
  perform (tcommit, []).

%% @doc Roll back the current transaction level
%% and clear the transaction buffer (MUMPS: `TRollback').
-spec trollback () -> ok.
trollback () ->
  ?trace ("trollback"),
  perform (trollback, []).

%% @equiv lock (Gvn, [])
lock (Gvn) -> lock (Gvn, []).

%% @doc Lock a subtree of global variable (MUMPS: `Lock +@Gvn@(Subs)').
-spec lock (Gvn::global_name (), Subs::subscripts ()) -> ok.
lock (Gvn, Subs) when is_list (Subs) ->
  ?trace ("lock", [Gvn, Subs]),
  perform (lock, [egtm_util_fmt:format_gvn (Gvn, Subs)]).

%% @equiv unlock (Gvn, [])
unlock (Gvn) -> unlock (Gvn, []).

%% @doc Unlock a subtree of global variable (MUMPS: `Lock -@Gvn@(Subs)').
-spec unlock (Gvn::global_name (), Subs::subscripts ()) -> ok.
unlock (Gvn, Subs) when is_list (Subs) ->
  ?trace ("unlock", [Gvn, Subs]),
  perform (unlock, [egtm_util_fmt:format_gvn (Gvn, Subs)]).

%% @doc data (Gvn, []).
data (Gvn) -> data (Gvn, []).

%% @doc Check if the subtree of global variable
%% contains any records (MUMPS: `$Data(@Gvn@(Subs))').
-spec data (Gvn::global_name (), Subs::subscripts ()) -> integer ().
data (Gvn, Subs) when is_list (Subs) ->
  ?trace ("data", [Gvn, Subs]),
  perform (data, [egtm_util_fmt:format_gvn (Gvn, Subs)]).

%% @doc Evaluate MUMPS code (MUMPS: `Xecute Mcode').
%% USE CAREFULLY!
-spec xecute (Mcode::string ()) -> ok.
xecute (Mcode) ->
  ?trace ("xecute", [Mcode]),
  perform (xecute, [Mcode]).

%% @doc Return GT.M version information (MUMPS: `$Zversion').
-spec zversion () -> string ().
zversion () ->
  ?trace ("zversion"),
  perform (zver, []).

%% @doc Return the current time in MUMPS $H-format (MUMPS: `$Horolog').
%% XXX: what about transforming it from string "X,Y" to Erlang tuple {X,Y}?
-spec horolog () -> string ().
horolog () ->
  ?trace ("horolog"),
  perform (horo, []).

%% @doc Return process ID of the GT.M worker job (MUMPS: `$Job').
%% XXX: what about transforming it from string to integer or long?
-spec job () -> string ().
job () ->
  ?trace ("job"),
  perform (job, []).

%% @equiv iget (VarName)
-spec iget (VarName::string (), Subs::subscripts ()) -> string ().
iget (VarName, Subs) -> iget (egtm_util_fmt:format_gvn (VarName, Subs)).

%% @doc Return a value of intrinsic (system) variable.
%% Example: to get `$ZRO[utines]', just `egtm:iget ("ZRO")'.
%% Note: to set an intrinsic variable, there's no `iset'
%% supported, so feel free to use `xecute'.
-spec iget (VarName::string ()) -> string ().
iget (VarName) ->
  ?trace ("iget"),
  perform (iget, [VarName]).

%% @doc XXX: Alternative `egtm:order ()' experiment.
fast_order (Gvn, Subs) ->
  Fmt = egtm_util_fmt:format_gvn (Gvn, Subs, true),
  ?trace ("fast_order", [Fmt, 1]),
  N = length (Subs),
  Subs2 = lists:sublist (Subs, N-1),
  case perform (fast_order, [Fmt, 1]) of
    {error, Error} -> {error, Error};
    Res            -> Subs2++[egtm_util_fmt:unescape_key (Res)]
  end.

%% @doc XXX: Alternative `egtm:order ()' experiment.
call_fast_order (Gvn, Subs) ->
  Fmt = egtm_util_fmt:format_gvn (Gvn, Subs, true),
  ?trace ("call_fast_order", [Fmt, 1]),
  N = length (Subs),
  Subs2 = lists:sublist (Subs, N-1),
  case call ("fastOrder^%egtmapi", [Fmt, 1]) of
    {error, Error} -> {error, Error};
    Res            -> Subs2++[egtm_util_fmt:unescape_key (Res)]
  end.

%% @doc XXX: Alternative `egtm:order ()' experiment.
%% XXX: Ensure it to run on the same `egtm_worker'
xecute_fast_order (Gvn, Subs) ->
  Fmt = egtm_util_fmt:format_gvn (Gvn, Subs, true),
  ?trace ("xecute_fast_order", [Fmt, 1]),
  N = length (Subs),
  Subs2 = lists:sublist (Subs, N-1),
  Cmd = lists:flatten (io_lib:format ("S %OrderVal=$O(~s)", [Fmt])),
  case xecute (Cmd) of
    ok       -> Subs2++[egtm:get ("%OrderVal")];
    Whatever -> {error, Whatever}
  end.

%% --- Internal utils ---------
%-define (EGTM_POOL_ENABLED, 1).
-ifdef (EGTM_POOL_ENABLED).
operation_mode () ->
  case {application:get_env (?MODULE, role),
        egtm_config:param ([egtm, mode])} of
    {{ok, worker}, _} -> worker;  %% egtm_pool started us as its worker
    {_, single} -> worker;
    {_, pool}   -> manager
  end.
-else.
operation_mode () -> worker.
-endif.

%% @doc Perform EGTM operation. A wrapper for all calls
%% with integrated decision logic if the operation is
%% to be performed by local worker, via pool, or via
%% cluster API.
%% This function is used as a proxy for all EGTM operations
%% within `egtm' module.
%% It is not recommended to use it directly from applications
%% as it calls raw NIF functions without any additional logic.
perform (Op, Args) ->
  case lists:member (Op, egtm_config:param ([egtm, deny])) of
    true  -> {error, {security, operation_denied, Op}};
    false -> perform_internal (Op, [ nif_arg (A) || A <- Args ])
  end.

%% The NIF takes Latin-1 char lists; accept binaries (Elixir
%% strings) as their raw bytes, including binaries embedded in
%% a formatted reference such as `[<<"^Foo">>, $(, ...]'.
nif_arg (A) when is_binary (A) -> binary_to_list (A);
nif_arg (A) when is_list (A) ->
  case lists:any (fun erlang:is_binary/1, A) of
    true  -> lists:flatmap (fun (B) when is_binary (B) -> binary_to_list (B);
                                (C) -> [C] end, A);
    false -> A
  end;
nif_arg (A) -> A.

perform_internal (Operation, Args) ->
  Result = case operation_mode () of
    worker  ->
      ?metrics ("egtm.worker.op."++atom_to_list (Operation),
        fun () -> egtm_worker:perform (Operation, Args) end);
    manager ->
      ?metrics ("egtm.pool.op."++atom_to_list (Operation),
        fun () -> egtm_pool:perform (Operation, Args) end)
  end,
  case Result of
    {ok, Res}      -> Res;
    {error, Error} -> ?report_error (Error), [];
    Whatever       -> Whatever
  end.

epiece ([], _, _) -> [];
epiece (_, _, N) when N =< 0 -> [];
epiece (S, D, N) when N > 0 andalso is_list (S) ->
  DBin = iolist_to_binary (D),
  SBin = list_to_binary (S),
  binary_to_list (epiece_internal (binary:split (SBin, DBin), DBin, 1, N)).

epiece_internal ([S|_], _, N, N) -> S;
epiece_internal ([_, R], D, M, N) ->
  epiece_internal (binary:split (R, D), D, M+1, N);
epiece_internal (_, _, _, _) -> <<>>.

clear_cache (Gvn, Subs) -> clear_cache (Gvn, Subs, false).
clear_cache (Gvn, Subs, Flush) ->
  case egtm_config:param ([egtm,optimize,get_cache,enabled]) of
    true ->
      CKey = {Gvn, Subs},
      case Flush of
        true  -> egtm_cache:flush ();
        false -> egtm_cache:delete (CKey)
      end,
      ok;
    _    -> ok
  end.


%% EUnit Tests
-ifdef (TEST).
-include_lib ("eunit/include/eunit.hrl").

basic_test () ->
  ?MODULE:start (),

  RndStr = egtm_util_eunit:rnd_str_fun (),
  {Gvn, Subs} = {"^EUnit", ["egtm:basic", RndStr (8)]},
  Text = RndStr (256),

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, Text)),
  ?assertEqual (Text, ?MODULE:get (Gvn, Subs)),

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, "")),
  ?assertEqual ("", ?MODULE:get (Gvn, Subs)),

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, "\"\"\"")),
  ?assertEqual ("\"\"\"", ?MODULE:get (Gvn, Subs)),

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, 256.99)),
  ?assertEqual ("256.99", ?MODULE:get (Gvn, Subs)),

  ?assertEqual (ok, ?MODULE:zkill (Gvn, Subs)),
  ?assertEqual ("", ?MODULE:get (Gvn, Subs)),

  ?assertEqual (?MODULE:zversion (), ?MODULE:iget ("zver")),
  ?assertEqual (?MODULE:zversion (), ?MODULE:iget ("zversion")),

  ?MODULE:stop (),
  ok.

%% Binaries (Elixir strings) work wherever strings do; results
%% are still char lists of the stored bytes.
binary_test () ->
  ?MODULE:start (),
  Gvn = <<"^EUnit">>, Subs = [<<"egtm:binary">>, <<"k\"q">>],
  Utf8 = <<"Žluťoučký kůň"/utf8>>,

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, <<"say \"hi\"">>)),
  ?assertEqual ("say \"hi\"", ?MODULE:get ("^EUnit", ["egtm:binary", "k\"q"])),

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, Utf8)),
  ?assertEqual (Utf8, list_to_binary (?MODULE:get (Gvn, Subs))),

  ?assertEqual (ok, ?MODULE:set (Gvn, Subs, <<"a|b|c">>)),
  ?assertEqual ("b", ?MODULE:getp (Gvn, Subs, 2, <<"|">>)),

  ?assertEqual (ok, ?MODULE:xecute (<<"set ^EUnit(\"egtm:binary\",\"x\")=1">>)),
  ?assertEqual ("1", ?MODULE:get (Gvn, [<<"egtm:binary">>, <<"x">>])),

  ?assertEqual (ok, ?MODULE:kill (Gvn, [<<"egtm:binary">>])),
  ?MODULE:stop (),
  ok.

%% do/call commands may be as long as xecute code (64 KB buffer),
%% though M itself limits a line of code to about 8 KB
call_long_arg_test () ->
  ?MODULE:start (),
  Arg = lists:duplicate (2000, $x),
  ?assertEqual (Arg, ?MODULE:call ("testEcho^%egtmapi", [Arg])),
  ?MODULE:stop (),
  ok.

order_direction_test () ->
  ?MODULE:start (),

  RndStr = egtm_util_eunit:rnd_str_fun (),
  {Gvn, Subs} = {"^EUnit", ["egtm:order_direction", RndStr (8)]},

  ?assertEqual (ok, ?MODULE:kill (Gvn, Subs)),
  ?assertEqual (ok, ?MODULE:set (Gvn, Subs++["1"], "one")),
  ?assertEqual (ok, ?MODULE:set (Gvn, Subs++[2], "two")),
  ?assertEqual (ok, ?MODULE:set (Gvn, Subs++[2.5], "two point five")),
  ?assertEqual (ok, ?MODULE:set (Gvn, Subs++["3","hello"], "three")),
  ?assertEqual (ok, ?MODULE:set (Gvn, Subs++["4"], "four")),

  ?assertEqual (Subs++["1"], ?MODULE:order (Gvn, Subs++[""])),
  ?assertEqual (Subs++["1"], ?MODULE:order (Gvn, Subs++[""], forward)),
  ?assertEqual (Subs++["2"], ?MODULE:order (Gvn, Subs++[1], forward)),
  ?assertEqual (Subs++["4"], ?MODULE:order (Gvn, Subs++[""], backward)),

  ?MODULE:stop (),
  ok.

order_speed_test () ->
  ?MODULE:start (),
  ?MODULE:do ("testPerfPrepare^%egtmapi()"),

  egtm_util_eunit:perform_speed ([
    {fun () -> ?MODULE:zversion () end,
      50, "Erlang $ZVersion"},
    {fun () -> ?MODULE:call ("testPerfOrder1^%egtmapi()") end,
      10, "Native $Order"},
    {fun () -> ?MODULE:call ("testPerfOrder2^%egtmapi()") end,
      10, "Indirection-based"},
    {fun () -> ?MODULE:call ("testPerfOrder3^%egtmapi()") end,
      10, "Xecute-based"},
    {fun () -> egtm_util_eunit:order_loop (?MODULE, indirection, 100) end,
      5, "Erlang Indirection-based"},
    {fun () -> egtm_util_eunit:order_loop (?MODULE, call_xecute, 100) end,
      5, "Erlang Call-Xecute-based"},
    {fun () -> egtm_util_eunit:order_loop (?MODULE, xecute, 100) end,
      5, "Erlang Xecute-based"},
    {fun () -> egtm_util_eunit:order_loop (?MODULE, erl_xecute, 100) end,
      5, "Erlang ErlXecute-based"}
  ]),

  ?MODULE:stop (),
  ok.
-endif.

%% vim: fdm=syntax:fdn=3:tw=74:ts=2:syn=erlang
