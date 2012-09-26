%% Copyright (c) 2012 Robert Virding. All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.

%% File    : luerl_emul.erl
%% Author  : Robert Virding
%% Purpose : A very basic LUA 5.2 machine emulator.

%% First version of emulator. Compiler so far only explicitly handles
%% local/global variables.
%%
%% Issues: how should we handle '...'? Now we treat it as any (local)
%% variable.

-module(luerl_emul).

-include("luerl.hrl").

%% Basic interface.
-export([init/0,call/2,call/3,chunk/2,chunk/3,funchunk/2,funchunk/3,gc/1]).

%% Internal functions which can be useful "outside".
-export([alloc_table/2,functioncall/3,get_table_key/3,
	 getmetamethod/3,getmetamethod/4]).

%% Currently unused internal functions, to suppress warnings.
-export([alloc_table/1,set_local_keys/3,set_local_keys_tab/3,
	 get_local_key/2,set_env_name_env/4]).

-import(luerl_lib, [lua_error/1,badarg_error/2]).

%% -compile(inline).				%For when we are optimising
%% -compile({inline,[is_true_value/1,first_value/1]}).

%%-define(DP(F,As), io:format(F, As)).
-define(DP(F, A), ok).

%% init() -> State.
%% Initialise the basic state.

init() ->
    St0 = #luerl{meta=#meta{},env=[],locf=false,tag=make_ref()},
    %% Initialise the table handling.
    St1 = St0#luerl{tabs=?MAKE_TABLE(),free=[],next=0},
    %% Initialise the stack and frame handling.
    St2 = St1#luerl{st=[],ft=array:new(),ff=[],fn=0},
    %% Allocate the _G table and initialise the environment
    {_G,St3} = luerl_basic:install(St2),	%Global environment
    St4 = St3#luerl{g=_G},
    %% Set _G variable to point to it.
    St5 = set_global_name('_G', _G, St4),
    %% Add the other standard libraries.
    St6 = alloc_libs([{<<"math">>,luerl_math},
		      {<<"io">>,luerl_io},
		      {<<"os">>,luerl_os},
		      {<<"string">>,luerl_string},
		      {<<"table">>,luerl_table}], St5),
    St6.

alloc_libs(Libs, St) ->
    Fun = fun ({Key,Mod}, St0) ->
		  {T,St1} = Mod:install(St0),
		  set_global_key(Key, T, St1)
	  end,
    lists:foldl(Fun, St, Libs).

%% set_global_name(Name, Value, State) -> State.
%% set_global_key(Key, Value, State) -> State.
%% get_global_name(Name, State) -> {[Val],State}.
%% get_global_key(Key, State) -> {[Val],State}.
%%  Access elements in the global name table, _G.

set_global_name(Name, Val, St) ->
    set_global_key(atom_to_binary(Name, latin1), Val, St).

