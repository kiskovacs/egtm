%%
%% $Id: $
%%
%% Module:  egtm_cache -- $Get cache with per-key expiration
%% Created: 21-OCT-2026
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

%% @doc A minimal ETS replacement of the `ecache' application
%% (which no longer compiles on current Erlang/OTP) used by
%% the `[egtm, optimize, get_cache]' optimization.
%% Expired entries are dropped lazily on `load/1'.
-module (egtm_cache).
-export ([init/0, load/1, store/3, delete/1, flush/0]).

-define (TABLE, ?MODULE).

%% @doc Create the cache table. The calling process becomes
%% its owner, so call it from a process that lives as long
%% as the cache is needed (`egtm:start/2').
init () ->
  case ets:whereis (?TABLE) of
    undefined ->
      ets:new (?TABLE, [named_table, public, set,
        {read_concurrency, true}]),
      ok;
    _ -> ok
  end.

%% @doc Look `Key' up. Returns `{ok, Value}' or `undefined'.
load (Key) ->
  Now = erlang:monotonic_time (second),
  case ets:lookup (?TABLE, Key) of
    [{Key, Value, Expires}] when Expires > Now -> {ok, Value};
    [_] -> ets:delete (?TABLE, Key), undefined;
    []  -> undefined
  end.

%% @doc Store `Value' under `Key' for `TimeOut' seconds.
store (Key, Value, TimeOut) ->
  Expires = erlang:monotonic_time (second) + TimeOut,
  ets:insert (?TABLE, {Key, Value, Expires}),
  ok.

delete (Key) -> ets:delete (?TABLE, Key), ok.

flush () -> ets:delete_all_objects (?TABLE), ok.

%% vim: fdm=syntax:fdn=3:tw=74:ts=2:syn=erlang
