%% @doc serierl top-level supervisor
%% License: Apache 2.0
-module(serierl_sup).
-behaviour(supervisor).

-export([start_link/0, start_port/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

%% --- API ---

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Dynamically spawns a new supervised serierl process.
start_port() ->
    supervisor:start_child(?SERVER, []).

%% --- Callbacks ---

init([]) ->
    %% simple_one_for_one means the supervisor starts empty.
    %% When we call start_child/2, it uses this template to spawn a process.
    %% transient means it will only be restarted if it crashes abnormally.
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 5,    %% Max 5 crashes...
        period => 10       %% ...in 10 seconds before giving up
    },
    
    ChildSpec = #{
        id => serierl_worker,
        start => {serierl, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [serierl]
    },
    
    {ok, {SupFlags, [ChildSpec]}}.