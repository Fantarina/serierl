%%%-------------------------------------------------------------------
%% @doc serierl public API
%% @end
%%%-------------------------------------------------------------------

-module(serierl_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    serierl_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
