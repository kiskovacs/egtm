%%
%% $Id: $
%%
%% Module:  egtm_pool -- description
%% Created: 06-APR-2012 22:40
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

%% @doc EGTM worker pool manager process.
%%
%% Since GT.M/YottaDB call-ins are limited to one database
%% process per OS process, a pool needs one ErlVM per worker.
%% Workers are started with `peer' as child ErlVMs controlled
%% over their standard I/O (no Erlang distribution, EPMD or
%% cookie needed), one per name in `[egtm, workers, nodes]'.
%% Each runs the `egtm' application in worker role, sharing
%% the same database.
%%
%% Requests are dispatched concurrently to a random worker.
%%
%% Transactions: the emulated TP buffer (`%EGTMTP') lives in the
%% worker's M process and is shared by everything that runs there,
%% so `tstart' reserves a worker exclusively for the calling process
%% until its outermost `tcommit'/`trollback'. Other callers are
%% routed to the remaining workers, or wait when all are reserved.
%% If the caller dies inside a transaction, it is rolled back.
%%
%% The pool is disabled by default; to use it, compile EGTM with
%% the `EGTM_POOL_ENABLED' macro (`rebar3 as pool compile') and
%% set `[egtm, mode]' to `pool'.
-module (egtm_pool).
-behaviour (gen_server).

