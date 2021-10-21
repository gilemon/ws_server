-module(context).

-export([new/0, new/1, get/1, get/2, set/1, set/2, delete/0, delete/1]).

-define(CONTEXT, list_to_atom(pid_to_list(self()))).

new() ->
	ets:new(?CONTEXT, [set, protected, named_table, {keypos, 1}]).

new(Name) ->
	ets:new(Name, [set, protected, named_table, {keypos, 1}]).

get(Key) ->
	ets:lookup(?CONTEXT, Key).

get(Name, Key) ->
	ets:lookup(Name, Key).

set({Key, Value}) ->
	ets:insert(?CONTEXT, {Key, Value}).

set(Name, {Key, Value}) ->
	ets:insert(Name, {Key, Value}).

delete() ->
	ets:delete(?CONTEXT).

delete(Name) ->
	ets:delete(Name).
