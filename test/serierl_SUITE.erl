%% @doc EUnit test suite for serierl focusing strictly on core read/write capabilities.
-module(serierl_SUITE).
-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% Test generator
%% ---------------------------------------------------------------------------

serierl_test_() ->
    {setup,
        fun setup_all/0,
        fun teardown_all/1,
        {foreach,
            fun setup/0,
            fun teardown/1,
            [
                fun open_and_close/1,
                fun write_reaches_device/1,
                fun device_data_read_all/1,
                fun device_data_read_n_bytes/1,
                fun device_data_readline/1,
                fun device_data_read_until/1,
                fun read_timeout_returns_partial/1,
                fun write_error_on_closed_port/1,
                fun double_open_replaces_port/1,
                fun drop_reads_discards_data/1,
                fun reset_input_buffer_clears/1
            ]
        }
    }.

%% ---------------------------------------------------------------------------
%% Setup / Teardown
%% ---------------------------------------------------------------------------

setup_all() ->
    application:ensure_all_started(serierl).

teardown_all(_) ->
    application:stop(serierl).

setup() ->
    {AppPath, DevicePath} = open_socat(),
    
    {ok, AppPid} = serierl:start_link(),
    {ok, DevicePid} = serierl:start_link(),
    
    {AppPid, DevicePid, AppPath, DevicePath}.

teardown({AppPid, DevicePid, _AppPath, _DevicePath}) ->
    catch serierl:close(AppPid),
    catch serierl:close(DevicePid),
    catch gen_server:stop(AppPid),
    catch gen_server:stop(DevicePid),
    close_socat().

%% ---------------------------------------------------------------------------
%% Individual test functions
%% ---------------------------------------------------------------------------

open_and_close({AppPid, _DevicePid, AppPath, _DevicePath}) ->
    ?_test(begin
        ?assertEqual(ok, serierl:open(AppPid, AppPath)),
        ?assertEqual(ok, serierl:close(AppPid))
    end).

write_reaches_device({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath),
        ok = serierl:open(DevicePid, DevicePath),
        
        ok = serierl:write(AppPid, <<"ping">>),
        
        {ok, Received} = serierl:read(DevicePid, 4),
        ?assertEqual(<<"ping">>, Received)
    end).

device_data_read_all({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath),
        ok = serierl:open(DevicePid, DevicePath),
        
        ok = serierl:write(DevicePid, <<"hello">>),
        timer:sleep(100),
        
        {ok, Data} = serierl:read(AppPid),
        ?assertEqual(<<"hello">>, Data)
    end).

device_data_read_n_bytes({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath, [{timeout, 2.0}]),
        ok = serierl:open(DevicePid, DevicePath),
        
        spawn(fun() ->
            timer:sleep(50),
            serierl:write(DevicePid, <<"12345">>),
            timer:sleep(50),
            serierl:write(DevicePid, <<"67890">>)
        end),
        
        {ok, Data} = serierl:read(AppPid, 10),
        ?assertEqual(<<"1234567890">>, Data)
    end).

device_data_readline({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath, [{timeout, 2.0}]),
        ok = serierl:open(DevicePid, DevicePath),
        
        spawn(fun() ->
            timer:sleep(50),
            serierl:write(DevicePid, <<"OK\r\n">>)
        end),
        
        {ok, Line} = serierl:readline(AppPid),
        ?assertEqual(<<"OK\r\n">>, Line)
    end).

device_data_read_until({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath, [{timeout, 2.0}]),
        ok = serierl:open(DevicePid, DevicePath),
        
        spawn(fun() ->
            timer:sleep(50),
            serierl:write(DevicePid, <<"DATA:42:END">>)
        end),
        
        {ok, Chunk} = serierl:read_until(AppPid, <<"END">>),
        ?assertEqual(<<"DATA:42:END">>, Chunk)
    end).

read_timeout_returns_partial({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath, [{timeout, 0.1}]),
        ok = serierl:open(DevicePid, DevicePath),
        
        ok = serierl:write(DevicePid, <<"partial">>),
        
        {ok, Data} = serierl:read(AppPid, 9999),
        ?assertEqual(<<"partial">>, Data)
    end).

write_error_on_closed_port({AppPid, _DevicePid, AppPath, _DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath),
        ok = serierl:close(AppPid),
        
        Result = serierl:write(AppPid, <<"data">>),
        ?assertMatch({error, _}, Result)
    end).

double_open_replaces_port({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath),
        ok = serierl:open(DevicePid, DevicePath),
        
        ok = serierl:open(AppPid, AppPath),
        ok = serierl:write(AppPid, <<"x">>),
        
        {ok, Data} = serierl:read(DevicePid, 1),
        ?assertEqual(<<"x">>, Data)
    end).

drop_reads_discards_data({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath, [{drop_reads, true}]),
        ok = serierl:open(DevicePid, DevicePath),
        
        ok = serierl:write(DevicePid, <<"ignored">>),
        timer:sleep(150),
        
        {ok, Buf} = serierl:read(AppPid),
        ?assertEqual(<<>>, Buf)
    end).

reset_input_buffer_clears({AppPid, DevicePid, AppPath, DevicePath}) ->
    ?_test(begin
        ok = serierl:open(AppPid, AppPath),
        ok = serierl:open(DevicePid, DevicePath),
        
        ok = serierl:write(DevicePid, <<"noise">>),
        timer:sleep(100),
        
        ok = serierl:reset_input_buffer(AppPid),
        {ok, Buf} = serierl:read(AppPid),
        ?assertEqual(<<>>, Buf)
    end).

%% ---------------------------------------------------------------------------
%% Socat PTS helpers
%% ---------------------------------------------------------------------------

open_socat() ->
    Port = open_port({spawn, "socat -d -d pty,raw,echo=0 pty,raw,echo=0"}, 
                     [stderr_to_stdout, {line, 256}]),
    
    Path1 = wait_for_pty(Port),
    Path2 = wait_for_pty(Port),
    
    put(socat_port, Port),
    {Path1, Path2}.

wait_for_pty(Port) ->
    receive
        {Port, {data, {_, Line}}} ->
            case string:find(Line, "PTY is ") of
                nomatch -> wait_for_pty(Port);
                Match -> 
                    "PTY is " ++ Path = Match,
                    Path
            end
    after 3000 ->
        error(socat_timeout)
    end.

close_socat() ->
    case get(socat_port) of
        undefined -> ok;
        Port ->
            port_close(Port),
            erase(socat_port)
    end.