-export ([init/1,
  handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).
-export ([start_link/0, perform/2, status/0]).

-include ("egtm.hrl").

-define (RESTART_DELAY, 2000).

%% workers: Name => #{pid, inflight, owner, pending}
%%   owner   -- process holding the worker for a transaction
%%   pending -- `tstart' waiting for in-flight requests to drain
%% owners:  Caller => #{name, depth, mref, dead}
%% pids:    PeerPid => Name
-record (state, {workers = #{}, owners = #{}, pids = #{},
                 waiting = queue:new ()}).

start_link () ->
  gen_server:start_link ({local, ?MODULE}, ?MODULE, [], []).

%% @doc Call a core-EGTM operation `Operation' with
%% arguments `Args' via one of the pool workers.
perform (Operation, Args) ->
  case catch (gen_server:call (?MODULE, {op, Operation, Args})) of
    {'EXIT', X} -> {error, X};
    Result      -> Result
  end.

%% @doc Workers, their load and transaction reservations.
status () -> gen_server:call (?MODULE, status).

init (_Args) ->
  process_flag (trap_exit, true),
  ?report_info ("Starting up ~p...", [?MODULE]),
  Names = egtm_config:param ([egtm, workers, nodes]),
  {ok, lists:foldl (fun start_worker/2, #state{}, Names)}.

handle_call ({op, Op, Args}, From, State) ->
  {noreply, route (From, Op, Args, State)};
handle_call (status, _From, #state{workers = W, owners = O} = State) ->
  Workers = [ {N, maps:get (inflight, R), maps:get (owner, R)}
              || {N, R} <- lists:sort (maps:to_list (W)) ],
  {reply, [{workers, Workers}, {transactions, maps:size (O)},
           {waiting, queue:len (State#state.waiting)}], State}.

handle_cast (_Msg, State) ->
  {noreply, State}.

handle_info ({done, Name, From, Op, Result}, State) ->
  reply (From, Result),
  S1 = update_depth (Name, From, Op, Result,
         update_worker (Name, fun (#{inflight := I} = R) ->
                                R#{inflight := I-1} end, State)),
  {noreply, drain (progress (Name, S1))};

handle_info ({'DOWN', _Ref, process, Caller, _}, State) ->
  case State#state.owners of
    #{Caller := #{name := Name} = O} ->
      ?report_warning ({transaction_owner_died, Caller, Name}),
      Owners = (State#state.owners)#{Caller := O#{dead := true}},
      {noreply, drain (progress (Name, State#state{owners = Owners}))};
    _ ->
      {noreply, State}
  end;

handle_info ({'EXIT', Pid, Reason}, #state{pids = Pids} = State) ->
  case Pids of
    #{Pid := Name} ->
      ?report_warning ({worker_down, Name, Reason}),
      erlang:send_after (?RESTART_DELAY, self (), {restart, Name}),
      {noreply, drain (drop_worker (Name, State))};
    _ ->
      {noreply, State}
  end;

handle_info ({restart, Name}, State) ->
  {noreply, drain (start_worker (Name, State))};

handle_info (_Info, State) ->
  {noreply, State}.

terminate (_Reason, #state{pids = Pids}) ->
  [ catch (peer:stop (Pid)) || Pid <- maps:keys (Pids) ],
  ok;
terminate (_Reason, _State) ->
  ok.

code_change (_OldVsn, State, _Extra) ->
  {ok, State}.

%% --- Workers ---------

start_worker (Name, #state{workers = W, pids = Pids} = State) ->
  case start_peer () of
    {ok, Pid} ->
      ?report_info ("EGTM pool worker ~p started", [Name]),
      State#state{
        workers = W#{Name => #{pid => Pid, inflight => 0,
                               owner => undefined, pending => none}},
        pids = Pids#{Pid => Name}};
    Error ->
      ?report_error ({worker_start_failed, Name, Error}),
      erlang:send_after (?RESTART_DELAY, self (), {restart, Name}),
      State
  end.

start_peer () ->
  %% Same code paths as this node, minus OTP's own
  Root = code:root_dir (),
  Paths = [ P || P <- code:get_path (), not lists:prefix (Root, P) ],
  case catch (peer:start_link (#{connection => standard_io,
                 args => ["-egtm", "role", "worker", "-pa" | Paths]})) of
    {ok, Pid, _Node} ->
      case catch (peer:call (Pid, egtm, start, [], 60000)) of
        ok    -> {ok, Pid};
        Error -> catch (peer:stop (Pid)), {error, Error}
      end;
    Error ->
      {error, Error}
  end.

drop_worker (Name, #state{workers = W, owners = O, pids = Pids} = State) ->
  #{Name := #{pid := Pid, owner := Owner, pending := Pending}} = W,
  case Pending of
    {From, _} -> reply (From, {error, {worker_down, Name}});
    none      -> ok
  end,
  Owners = case O of
    #{Owner := #{mref := MRef}} ->
      erlang:demonitor (MRef, [flush]), maps:remove (Owner, O);
    _ -> O
  end,
  State#state{workers = maps:remove (Name, W), owners = Owners,
              pids = maps:remove (Pid, Pids)}.

update_worker (Name, Fun, #state{workers = W} = State) ->
  case W of
    #{Name := R} -> State#state{workers = W#{Name := Fun (R)}};
    _            -> State
  end.

%% --- Routing ---------

route (From, Op, Args, #state{workers = W, owners = O} = State) ->
  {Caller, _} = From,
  case O of
    #{Caller := #{name := Name}} ->
      case W of
        #{Name := _} -> dispatch (Name, From, Op, Args, State);
        _            -> reply (From, {error, {worker_down, Name}}),
                        State
      end;
    _ when Op =:= tcommit; Op =:= trollback ->
      %% Would drive the worker's TP level negative
      reply (From, {error, no_transaction}), State;
    _ when map_size (W) =:= 0 ->
      reply (From, {error, no_workers}), State;
    _ ->
      case free_workers (State) of
        [] ->
          Waiting = queue:in ({From, Op, Args}, State#state.waiting),
          State#state{waiting = Waiting};
        Free when Op =:= tstart ->
          reserve (least_loaded (Free, State), From, Args, State);
        Free ->
          dispatch (lists:nth (rand:uniform (length (Free)), Free),
                    From, Op, Args, State)
      end
  end.

free_workers (#state{workers = W}) ->
  [ N || {N, #{owner := undefined}} <- maps:to_list (W) ].

least_loaded (Names, #state{workers = W}) ->
  {_, Name} = lists:min ([ {maps:get (inflight, maps:get (N, W)), N}
                           || N <- Names ]),
  Name.

%% Reserve a worker for `Caller'; its `tstart' is sent once all
%% requests already in flight there have completed.
reserve (Name, {Caller, _} = From, Args, State) ->
  MRef = erlang:monitor (process, Caller),
  Owner = #{name => Name, depth => 0, mref => MRef, dead => false},
  S1 = update_worker (Name, fun (R) ->
         R#{owner := Caller, pending := {From, Args}} end,
       State#state{owners = (State#state.owners)#{Caller => Owner}}),
  progress (Name, S1).

dispatch (Name, From, Op, Args, State) ->
  Pool = self (),
  #{Name := #{pid := Pid}} = State#state.workers,
  spawn (fun () ->
    Result = case catch (peer:call (Pid, egtm_worker, perform,
                                    [Op, Args], infinity)) of
      {'EXIT', Error} -> {error, {worker_call, Error}};
      Res             -> Res
    end,
    Pool ! {done, Name, From, Op, Result}
  end),
  update_worker (Name, fun (#{inflight := I} = R) ->
                         R#{inflight := I+1} end, State).

%% Transaction depth of the worker's owner, after a completed request
%% (void operations such as `tstart' reply a bare `ok')
update_depth (_Name, _From, _Op, {error, _}, State) ->
  State;
update_depth (Name, {Caller, _}, Op, _Ok, #state{owners = O} = State)
    when Op =:= tstart; Op =:= tcommit; Op =:= trollback ->
  case O of
    #{Caller := #{name := Name, depth := D} = Owner} ->
      D1 = case Op of tstart -> D+1; _ -> max (0, D-1) end,
      State#state{owners = O#{Caller := Owner#{depth := D1}}};
    _ -> State
  end;
update_depth (_Name, _From, _Op, _Result, State) ->
  State.

%% Move a reserved worker forward once nothing is in flight there:
%% send a pending `tstart', roll back after a dead owner,
%% or release the worker when the transaction is over.
progress (Name, #state{workers = W, owners = O} = State) ->
  case W of
    #{Name := #{inflight := 0, owner := Owner, pending := Pending}}
        when Owner =/= undefined ->
      #{Owner := #{depth := D, dead := Dead}} = O,
      case {Pending, Dead, D} of
        {{From, Args}, false, _} ->
          dispatch (Name, From, tstart, Args, update_worker (Name,
            fun (R) -> R#{pending := none} end, State));
        {{From, _}, true, _} ->
          release (Name, update_worker (Name,
            fun (R) -> R#{pending := none} end, State), From);
        {none, true, D} when D > 0 ->
          dispatch (Name, {Owner, rollback}, trollback, [], State);
        {none, _, 0} ->
          release (Name, State, none);
        _ ->
          State
      end;
    _ ->
      State
  end.

release (Name, State, PendingFrom) ->
  case PendingFrom of
    none -> ok;
    _    -> reply (PendingFrom, {error, caller_down})
  end,
  #{Name := #{owner := Owner}} = State#state.workers,
  #{Owner := #{mref := MRef}} = State#state.owners,
  erlang:demonitor (MRef, [flush]),
  update_worker (Name, fun (R) -> R#{owner := undefined} end,
    State#state{owners = maps:remove (Owner, State#state.owners)}).

%% Retry queued requests while there are unreserved workers.
drain (#state{waiting = Q} = State) ->
  case {free_workers (State), queue:out (Q)} of
    {[_|_], {{value, {From, Op, Args}}, Q1}} ->
      drain (route (From, Op, Args, State#state{waiting = Q1}));
    _ ->
      State
  end.

reply ({_, rollback}, _Result) -> ok;
reply (From, Result) -> gen_server:reply (From, Result).

%% --- EUnit tests ---------
%% Run with `rebar3 as pool eunit --module=egtm_pool'
%% (without EGTM_POOL_ENABLED, egtm never starts the pool).
-ifdef (TEST).
-ifdef (EGTM_POOL_ENABLED).
-include_lib ("eunit/include/eunit.hrl").

pool_test_ () ->
  {setup,
   fun () ->
     Conf = [{egtm, [{mode, pool},
                     {workers, [{nodes, [egtmt1, egtmt2]}]}]}],
     application:load (egtm),
     application:set_env (egtm, config, Conf),
     ok = egtm:start (),
     egtm:kill ("^EUnitPool")
   end,
   fun (_) -> egtm:kill ("^EUnitPool"), egtm:stop () end,
   {timeout, 60, [fun pool_basic/0, fun pool_spread/0,
                  fun pool_tx_isolation/0, fun pool_tx_owner_death/0,
                  fun pool_no_transaction/0, fun pool_worker_restart/0]}}.

pool_basic () ->
  ?assertEqual (ok, egtm:set ("^EUnitPool", ["basic"], "abc")),
  ?assertEqual ("abc", egtm:get ("^EUnitPool", ["basic"])),
  {ok, commit, done} = egtm_util:transaction (fun () ->
    egtm:set ("^EUnitPool", ["tx"], "committed"), true end),
  ?assertEqual ("committed", egtm:get ("^EUnitPool", ["tx"])).

%% Requests reach more than one worker process ($Job)
pool_spread () ->
  Jobs = lists:usort ([ egtm:perform (job, []) || _ <- lists:seq (1, 50) ]),
  ?assertEqual (2, length (Jobs)).

%% Writes of other callers are not swallowed by an open transaction
pool_tx_isolation () ->
  Self = self (),
  A = spawn (fun () ->
    egtm:tstart (),
    egtm:set ("^EUnitPool", ["iso", "a"], "A"),
    Self ! {a_open, egtm:perform (job, [])},
    receive go -> egtm:trollback () end,
    Self ! a_done
  end),
  JobA = receive {a_open, J} -> J end,
  %% Everybody else is routed away from A's worker
  Others = lists:usort ([ egtm:perform (job, []) || _ <- lists:seq (1, 20) ]),
  ?assertNot (lists:member (JobA, Others)),
  ?assertEqual (ok, egtm:set ("^EUnitPool", ["iso", "b"], "B")),
  A ! go, receive a_done -> ok end,
  ?assertEqual ([], egtm:get ("^EUnitPool", ["iso", "a"])),
  ?assertEqual ("B", egtm:get ("^EUnitPool", ["iso", "b"])).

%% A transaction of a dead caller is rolled back, the worker released
pool_tx_owner_death () ->
  Self = self (),
  {Pid, MRef} = spawn_monitor (fun () ->
    egtm:tstart (),
    egtm:set ("^EUnitPool", ["dead"], "X"),
    Self ! open,
    receive never -> ok end
  end),
  receive open -> ok end,
  exit (Pid, kill),
  receive {'DOWN', MRef, process, Pid, _} -> ok end,
  wait_until (fun () ->
    proplists:get_value (transactions, status ()) =:= 0 end),
  ?assertEqual ([], egtm:get ("^EUnitPool", ["dead"])),
  %% ...and its worker accepts plain writes again
  Keys = [ integer_to_list (N) || N <- lists:seq (1, 10) ],
  [ egtm:set ("^EUnitPool", ["after", K], "ok") || K <- Keys ],
  ?assertEqual (lists:duplicate (10, "ok"),
    [ egtm:get ("^EUnitPool", ["after", K]) || K <- Keys ]).

pool_no_transaction () ->
  ?assertEqual ({error, no_transaction}, perform (tcommit, [])).

pool_worker_restart () ->
  [{workers, [{Name, _, _} | _]} | _] = status (),
  #{pid := Pid} = maps:get (Name, (sys:get_state (?MODULE))#state.workers),
  exit (Pid, kill),
  wait_until (fun () ->
    case (sys:get_state (?MODULE))#state.workers of
      #{Name := #{pid := NewPid}} = W ->
        map_size (W) =:= 2 andalso NewPid =/= Pid;
      _ -> false
    end end),
  ?assertEqual ("abc", egtm:get ("^EUnitPool", ["basic"])).

wait_until (Fun) -> wait_until (Fun, 100).
wait_until (Fun, 0) -> ?assert (Fun ());
wait_until (Fun, N) ->
  case Fun () of
    true -> ok;
    _    -> timer:sleep (100), wait_until (Fun, N-1)
  end.

-endif.
-endif.

%% vim: fdm=syntax:fdn=3:tw=74:ts=2:syn=erlang