set_global_key(Key, Val, #luerl{g=G}=St) ->
    set_table_key(G, Key, Val, St).

get_global_name(Name, St) ->
    get_global_key(atom_to_binary(Name, latin1), St).

get_global_key(Key, #luerl{g=G}=St) ->
    get_table_key(G, Key, St).

%% push_frame(Size, State) -> State.
%% pop_frame(State) -> State.
%% pop_free_frame(State) -> State.

push_frame(Sz, #luerl{st=Fps,ft=Ft0,ff=[N|Ns]}=St) ->
    Ft1 = array:set(N, erlang:make_tuple(Sz, nil), Ft0),
    St#luerl{st=[#fref{i=N}|Fps],ft=Ft1,ff=Ns};
push_frame(Sz, #luerl{st=Fps,ft=Ft0,ff=[],fn=N}=St) ->
    Ft1 = array:set(N, erlang:make_tuple(Sz, nil), Ft0),
    St#luerl{st=[#fref{i=N}|Fps],ft=Ft1,fn=N+1}.

pop_frame(#luerl{st=[#fref{i=N}|Fps],ff=Ns}=St) ->
    St#luerl{st=Fps,ff=[N|Ns]}.

pop_free_frame(#luerl{st=[#fref{i=N}|Fps],ft=Ft0,ff=Ns}=St) ->
    Ft1 = array:reset(N, Ft0),			%Free the frame
    St#luerl{st=Fps,ft=Ft1,ff=[N|Ns]}.

%% alloc_table(State) -> {Tref,State}.
%% alloc_table(InitialTable, State) -> {Tref,State}.
%% free_table(Tref, State) -> State.
%%  The InitialTable is [{Key,Value}], there is no longer any need to
%%  have it as an orddict.

alloc_table(St) -> alloc_table([], St).

alloc_table(Itab, #luerl{tabs=Ts0,free=[N|Ns]}=St) ->
    T = init_table(Itab),
    %% io:fwrite("it1: ~p\n", [{N,T}]),
    Ts1 = ?SET_TABLE(N, T, Ts0),
    {#tref{i=N},St#luerl{tabs=Ts1,free=Ns}};
alloc_table(Itab, #luerl{tabs=Ts0,free=[],next=N}=St) ->
    T = init_table(Itab),
    %% io:fwrite("it2: ~p\n", [{N,T}]),
    Ts1 = ?SET_TABLE(N, T, Ts0),
    {#tref{i=N},St#luerl{tabs=Ts1,next=N+1}}.

init_table(Itab) ->
    T0 = orddict:new(),
    A0 = array:new([{default,nil}]),		%Arrays with 'nil' as default
    Init = fun ({_,nil}, {T,A}) -> {T,A};	%Ignore nil values
	       ({K,V}, {T,A}) when is_number(K) ->
		   case ?IS_INTEGER(K, I) of
		       true when I >= 1 -> {T,array:set(I, V, A)};
		       _NegFalse -> {orddict:store(K, V, T),A}
		   end;
	       ({K,V}, {T,A}) -> {orddict:store(K, V, T),A}
	   end,
    {T1,A1} = lists:foldl(Init, {T0,A0}, Itab),
    #table{a=A1,t=T1,m=nil}.

free_table(#tref{i=N}, #luerl{tabs=Ts0,free=Ns}=St) ->
    %% io:fwrite("ft: ~p\n", [{N,?GET_TABLE(N, Ts0)}]),
    Ts1 = ?DEL_TABLE(N, Ts0),
    St#luerl{tabs=Ts1,free=[N|Ns]}.

%% set_table_name(Tref, Name, Value, State) -> State.
%% set_table_key(Tref, Key, Value, State) -> State.
%% get_table_name(Tref, Name, State) -> {[Val],State}.
%% get_table_key(Tref, Key, State) -> {[Val],State}.
%%  Access tables, as opposed to the environment (which are also
%%  tables). Setting a value to 'nil' will clear it from the array but
%%  not from the table; however, we won't add a nil value. NOTE: WE
%%  ALWAYS RETURN A LIST OF VALUES GET AS METAMETHOD MY DO SO AND WE
%%  DON'T WANT TO PRE-SUPPOSE HOW THE VALUE IS TO BE USED!

set_table_name(Tab, Name, Val, St) ->
    set_table_key(Tab, atom_to_binary(Name, latin1), Val, St).

set_table_key(#tref{}=Tref, Key, Val, St) when is_number(Key) ->
    case ?IS_INTEGER(Key, I) of
	true when I >= 1 -> set_table_int_key(Tref, Key, I, Val, St);
	_NegFalse -> set_table_key_key(Tref, Key, Val, St)
    end;
set_table_key(#tref{}=Tref, Key, Val, St) ->
    set_table_key_key(Tref, Key, Val, St);
set_table_key(Tab, Key, _, _) ->
    lua_error({illegal_index,Tab,Key}).

set_table_key_key(#tref{i=N}, Key, Val, #luerl{tabs=Ts0}=St) ->
    #table{t=Tab0,m=Meta}=T = ?GET_TABLE(N, Ts0),	%Get the table
    case orddict:find(Key, Tab0) of
	{ok,_} ->			    %Key exists
	    %% Don't delete key for nil here!
	    Tab1 = orddict:store(Key, Val, Tab0),
	    Ts1 = ?SET_TABLE(N, T#table{t=Tab1}, Ts0),
	    St#luerl{tabs=Ts1};
	error ->				%Key does not exist
	    case getmetamethod_tab(Meta, <<"__newindex">>, Ts0) of
		nil ->
		    %% Only add non-nil value.
		    Tab1 = if Val =:= nil -> Tab0;
			      true -> orddict:store(Key, Val, Tab0)
			   end,
		    Ts1 = ?SET_TABLE(N, T#table{t=Tab1}, Ts0),
		    St#luerl{tabs=Ts1};
		Meth when element(1, Meth) =:= function ->
		    functioncall(Meth, [Key,Val], St);
		Meth -> set_table_key(Meth, Key, Val, St)
	    end
    end.

set_table_int_key(#tref{i=N}, Key, I, Val, #luerl{tabs=Ts0}=St) ->
    #table{a=Arr0,m=Meta}=T = ?GET_TABLE(N, Ts0),	%Get the table
    case array:get(I, Arr0) of
	nil ->					%Key does not exist
	    case getmetamethod_tab(Meta, <<"__newindex">>, Ts0) of
		nil ->
		    %% Only add non-nil value, slightly faster (?)
		    Arr1 = if Val =:= nil -> Arr0;
			      true -> array:set(I, Val, Arr0)
			   end,
		    Ts1 = ?SET_TABLE(N, T#table{a=Arr1}, Ts0),
		    St#luerl{tabs=Ts1};
		Meth when element(1, Meth) =:= function ->
		    functioncall(Meth, [Key,Val], St);
		Meth -> set_table_key(Meth, Key, Val, St)
	    end;
	_ ->					%Key exists
	    %% Can do this as 'nil' is default value of array.
	    Arr1 = array:set(I, Val, Arr0),
	    Ts1 = ?SET_TABLE(N, T#table{a=Arr1}, Ts0),
	    St#luerl{tabs=Ts1}
    end.

get_table_name(Tab, Name, St) ->
    get_table_key(Tab, atom_to_binary(Name, latin1), St).

get_table_key(#tref{}=Tref, Key, St) when is_number(Key) ->
    case ?IS_INTEGER(Key, I) of
	true when I >= 1 -> get_table_int_key(Tref, Key, I, St);
	_NegFalse -> get_table_key_key(Tref, Key, St)
    end;
get_table_key(#tref{}=Tref, Key, St) ->
    get_table_key_key(Tref, Key, St);
get_table_key(Tab, Key, St) ->			%Just find the metamethod
    case getmetamethod(Tab, <<"__index">>, St) of
	nil -> lua_error({illegal_index,Tab,Key});
	Meth when element(1, Meth) =:= function ->
	    {Vs,St1} = functioncall(Meth, [Tab,Key], St),
	    {Vs,St1};
	Meth ->					%Recurse down the metatable
	    get_table_key(Meth, Key, St)
    end.

get_table_key_key(#tref{i=N}=T, Key, #luerl{tabs=Ts}=St) ->
    #table{t=Tab,m=Meta} = ?GET_TABLE(N, Ts),	%Get the table.
    case orddict:find(Key, Tab) of
	{ok,Val} -> {[Val],St};
	error ->
	    %% Key not present so try metamethod
	    get_table_metamethod(T, Meta, Key, Ts, St)
    end.

get_table_int_key(#tref{i=N}=T, Key, I, #luerl{tabs=Ts}=St) ->
    #table{a=A,m=Meta} = ?GET_TABLE(N, Ts),	%Get the table.
    case array:get(I, A) of
	nil ->
	    %% Key not present so try metamethod
	    get_table_metamethod(T, Meta, Key, Ts, St);
	Val -> {[Val],St}
    end.

get_table_metamethod(T, Meta, Key, Ts, St) ->
    case getmetamethod_tab(Meta, <<"__index">>, Ts) of
	nil -> {[nil],St};
	Meth when element(1, Meth) =:= function ->
	    {Vs,St1} = functioncall(Meth, [T,Key], St),
	    {Vs,St1};
	Meth ->				%Recurse down the metatable
	    get_table_key(Meth, Key, St)
    end.

%% set_local_name(Name, Val, State) -> State.
%% set_local_key(Key, Value, State) -> State.
%% set_local_keys(Keys, Values, State) -> State.
%% get_local_key(Key, State) -> Value | nil.
%%  Set variable values in the local environment. Variables are not
%%  cleared when their value is set to 'nil' as this would remove the
%%  local variable. NOTE: ONLY RETURN A SINGLE VALUE AS THIS IS ALL A
%%  KEY MAY HAVE!

set_local_name(Name, Val, St) ->
    set_local_key(atom_to_binary(Name, latin1), Val, St).

set_local_key(Key, Val, #luerl{tabs=Ts0,env=Env}=St) ->
    Ts1 = set_local_key_env(Key, Val, Ts0, Env),
    St#luerl{tabs=Ts1}.

set_local_name_env(Name, Val, Ts, Env) ->
    set_local_key_env(atom_to_binary(Name, latin1), Val, Ts, Env).

set_local_key_env(K, Val, Ts, [#tref{i=E}|_]) ->
    Store = fun (#table{t=Tab}=T) -> T#table{t=orddict:store(K, Val, Tab)} end,
    ?UPD_TABLE(E, Store, Ts).

set_local_keys(Ks, Vals, #luerl{tabs=Ts0,env=[#tref{i=E}|_]}=St) ->
    Store = fun (#table{t=Tab}=T) ->
		    T#table{t=set_local_keys_tab(Ks, Vals, Tab)} end,
    Ts1 = ?UPD_TABLE(E, Store, Ts0),
    St#luerl{tabs=Ts1}.

set_local_keys_tab([K|Ks], [Val|Vals], T0) ->
    T1 = orddict:store(K, Val, T0),
    set_local_keys_tab(Ks, Vals, T1);
set_local_keys_tab([K|Ks], [], T0) ->
    T1 = orddict:store(K, nil, T0),		%Default value nil
    set_local_keys_tab(Ks, [], T1);
set_local_keys_tab([], _, T) -> T.		%Ignore extra values

get_local_key(Key, #luerl{tabs=Ts,env=[#tref{i=E}|_]}) ->
    #table{t=Tab} = ?GET_TABLE(E, Ts),
    case orddict:find(Key, Tab) of
	{ok,Val} -> Val;
	error -> nil
    end.

%% set_env_name(Name, Val, State) -> State.
%% set_env_key(Key, Value, State) -> State.
%% set_env_key_env(Key, Value, Tables, Env) -> Tables.
%% get_env_name(Name, State) -> Val.
%% get_env_key(Key, State) -> Value | nil.
%% get_env_key_env(Key, Tables, Env) -> Value | nil.
%%  Set/get variable values in the environment tables. Variables are
%%  not cleared when their value is set to 'nil' as this would move
%%  them in the environment stack. NOTE: ONLY RETURN A SINGLE VALUE AS
%%  THIS IS ALL A KEY MAY HAVE!

set_env_name(Name, Val, St) ->
    set_env_key(atom_to_binary(Name, latin1), Val, St).

set_env_name_env(Name, Val, Ts, Env) ->
    %% io:fwrite("sek: ~p\n", [{Env}]),
    set_env_key_env(atom_to_binary(Name, latin1), Val, Ts, Env).

set_env_key(K, Val, #luerl{tabs=Ts0,env=Env}=St) ->
    %% io:fwrite("sek: ~p\n", [{Env}]),
    Ts1 = set_env_key_env(K, Val, Ts0, Env),
    St#luerl{tabs=Ts1}.

set_env_key_env(K, Val, Ts, [#tref{i=_G}]) ->	%Top table _G
    Store = fun (#table{t=Tab}=T) ->
		    T#table{t=orddict:store(K, Val, Tab)} end,
    ?UPD_TABLE(_G, Store, Ts);
set_env_key_env(K, Val, Ts, [#tref{i=E}|Es]) ->
    %% io:fwrite("seke: ~p\n", [{K,Val,E,?GET_TABLE(E, Ts)}]),
    #table{t=Tab} = ?GET_TABLE(E, Ts),		%Find the table
    case orddict:is_key(K, Tab) of
	true ->
	    Store = fun (#table{t=Tab}=T0) ->
			    T0#table{t=orddict:store(K, Val, Tab)} end,
	    ?UPD_TABLE(E, Store, Ts);
	false -> set_env_key_env(K, Val, Ts, Es)
    end.

get_env_name(Name, St) -> get_env_key(atom_to_binary(Name, latin1), St).

get_env_key(K, #luerl{tabs=Ts,env=Env}) ->
    get_env_key_env(K, Ts, Env).

get_env_key_env(K, Ts, [#tref{i=E}|Es]) ->
    #table{t=Tab} = ?GET_TABLE(E, Ts),		%Get environment table
    case orddict:find(K, Tab) of		%Check if variable in the env
	{ok,Val} -> Val;
	error -> get_env_key_env(K, Ts, Es)
    end;
get_env_key_env(_, _, []) -> nil.		%The default value

%% set_var(Var, Val, State) -> State.
%% set_local_var(Var, Val, State) -> State.
%% get_var(Var, State) -> Value | nil.

set_var({local_var,_,_,I}, Val, #luerl{st=Fps,ft=Ft0}=St) ->
    Ft1 = set_local_var(I, Val, Fps, Ft0),
    St#luerl{ft=Ft1};
set_var({stack_var,_,_,D,I}, Val, #luerl{st=Fps,ft=Ft0}=St) ->
    Ft1 = set_stack_var(D, I, Val, Fps, Ft0),
    St#luerl{ft=Ft1};
set_var({global_var,_,N}, Val, #luerl{tabs=Ts0,g=#tref{i=G}}=St) ->
    Key = atom_to_binary(N, latin1),
    Store = fun (#table{t=Tab}=T) ->
    		    T#table{t=orddict:store(Key, Val, Tab)} end,
    Ts1 = ?UPD_TABLE(G, Store, Ts0),
    St#luerl{tabs=Ts1}.

set_local_var({local_var,_,_,I}, Val, #luerl{st=Fps,ft=Ft0}=St) ->
    Ft1 = set_local_var(I, Val, Fps, Ft0),
    St#luerl{ft=Ft1}.

get_var({local_var,_,_,I}, #luerl{st=Fps,ft=Ft}) ->
    get_local_var(I, Fps, Ft);
get_var({stack_var,_,_,D,I}, #luerl{st=Fps,ft=Ft}) ->
    get_stack_var(D, I, Fps, Ft);
get_var({global_var,_,N}, #luerl{tabs=Ts,g=#tref{i=G}}) ->
    #table{t=Tab} = ?GET_TABLE(G, Ts),
    case orddict:find(atom_to_binary(N, latin1), Tab) of
	{ok,Val} -> Val;
	error -> nil
    end.

get_local_var(I, [#fref{i=N}|_], Ft) ->
    element(I, array:get(N, Ft)).

get_stack_var(D, I, Fps, Ft) ->
    #fref{i=N} = lists:nth(D, Fps),
    element(I, array:get(N, Ft)).

set_local_var(I, V, [#fref{i=N}|_], Ft) ->
    F = setelement(I, array:get(N, Ft), V),
    array:set(N, F, Ft).

set_stack_var(D, I, V, Fps, Ft) ->
    #fref{i=N} = lists:nth(D, Fps),
    F = setelement(I, array:get(N, Ft), V),
    array:set(N, F, Ft).

%% chunk(Chunk, State) -> {Return,State}.
%% chunk(Chunk, Args, State) -> {Return,State}.

chunk(Chunk, St) -> chunk(Chunk, [], St).
chunk(Chunk, Args, St) -> call(Chunk, Args, St).

%% call(Chunk, State) -> {Return,State}.
%% call(Chunk, Args, State) -> {Return,State}.

call(Chunk, St) -> call(Chunk, [], St).

call({functiondef,L,Sz,Ps,B}, Args, St0) ->
    %% Generate function and call it.
    {[Func],St1} = exp({functiondef,L,Sz,Ps,B}, St0),
    {Ret,St2} = functioncall(Func, Args, St1),
    %% Should do GC here.
    {Ret,St2};
call({functiondef,L,Sz,_,Ps,B}, Args, St0) ->
    %% Generate function and call it.
    {[Func],St1} = exp({functiondef,L,Sz,Ps,B}, St0),
    {Ret,St2} = functioncall(Func, Args, St1),
    %% Should do GC here.
    {Ret,St2};
call({function,_}=Func, Args, St0) ->
    {Ret,St1} = functioncall(Func, Args, St0),
    %% Should do GC here.
    {Ret,St1}.

%% funchunk(Function, State) -> {Return,State}.

funchunk({functiondef,_Line,Sz,_Name,_Pars,Body}, St0) ->
    {Ret,St1} = function_block(Sz,fun (S) -> {[],stats(Body, S)} end, St0),
    %% Should do GC here.
    {Ret,St1};

funchunk({functiondef,_Line,Sz,_Pars,Body}, St0) ->
    {Ret,St1} = function_block(Sz, fun (S) -> {[],stats(Body, S)} end, St0),
    %% Should do GC here.
    {Ret,St1}.

funchunk(Func, St0, _Pars) ->           %Todo: Parameters.
    funchunk(Func, St0).                %Note: from ERLANG. And the functiondef
                                        %is a wrap around ALL chunks except
                                        %those that already were functions.

%% block(Size, Stats, State) -> State.
%%  Evaluate statements in a block. The with_block function requires
%%  that its action returns a result, which is irrelevant here.

block(_, [], St) -> St;				%Empty block, do nothing
block(Sz, Stats, St0) ->
    Do = fun (S) -> {[],stats(Stats, S)} end,
    {_,St1} = with_block(Sz, Do, St0),
    St1.

block(_, _) ->
    error({boom,block}).

%% with_block(Size, Do, State) -> {Return,State}.
%%  A block creates a new local environment which we would like to
%%  remove afterwards. We can only do this if there are no local
%%  functions defined within this block or sub-blocks. The 'locf'
%%  field is set to 'true' when this occurs.

with_block(Sz, Do, St0) ->
    Locf0 = St0#luerl.locf,			%"Global" locf value
    St1 = push_frame(Sz, St0),
    %% io:fwrite("wb: ~p\n", [{Locf0}]),
    {Ret,St2} = Do(St1#luerl{locf=false}),	%Do its thing
    Locf1 = St2#luerl.locf,			%"Local" locf value
    %% io:fwrite("wb->~p\n", [{Locf1}]),
    St3  = case Locf1 of			%Check if we can free table
	       true -> pop_frame(St2);
	       false -> pop_free_frame(St2)
	   end,
    {Ret,St3#luerl{locf=Locf1 or Locf0}}.

with_block(_, _) ->
    error({boom,with_block}).

%% stats(Stats, State) -> State.

stats([S|Ss], St0) ->
    %% io:format("ss: ~p\n", [{S}]),
    St1 = stat(S, St0),
    stats(Ss, St1);
stats([], St) -> St.

%% stat(Stat, State) -> State.

stat({';',_}, St) -> St;			%A no-op
stat({assign,_,Vs,Es}, St) ->
     assign(Vs, Es, St);
stat({return,L,Es}, #luerl{tag=Tag}=St0) ->
    {Vals,St1} = explist(Es, St0),
    throw({return,L,Tag,Vals,St1});
stat({label,_,_}, _) ->				%Not implemented yet
    lua_error({undefined_op,label});
stat({break,L}, #luerl{tag=T}=St) ->
    %% io:fwrite("br: ~p\n", [{St#luerl.locf}]),
    throw({break,L,T,St});			%Easier match with explicit tag
stat({goto,_,_}, _) ->				%Not implemented yet
    lua_error({undefined_op,goto});
stat({block,_,Sz,B}, St) ->
    block(Sz, B, St);
stat({functiondef,L,Sz,V,Ps,B}, St0) ->
    {[F],St1} = exp({functiondef,L,Sz,Ps,B}, St0),
    assign_var(V, F, St1);
stat({'while',_,Exp,Sz,Body}, St) ->
    do_while(Exp, Sz, Body, St);
stat({repeat,_,Sz,Body,Exp}, St) ->
    do_repeat(Sz, Body, Exp, St);
stat({'if',_,Tests,Else}, St) ->
    do_if(Tests, Else, St);
stat({for,_,V,I,L,S,Sz,B}, St) ->		%Numeric for
    do_numfor(V, I, L, S, Sz, B, St);
stat({for,_,Vs,Gen,Sz,B}, St) ->		%Generic for
    do_genfor(Vs, Gen, Sz, B, St);
stat({local,Decl}, St) ->
    %% io:format("sl: ~p\n", [Decl]),
    local(Decl, St);
stat(P, St0) ->
    %% These are just function calls here.
    {_,St1} = prefixexp(P, St0),		%Drop return value
    St1.

assign(Ns, Es, St0) ->
    {Vals,St1} = explist(Es, St0),
    assign_loop(Ns, Vals, St1).

assign_loop([Pre|Pres], [E|Es], St0) ->
    St1 = assign_var(Pre, E, St0),
    assign_loop(Pres, Es, St1);
assign_loop([Pre|Pres], [], St0) ->		%Set remaining to nil
    St1 = assign_var(Pre, nil, St0),
    assign_loop(Pres, [], St1);
assign_loop([], _, St) -> St.

%% assign_var(PrefixExp, Val, State) -> State.
%%  Step down the prefixexp sequence evaluating as we go, stop at the
%%  end and return a key and a table where to put data. We can reuse
%%  much of the prefixexp code but must have our own thing at the end.

assign_var({'.',_,Exp,Rest}, Val, St0) ->
    {Next,St1} = prefixexp_first(Exp, St0),
    assign_var_rest(Rest, Val, first_value(Next), St1);
assign_var(Var, Val, St) ->
    set_var(Var, Val, St).
    
assign_var_rest({'.',_,Exp,Rest}, Val, SoFar, St0) ->
    {Next,St1} = prefixexp_element(Exp, SoFar, St0),
    assign_var_rest(Rest, Val, first_value(Next), St1);
assign_var_rest(Exp, Val, SoFar, St) ->
    assign_var_last(Exp, Val, SoFar, St).

assign_var_last({'NAME',_,N}, Val, SoFar, St) ->
    set_table_name(SoFar, N, Val, St);
assign_var_last({key_field,_,Exp}, Val, SoFar, St0) ->
    {Key,St1} = exp(Exp, St0),
    set_table_key(SoFar, first_value(Key), Val, St1);
assign_var_last({method,_,{'NAME',_,N}}, {function,L,Sz,Stk,Pars,B}, SoFar, St) ->
    %% Method a function, make a "method" by adding self parameter.
    set_table_name(SoFar, N, {function,L,Sz,Stk,[{'NAME',L,self}|Pars],B}, St).

%% do_while(TestExp, Size, Body, State) -> State.

do_while(Exp, Sz, Body, St0) ->
    While = fun (St) -> while_loop(Exp, Sz, Body, St) end,
    {_,St1} = loop_block(While, St0),
    St1.

while_loop(Exp, Sz, Body, St0) ->
    {Test,St1} = exp(Exp, St0),
    case is_true_value(Test) of
	true ->
	    St2 = block(Sz, Body, St1),		%!!!!
	    while_loop(Exp, Sz, Body, St2);
	false -> {[],St1}
    end.

%% do_repeat(Size, Body, Exp, State) -> State.
%%  The Body includes the Exp as last element.

do_repeat(Sz, Body, Exp, St0) ->
    RepeatBody = fun (S0) ->			%Combine body with test
			 S1 = stats(Body, S0),
			 exp(Exp, S1)
		 end,
    Repeat = fun (St) -> repeat_loop(Sz, RepeatBody, St) end,
    {_,St1} = loop_block(Repeat, St0),		%element(2, ...)
    St1.

repeat_loop(Sz, Body, St0) ->
    {Ret,St1} = with_block(Sz, Body, St0),
    case is_true_value(Ret) of
	true -> {[],St1};
	false -> repeat_loop(Sz, Body, St1)
    end.

%% loop_block(DoLoop, State) -> State.
%%  The top level block to run loops in. Catch breaks here. Stack
%%  needs to be reset/unwound when we catch a break.

loop_block(Do, St) ->
    Block = fun (St0) ->
		    Tag = St0#luerl.tag,
		    try Do(St0)
		    catch
			throw:{break,_,Tag,St1} ->
			    %% Unwind the stack and freeing tables.
			    Old = St0#luerl.env,
			    St2 = unwind_stack(St1#luerl.env, Old, St1),
			    %% io:fwrite("lb: ~p\n", [{St0#luerl.locf,St1#luerl.locf,St2#luerl.locf}]),
			    {[],St2}
		    end
	    end,
    Block(St).
%%    with_block(Block, St).			%!!!!

%% do_if(Tests, Else, State) -> State.

do_if(Tests, Else, St) ->
    %% io:format("di: ~p\n", [{Tests,Else}]),
    %% io:format("di: ~p\n", [{St#luerl.locf}]),
    St1 = if_tests(Tests, Else, St),
    %% io:format("di->~p\n", [{St1#luerl.locf}]),
    St1.

if_tests([{Exp,Sz,Block}|Ts], Else, St0) ->
    {Test,St1} = exp(Exp, St0),			%What about the environment
    case is_true_value(Test) of
	true ->					%Test succeeded, do block
	    block(Sz, Block, St1);
	false ->				%Test failed, try again
	    if_tests(Ts, Else, St1)
    end;
if_tests([], {Sz,Else}, St) -> block(Sz,Else, St).

%% do_numfor(Var, Init, Limit, Step, Size, Block, State) -> State.
%%  The Var is relative the inner for block where it can be referenced.

do_numfor(Var, Init, Limit, Step, Sz, B, St0) ->
    NumFor = fun (St) -> numeric_for(Var, Init, Limit, Step, Sz, B, St) end,
    %% io:fwrite("dn: ~p\n", [{N,St0#luerl.locf}]),
    {_,St1} = loop_block(NumFor, St0),
    %% io:fwrite("dn->~p\n", [{N,St1#luerl.locf}]),
    St1.

numeric_for(Var, Init, Limit, Step, Sz, B, St0) ->
    {Es,St1} = explist([Init,Limit,Step], St0),
    case luerl_lib:tonumbers(Es) of
	[I,L,S|_] ->		%Ignore extra values
	    numfor_loop(Var, I, L, S, Sz, B, St1);
	nil ->
	    badarg_error(for, Es)
    end.

numfor_loop(V, I, L, S, Sz, B, St0)
  when S > 0, I =< L ; S =< 0, I >= L ->
    %% Create a local block for each iteration of the loop.
    Do = fun (S0) ->
		 %% Use local assign to put argument into environment.
		 S1 = set_var(V, I, S0),
		 {[],stats(B, S1)}
	 end,
    {_,St1} = with_block(Sz, Do, St0),
    numfor_loop(V, I+S, L, S, Sz, B, St1);
numfor_loop(_, _, _, _, _, _, St) -> {[],St}.	%We're done

%% do_genfor(Vars, Gens, Size, Block, State) -> State.

do_genfor(Vars, Gens, Sz, B, St0) ->
    GenFor = fun (St) -> generic_for(Vars, Gens, Sz, B, St) end,
    {_,St1} = loop_block(GenFor, St0),
    St1.

generic_for(Vars, Gens, Sz, B, St0) ->
    {Rets,St1} = explist(Gens, St0),
    case Rets of				%Export 3 values!
	[F] -> S = nil, Var = nil;
	[F,S] -> Var = nil;
	[F,S,Var|_] -> ok
    end,
    genfor_loop(Vars, F, S, Var, Sz, B, St1).

genfor_loop(Vars, F, S, Var, Sz, B, St0) ->
    {Vals,St1} = functioncall(F, [S,Var], St0),
    case is_true_value(Vals) of
	true ->	    				%We go on
	    %% Create a local block for each iteration of the loop.
	    Do = fun (S0) ->
			 %% Use local assign to put arguments into environment.
			 S1 = assign_local_loop(Vars, Vals, S0),
			 {[],stats(B, S1)}
		 end,
	    {_,St2} = with_block(Sz, Do, St1),
	    genfor_loop(Vars, F, S, first_value(Vals), Sz, B, St2);
	false -> {[],St1}			%Done
    end.

local({functiondef,L,Sz,V,Ps,B}, St0) ->
    %% Compiler has fixed name so recursive call finds right name
    {[F],St1} = exp({functiondef,L,Sz,Ps,B}, St0),
    set_var(V, F, St1);
local({assign,_,Vs,Es}, St0) ->
    {Vals,St1} = explist(Es, St0),
    assign_local_loop(Vs, Vals, St1).

assign_local_loop(Vs, Vals, #luerl{st=Fps,ft=Ft0}=St) ->
    Ft1 = assign_local_loop(Vs, Vals, Fps, Ft0),
    St#luerl{ft=Ft1}.

assign_local_loop([{local_var,_,_,I}|Vs], [Val|Vals], Fps, Ft0) ->
    Ft1 = set_local_var(I, Val, Fps, Ft0),
    assign_local_loop(Vs, Vals, Fps, Ft1);
assign_local_loop([{local_var,_,_,I}|Vs], [], Fps, Ft0) ->
    Ft1 = set_local_var(I, nil, Fps, Ft0),
    assign_local_loop(Vs, [], Fps, Ft1);
assign_local_loop([], _, _, Ft) -> Ft.

%% explist([Exp], State) -> {[Val],State}.
%% Evaluate a list of expressions returning a list of values. If the
%% last expression returns more than one value then these are appended
%% to the returned list.

explist([E], St) -> exp(E, St);			%Appended values to output
explist([E|Es], St0) ->
    %% io:format("el: ~p\n", [E]),
    {V,St1} = exp(E, St0),
    {Vs,St2} = explist(Es, St1),
    {[first_value(V)|Vs],St2};			%Only take the first value
explist([], St) -> {[],St}.

%% exp(Exp, State) -> {Vals,State}.
%% Function calls can affect the state. Return a list of values!

exp({nil,_}, St) -> {[nil],St};
exp({false,_}, St) -> {[false],St};
exp({true,_}, St) -> {[true],St};
exp({'NUMBER',_,N}, St) -> {[N],St};
exp({'STRING',_,S}, St) -> {[S],St};
exp({local_var,_,'...',_}=VarArg, St) ->	%Get '...', error if undefined
    %% This must be handled separately!
    case get_var(VarArg, St) of			%Only returns single value!
	nil -> illegal_val_error('...');
	Val -> {Val,St}				%Already a list
    end;
exp({functiondef,L,Sz,Ps,B}, St) ->
    {[{function,L,Sz,St#luerl.st,Ps,B}],St#luerl{locf=true}};
exp({table,_,Fs}, St0) ->
    {Ts,St1} = tableconstructor(Fs, St0),
    {T,St2} = alloc_table(Ts, St1),
    {[T],St2};
%% 'and' and 'or' short-circuit so need special handling.
exp({op,_,'and',L0,R0}, St0) ->
    {L1,St1} = exp(L0, St0),
    case is_true_value(L1) of
	true ->
	    {R1,St2} = exp(R0, St1),
	    {R1,St2};				%Do we need first value?
	false -> {L1,St1}
    end;
exp({op,_,'or',L0,R0}, St0) ->
    {L1,St1} = exp(L0, St0),
    case is_true_value(L1) of
	true -> {L1,St1};
	false ->
	    {R1,St2} = exp(R0, St1),
	    {R1,St2}				%Do we need first value?
    end;
%% All the other operators are strict.
exp({op,_,Op,L0,R0}, St0) ->
    {L1,St1} = exp(L0, St0),
    {R1,St2} = exp(R0, St1),
    op(Op, first_value(L1), first_value(R1), St2);
exp({op,_,Op,A0}, St0) ->
    {A1,St1} = exp(A0, St0),
    op(Op, first_value(A1), St1);
exp(E, St) ->
    prefixexp(E, St).

%% prefixexp(PrefixExp, State) -> {[Vals],State}.
%% Step down the prefixexp sequence evaluating as we go. We special
%% checking for functions/methods to give better errors, after an idea
%% by @slepher.

prefixexp({'.',_,{'NAME',_,N}=Exp,{functioncall,_,_}=Rest}, St0) ->
    {Next,St1} = prefixexp_first(Exp, St0),
    case first_value(Next) of
	nil -> lua_error({undef_function,N});
	Fval -> prefixexp_rest(Rest, Fval, St1)
    end;
prefixexp({'.',_,Exp,Rest}, St0) ->
    %%io:format("p: ~p\n", [{Exp,Rest}]),
    {Next,St1} = prefixexp_first(Exp, St0),
    %%io:format("p> ~p\n", [{Next}]),
    prefixexp_rest(Rest, first_value(Next), St1);
prefixexp(P, St) -> prefixexp_first(P, St).

prefixexp_first({single,_,E}, St0) ->		%Guaranteed only one value
    {R,St1} = exp(E, St0),
    {[first_value(R)],St1};			%Only one value!
prefixexp_first(Var, St) ->
    {[get_var(Var, St)],St}.

prefixexp_rest({'.',_,{'NAME',_,N}=Exp,{functioncall,_,_}=Rest},
	       SoFar, St0) ->
    {Next,St1} = prefixexp_element(Exp, SoFar, St0),
    case first_value(Next) of
	nil -> lua_error({undef_function,N});
	Fval -> prefixexp_rest(Rest, Fval, St1)
    end;
prefixexp_rest({'.',_,Exp,Rest}, SoFar, St0) ->
    {Next,St1} = prefixexp_element(Exp, SoFar, St0),
    prefixexp_rest(Rest, first_value(Next), St1);
prefixexp_rest(Exp, SoFar, St) ->
    prefixexp_element(Exp, SoFar, St).

prefixexp_element({functioncall,_,Args0}, SoFar, St0) ->
    {Args1,St1} = explist(Args0, St0),
    %%io:fwrite("pe1: ~p\n", [{SoFar,Args1}]),
    functioncall(SoFar, Args1, St1);
prefixexp_element({'NAME',_,N}, SoFar, St0) ->
    {V,St1} = get_table_name(SoFar, N, St0),
    {V,St1};
prefixexp_element({key_field,_,Exp}, SoFar, St0) ->
    {Key,St1} = exp(Exp, St0),
    {V,St2} = get_table_key(SoFar, first_value(Key), St1),
    {V,St2};
prefixexp_element({method,_,{'NAME',_,N},Args0}, SoFar, St0) ->
    {Func,St1} = get_table_name(SoFar, N, St0),
    case first_value(Func) of
	nil -> lua_error({undef_function,N});
	Fval ->
	    {Args1,St2} = explist(Args0, St1),
	    %%io:fwrite("pe2: ~p\n", [{Func,[SoFar|Args1]}]),
	    functioncall(Fval, [SoFar|Args1], St2)
    end.

functioncall({function,_,Sz,Stk,Ps,B}, Args, St0) ->
    Stk0 = St0#luerl.st,			%Caller's stack
    St1 = St0#luerl{st=Stk},			%Set function's stack
    Do = fun (S0) ->
		 %% Use local assign to put argument into environment.
		 S1 = assign_par_loop(Ps, Args, S0),
		 {[],stats(B, S1)}
	 end,
    {Ret,St2} = function_block(Sz, Do, St1),
    St3 = St2#luerl{st=Stk0},			%Restore caller's stack
    {Ret,St3};
functioncall({function,Fun}, Args, St) when is_function(Fun) ->
    Fun(Args, St);
functioncall({userdata,Fun}, Args, St) when is_function(Fun) ->
    Fun(Args, St);
functioncall(Func, As, St) ->
    %% io:format("fc: ~p\n", [{Func,As}]),
    case getmetamethod(Func, <<"__call">>, St) of
	nil -> badarg_error(Func, As);
	Meta -> functioncall(Meta, As, St)
    end.

%% assign_par_loop(Names, Vals, State) -> State.
%% Could probably merge this and assign_local_loop.

assign_par_loop(Vs, Vals, #luerl{st=Fps,ft=Ft0}=St) ->
    Ft1 = assign_par_loop_1(Vs, Vals, Fps, Ft0),
    St#luerl{ft=Ft1}.

assign_par_loop_1([{local_var,_,'...',I}], Vals, Fps, Ft) ->
    set_local_var(I, Vals, Fps, Ft);
assign_par_loop_1([{local_var,_,_,I}|Vs], [Val|Vals], Fps, Ft0) ->
    Ft1 = set_local_var(I, Val, Fps, Ft0),
    assign_par_loop_1(Vs, Vals, Fps, Ft1);
assign_par_loop_1([{local_var,_,_,I}|Vs], [], Fps, Ft0) ->
    Ft1 = set_local_var(I, nil, Fps, Ft0),
    assign_par_loop_1(Vs, [], Fps, Ft1);
assign_par_loop_1([], _, _, Ft) -> Ft.

%% function_block(Size, Do, State) -> {Return,State}.
%%  The top level block in which to evaluate functions run loops
%%  in. Catch returns and breaks here; breaks are errors as they
%%  should have been caught already. Stack needs to be reset/unwound
%%  when we catch a break.

function_block(Sz, Do, St) ->
    Block = fun (St0) ->
		    Tag = St0#luerl.tag,
		    try Do(St0)
		    catch
			throw:{return,_,Tag,Ret,St1} ->
			    %% Unwind the stack and freeing tables.
			    Old = St0#luerl.st,
			    St2 = unwind_stack(St1#luerl.st, Old, St1),
			    {Ret,St2};
			throw:{break,_,Tag,_} ->
			    lua_error({illegal_op,break})
		    end
	    end,
    with_block(Sz, Block, St).

%% unwind_stack(From, To, State) -> State.
%%  If locf is false then we can unwind env stack freeing tables as we
%%  go, otherwise if locf is true we can not do this.

%% unwind_stack(_, To, St) -> St#luerl{env=To};	%For testing
unwind_stack(_, _, #luerl{locf=true}=St) -> St;
unwind_stack(From, [Top|_]=To, #luerl{ft=Ft0,ff=Ns0}=St) ->
    {Ft1,Ns1} = unwind_stack(From, Top, Ft0, Ns0),
    St#luerl{ft=Ft1,ff=Ns1,st=To}.

unwind_stack([Top|_], Top, Ft, Ns) -> {Ft,Ns};	%Done!
unwind_stack([#fref{i=N}|From], Top, Ft0, Ns) ->
    Ft1 = array:reset(N, Ft0),
    %% io:format("us: ~p\n", [N]),
    unwind_stack(From, Top, Ft1, [N|Ns]).

%% tableconstructor(Fields, State) -> {TableData,State}.
%%  We have to be a bit cunning here, the fields may end in a '...' in
%%  which case we have to "append" it elements similar to exp_fields
%%  but they have already been evaluated.

tableconstructor(Fs, St0) ->
    %% io:fwrite("tc: ~p\n", [{Fs,St0#luerl.env}]),
    %% io:fwrite("tc: ~p\n", [{Fs,St0#luerl.locf}]),
    {Tes,St1} = tc_fields(Fs, 1.0, [], St0),
    %% io:fwrite("tc->~p\n", [{St1#luerl.locf}]),
    %% io:fwrite("tc->~p\n", [{Tes}]),
    {Tes,St1}.

tc_fields([{exp_field,_,Ve}], I, Tes, St0) ->
    {Fs,St1} = exp(Ve, St0),			%Get the last field!
    tc_tail(Fs, I, Tes, St1); 
tc_fields([{exp_field,_,Ve}|Fs], I, Tes, St0) ->
    {V,St1} = exp(Ve, St0),
    tc_fields(Fs, I+1, [{I,first_value(V)}|Tes], St1);
tc_fields([{name_field,_,{'NAME',_,N},Ve}|Fs], I, Tes, St0) ->
    {V,St1} = exp(Ve, St0),
    K = atom_to_binary(N, latin1),
    tc_fields(Fs, I, [{K,first_value(V)}|Tes], St1);
tc_fields([{key_field,_,Ke,Ve}|Fs], I, Tes, St0) ->
    {K,St1} = exp(Ke, St0),
    {V,St2} = exp(Ve, St1),
    tc_fields(Fs, I, [{first_value(K),first_value(V)}|Tes], St2);
tc_fields([], _, Tes, St) -> {lists:reverse(Tes),St}.

tc_tail(Fs, I0, Tes, St) ->
    Fun = fun (Ve, I) -> {{I,Ve},I+1} end,
    {Tail,_} = lists:mapfoldl(Fun, I0, Fs),
    {lists:reverse(Tes, Tail),St}.

%% op(Op, Arg, State) -> {[Ret],State}.
%% op(Op, Arg1, Arg2, State) -> {[Ret],State}.
%% The built-in operators.

op('-', A, St) ->
    numeric_op('-', A, <<"__unm">>, fun (N) -> -N end, St);
op('not', A, St) -> {[not ?IS_TRUE(A)],St};
%% op('not', false, St) -> {[true],St};
%% op('not', nil, St) -> {[true],St};
%% op('not', _, St) -> {[false],St};		%Everything else is false
op('#', B, St) when is_binary(B) -> {[float(byte_size(B))],St};
op('#', #tref{}=T, St) ->
    luerl_table:length(T, St);
op(Op, A, _) -> badarg_error(Op, [A]).

%% Numeric operators.

op('+', A1, A2, St) ->
    numeric_op('+', A1, A2, <<"__add">>, fun (N1,N2) -> N1+N2 end, St);
op('-', A1, A2, St) ->
    numeric_op('-', A1, A2, <<"__sub">>, fun (N1,N2) -> N1-N2 end, St);
op('*', A1, A2, St) ->
    numeric_op('*', A1, A2, <<"__mul">>, fun (N1,N2) -> N1*N2 end, St);
op('/', A1, A2, St) ->
    numeric_op('/', A1, A2, <<"__div">>, fun (N1,N2) -> N1/N2 end, St);
op('%', A1, A2, St) ->
    numeric_op('%', A1, A2, <<"__mod">>,
	       fun (N1,N2) -> N1 - round(N1/N2 - 0.5)*N2 end, St);
op('^', A1, A2, St) ->
    numeric_op('^', A1, A2, <<"__pow">>,
	       fun (N1,N2) -> math:pow(N1, N2) end, St);
%% Relational operators, getting close.
op('==', A1, A2, St) -> eq_op('==', A1, A2, St);
op('~=', A1, A2, St) -> neq_op('~=', A1, A2, St);
op('<=', A1, A2, St) -> le_op('<=', A1, A2, St);
op('>=', A1, A2, St) -> le_op('>=', A2, A1, St);
op('<', A1, A2, St) -> lt_op('<', A1, A2, St);
op('>', A1, A2, St) -> lt_op('>', A2, A1, St);
%% String operator.
op('..', A1, A2, St) ->
    B1 = luerl_lib:tostring(A1),
    B2 = luerl_lib:tostring(A2),
    if B1 =/= nil, B2 =/= nil -> {[<< B1/binary,B2/binary >>],St};
       true ->
	    Meta = getmetamethod(A1, A2, <<"__concat">>, St),
	    functioncall(Meta, [A1,A2], St)
    end;
%% Bad args here.
op(Op, A1, A2, _) -> badarg_error(Op, [A1,A2]).

%% numeric_op(Op, Arg, Event, Raw, State) -> {[Ret],State}.
%% numeric_op(Op, Arg, Arg, Event, Raw, State) -> {[Ret],State}.
%% eq_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% neq_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% lt_op(Op, Arg, Arg, State) -> {[Ret],State}.
%% le_op(Op, Arg, Arg, State) -> {[Ret],State}.
%%  Straigt out of the reference manual.

numeric_op(_Op, O, E, Raw, St0) ->
    N = luerl_lib:tonumber(O),
    if is_number(N) -> {[Raw(N)],St0};
       true ->
	    Meta = getmetamethod(O, E, St0),
	    {Ret,St1} = functioncall(Meta, [O], St0),
	    {[is_true_value(Ret)],St1}
    end.

numeric_op(_Op, O1, O2, E, Raw, St0) ->
    N1 = luerl_lib:tonumber(O1),
    N2 = luerl_lib:tonumber(O2),
    if is_number(N1), is_number(N2) -> {[Raw(N1, N2)],St0};
       true ->
	    Meta = getmetamethod(O1, O2, E, St0),
	    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
	    {[is_true_value(Ret)],St1}
    end.

eq_op(_Op, O1, O2, St) when O1 =:= O2 -> {[true],St};
eq_op(_Op, O1, O2, St0) ->
    {Ret,St1} = eq_meta(O1, O2, St0),
    {[is_true_value(Ret)],St1}.

neq_op(_Op, O1, O2, St) when O1 =:= O2 -> {[false],St};
neq_op(_Op, O1, O2, St0) ->
    {Ret,St1} = eq_meta(O1, O2, St0),
    {[not is_true_value(Ret)],St1}.

eq_meta(O1, O2, St0) ->
    case getmetamethod(O1, <<"__eq">>, St0) of
	nil -> {[false],St0};			%Tweren't no method
	Meta ->
	    case getmetamethod(O2, <<"__eq">>, St0) of
		Meta ->				%Must be the same method
		    functioncall(Meta, [O1,O2], St0);
		_ -> {[false],St0}
	    end
    end.

lt_op(_Op, O1, O2, St) when is_number(O1), is_number(O2) -> {[O1 < O2],St};
lt_op(_Op, O1, O2, St) when is_binary(O1), is_binary(O2) -> {[O1 < O2],St};
lt_op(_Op, O1, O2, St0) ->
    Meta = getmetamethod(O1, O2, <<"__lt">>, St0),
    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
    {[is_true_value(Ret)],St1}.

le_op(_Op, O1, O2, St) when is_number(O1), is_number(O2) -> {[O1 =< O2],St};
le_op(_Op, O1, O2, St) when is_binary(O1), is_binary(O2) -> {[O1 =< O2],St};
le_op(_Op, O1, O2, St0) ->
    case getmetamethod(O1, O2, <<"__le">>, St0) of
	Meta when Meta =/= nil ->
	    {Ret,St1} = functioncall(Meta, [O1,O2], St0),
	    {[is_true_value(Ret)],St1};
	nil ->
	    %% Try for not (Op2 < Op1) instead.
	    Meta = getmetamethod(O1, O2, <<"__lt">>, St0),
	    {Ret,St1} = functioncall(Meta, [O2,O1], St0),
	    {[not is_true_value(Ret)],St1}
    end.

%% getmetamethod(Object1, Object2, Event, State) -> Metod | nil.
%% getmetamethod(Object, Event, State) -> Method | nil.
%% Get the metamethod for object(s).

getmetamethod(O1, O2, E, St) ->
    case getmetamethod(O1, E, St) of
	nil -> getmetamethod(O2, E, St);
	M -> M
    end.

getmetamethod(#tref{i=N}, E, #luerl{tabs=Ts}) ->
    #table{m=Meta} = ?GET_TABLE(N, Ts),
    getmetamethod_tab(Meta, E, Ts);
getmetamethod({userdata,_}, E, #luerl{tabs=Ts,meta=Meta}) ->
    getmetamethod_tab(Meta#meta.userdata, E, Ts);
getmetamethod(S, E, #luerl{tabs=Ts,meta=Meta}) when is_binary(S) ->
    getmetamethod_tab(Meta#meta.string, E, Ts);
getmetamethod(N, E, #luerl{tabs=Ts,meta=Meta}) when is_number(N) ->
    getmetamethod_tab(Meta#meta.number, E, Ts);
getmetamethod(_, _, _) -> nil.			%Other types have no metatables

getmetamethod_tab(#tref{i=M}, E, Ts) ->
    #table{t=Mtab} = ?GET_TABLE(M, Ts),
    case orddict:find(E, Mtab) of
	{ok,Mm} -> Mm;
	error -> nil
    end;
getmetamethod_tab(_, _, _) -> nil.		%Other types have no metatables

%% is_true_value(Rets) -> boolean().

is_true_value([nil|_]) -> false;
is_true_value([false|_]) -> false;
is_true_value([_|_]) -> true;
is_true_value([]) -> false.

%% first_value(Rets) -> Value.

first_value([V|_]) -> V;
first_value([]) -> nil.

illegal_val_error(Val) ->
    lua_error({illegal_val,Val}).

%% gc(State) -> State.
%% The garbage collector. Its main job is to reclaim unused tables. It
%% is a mark/sweep collector which passes over all objects and marks
%% tables which it has seen. All unseen tables are then freed and
%% their index added to the free list.

gc(#luerl{tabs=Ts0,meta=Meta,free=Free0,env=Env}=St) ->
    Root = [Meta#meta.number,Meta#meta.string,Meta#meta.userdata|Env],
    Seen = mark(Root, [], [], Ts0),
    %% io:format("gc: ~p\n", [Seen]),
    %% Free unseen tables and add freed to free list.
    Ts1 = ?FILTER_TABLES(fun (K, _) -> ordsets:is_element(K, Seen) end, Ts0),
    Free1 = ?FOLD_TABLES(fun (K, _, F) ->
				 case ordsets:is_element(K, Seen) of
				     true -> F;
				     false -> [K|F]
				 end
			 end, Free0, Ts0),
    St#luerl{tabs=Ts1,free=Free1}.

%% mark(ToDo, MoreTodo, Seen, Tabs) -> Seen.
%% Scan over all live objects and mark seen tables by adding them to
%% the seen list.

mark([{in_table,_}=T|Todo], More, Seen, Ts) ->
    %%io:format("gc: ~p\n", [T]),
    mark(Todo, More, Seen, Ts);
mark([#tref{i=T}|Todo], More, Seen0, Ts) ->
    case ordsets:is_element(T, Seen0) of
	true ->					%Already done
	    mark(Todo, More, Seen0, Ts);
	false ->				%Must do it
	    Seen1 = ordsets:add_element(T, Seen0),
	    #table{a=Arr,t=Tab,m=Meta} = ?GET_TABLE(T, Ts),
	    %% Have to be careful where add Tab and Meta as Tab is a
	    %% [{Key,Val}] and Meta is a nil|#tref{i=M}. We want lists.
	    mark([Meta|Todo], [[{in_table,T}],Tab,Arr,[{in_table,-T}]|More],
		 Seen1, Ts)
    end;
mark([{function,_,Env,_,_}|Todo], More, Seen, Ts) ->
    mark(Todo, [Env|More], Seen, Ts);
%% Catch these as they would match table key-value pair.
mark([{function,_}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([#thread{}|Todo], More, Seen, Ts) ->
    mark(Todo, More, Seen, Ts);
mark([#userdata{m=Meta}|Todo], More, Seen, Ts) ->
    mark([Meta|Todo], More, Seen, Ts);
mark([{K,V}|Todo], More, Seen, Ts) ->		%Table key-value pair
    %%io:format("mt: ~p\n", [{K,V}]),
    mark([K,V|Todo], More, Seen, Ts);
mark([_|Todo], More, Seen, Ts) ->		%Can ignore everything else
    mark(Todo, More, Seen, Ts);
mark([], [M|More], Seen, Ts) ->
    mark(M, More, Seen, Ts);
mark([], [], Seen, _) -> Seen.