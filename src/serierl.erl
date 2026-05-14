%% @doc Erlang idiomatic serial port with PySerial-like buffering, reading, and hardware control.
%% License: Apache 2.0
-module(serierl).
-behaviour(gen_server).

%% API
-export([start_link/0, open/2, open/3, write/2, close/1]).
-export([read/1, read/2, readline/1, read_until/2]).
-export([set_rts/2, set_dtr/2, get_signals/1]).
-export([reset_input_buffer/1, reset_output_buffer/1, flush/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    port,
    opts = #{},
    drop_reads = false :: boolean(),
    buffer = <<>> :: binary(),
    pending_read = undefined  %% {From, TimerRef, ReadCriteria}
}).

%% --- API ---

start_link() -> gen_server:start_link(?MODULE, [], []).

open(Pid, PortName) -> open(Pid, PortName, []).

open(Pid, PortName, Opts) ->
    %% Defaults: 5.0 seconds for timeouts (No default infinity)
    Defaults = #{
        baudrate => 9600, bytesize => 8, parity => none, stopbits => 1,
        xonxoff => false, rtscts => false, dsrdtr => false, exclusive => false,
        drop_reads => false, timeout => 5.0, write_timeout => 5.0
    },
    MergedOpts = maps:merge(Defaults, maps:from_list(Opts)),
    gen_server:call(Pid, {open, PortName, MergedOpts}, infinity).

write(Pid, Data) ->
    %% Fetch the exact write_timeout to override Erlang's 5s default
    TimeoutMs = gen_server:call(Pid, get_write_timeout),
    %% This natively crashes the caller if the timeout is reached
    gen_server:call(Pid, {write, iolist_to_binary(Data)}, TimeoutMs).

read(Pid) ->
    gen_server:call(Pid, read_all).

read(Pid, N) when is_integer(N), N > 0 ->
    gen_server:call(Pid, {read_size, N}, infinity).

readline(Pid) ->
    read_until(Pid, <<"\n">>).

read_until(Pid, Expected) when is_binary(Expected) ->
    gen_server:call(Pid, {read_until, Expected}, infinity).

set_rts(Pid, Value) when is_boolean(Value) ->
    IntVal = if Value -> 1; true -> 0 end,
    gen_server:call(Pid, {modem_set, 0, IntVal}).

set_dtr(Pid, Value) when is_boolean(Value) ->
    IntVal = if Value -> 1; true -> 0 end,
    gen_server:call(Pid, {modem_set, 1, IntVal}).

get_signals(Pid) ->
    gen_server:call(Pid, get_signals).

reset_input_buffer(Pid) ->
    gen_server:call(Pid, {buffer_op, 1}).

reset_output_buffer(Pid) ->
    gen_server:call(Pid, {buffer_op, 2}).

flush(Pid) ->
    gen_server:call(Pid, {buffer_op, 4}, infinity).

close(Pid) ->
    gen_server:call(Pid, close).

%% --- Callbacks ---

init([]) ->
    ExtPrg = filename:join(code:priv_dir(serierl), "serierl_port"),
    Port = open_port({spawn, ExtPrg}, [{packet, 2}, binary, exit_status]),
    {ok, #state{port = Port}}.

handle_call({open, PortName, Opts}, _From, State) ->
    PortBin = if is_list(PortName) -> list_to_binary(PortName); true -> PortName end,
    
    Baudrate = maps:get(baudrate, Opts),
    ByteSize = maps:get(bytesize, Opts),
    ParityInt = case maps:get(parity, Opts) of none->0; odd->1; even->2; mark->3; space->4 end,
    StopBitsInt = case maps:get(stopbits, Opts) of 1->1; 1.5->3; 2->2 end,
    XonXoff = case maps:get(xonxoff, Opts) of true -> 1; false -> 0 end,
    RtsCts  = case maps:get(rtscts, Opts) of true -> 1; false -> 0 end,
    DsrDtr  = case maps:get(dsrdtr, Opts) of true -> 1; false -> 0 end,
    FlowMask = (XonXoff bsl 0) bor (RtsCts bsl 1) bor (DsrDtr bsl 2),
    ExclusiveInt = case maps:get(exclusive, Opts) of true -> 1; false -> 0 end,
    DropReads = maps:get(drop_reads, Opts),

    Payload = <<1:8, Baudrate:32/big-unsigned-integer, ByteSize:8, ParityInt:8, 
                StopBitsInt:8, FlowMask:8, ExclusiveInt:8, PortBin/binary, 0:8>>,
                
    port_command(State#state.port, Payload),
    
    case wait_for_ack(State#state.port) of
        ok -> {reply, ok, State#state{opts = Opts, drop_reads = DropReads, buffer = <<>>}};
        Error -> {reply, Error, State}
    end;

handle_call(get_write_timeout, _From, State) ->
    {reply, to_ms(maps:get(write_timeout, State#state.opts)), State};

handle_call({write, Data}, _From, State) ->
    port_command(State#state.port, <<2:8, Data/binary>>),
    {reply, ok, State};

handle_call({modem_set, Pin, Val}, _From, State) ->
    port_command(State#state.port, <<4:8, Pin:8, Val:8>>),
    {reply, wait_for_ack(State#state.port), State};

handle_call({buffer_op, Action}, _From, State) ->
    port_command(State#state.port, <<5:8, Action:8>>),
    Result = wait_for_ack(State#state.port),
    NewState = if Action =:= 1 orelse Action =:= 3 -> State#state{buffer = <<>>}; true -> State end,
    {reply, Result, NewState};

handle_call(get_signals, _From, State) ->
    port_command(State#state.port, <<6:8>>),
    receive
        {Port, {data, <<0:8, Mask:8>>}} when Port =:= State#state.port ->
            Map = #{
                cts => (Mask band (1 bsl 0)) > 0,
                dsr => (Mask band (1 bsl 1)) > 0,
                ri  => (Mask band (1 bsl 2)) > 0,
                cd  => (Mask band (1 bsl 3)) > 0
            },
            {reply, {ok, Map}, State};
        {Port, {data, <<1:8, Err/binary>>}} when Port =:= State#state.port ->
            {reply, {error, binary_to_list(Err)}, State}
    after 5000 ->
        {reply, {error, timeout}, State}
    end;

handle_call(read_all, _From, State) ->
    {reply, {ok, State#state.buffer}, State#state{buffer = <<>>}};

handle_call({read_size, N}, From, State = #state{opts = Opts}) ->
    TimeoutMs = to_ms(maps:get(timeout, Opts)),
    TimerRef = case TimeoutMs of
        infinity -> make_ref();
        _ -> erlang:send_after(TimeoutMs, self(), {read_timeout, From})
    end,
    NewState = State#state{pending_read = {From, TimerRef, {size, N}}},
    {noreply, process_pending_read(NewState)};

handle_call({read_until, Expected}, From, State = #state{opts = Opts}) ->
    TimeoutMs = to_ms(maps:get(timeout, Opts)),
    TimerRef = case TimeoutMs of
        infinity -> make_ref();
        _ -> erlang:send_after(TimeoutMs, self(), {read_timeout, From})
    end,
    NewState = State#state{pending_read = {From, TimerRef, {until, Expected}}},
    {noreply, process_pending_read(NewState)};

handle_call(close, _From, State) ->
    port_command(State#state.port, <<3:8>>),
    if State#state.pending_read =/= undefined ->
        {WaitingFrom, TimerRef, _} = State#state.pending_read,
        erlang:cancel_timer(TimerRef),
        gen_server:reply(WaitingFrom, {error, closed});
    true -> ok end,
    {reply, ok, State#state{buffer = <<>>, pending_read = undefined}}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({read_timeout, From}, State = #state{pending_read = {From, _Ref, _Criteria}}) ->
    %% Timeout hit: Return the partial buffer exactly like PySerial
    PartialData = State#state.buffer,
    gen_server:reply(From, {ok, PartialData}),
    {noreply, State#state{buffer = <<>>, pending_read = undefined}};

handle_info({read_timeout, _StaleFrom}, State) ->
    %% Ignore stale timeouts if data arrived right at the deadline
    {noreply, State};

handle_info({Port, {data, <<2:8, Incoming/binary>>}}, #state{port = Port} = State) ->
    if State#state.drop_reads ->
        {noreply, State};
    true ->
        NewBuf = <<(State#state.buffer)/binary, Incoming/binary>>,
        NewState = process_pending_read(State#state{buffer = NewBuf}),
        {noreply, NewState}
    end;

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    {stop, {port_crashed, Status}, State};

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    case State#state.port of
        undefined -> ok;
        Port -> port_close(Port)
    end.

%% --- Internal ---

wait_for_ack(Port) ->
    receive
        {Port, {data, <<0:8>>}} -> ok;
        {Port, {data, <<1:8, Err/binary>>}} -> {error, binary_to_list(Err)}
    after 5000 -> {error, timeout}
    end.

%% Converts seconds to milliseconds, allows 'none' to mean infinity
to_ms(none) -> infinity;
to_ms(infinity) -> infinity;
to_ms(Seconds) when is_float(Seconds) -> trunc(Seconds * 1000);
to_ms(Seconds) when is_integer(Seconds) -> Seconds * 1000.

process_pending_read(State = #state{pending_read = undefined}) ->
    State;
process_pending_read(State = #state{pending_read = {From, TimerRef, {until, Expected}}, buffer = Buf}) ->
    case binary:match(Buf, Expected) of
        {Pos, Len} ->
            erlang:cancel_timer(TimerRef),
            SplitAt = Pos + Len,
            <<ReturnChunk:SplitAt/binary, RestBuf/binary>> = Buf,
            gen_server:reply(From, {ok, ReturnChunk}),
            State#state{buffer = RestBuf, pending_read = undefined};
        nomatch -> State
    end;
process_pending_read(State = #state{pending_read = {From, TimerRef, {size, N}}, buffer = Buf}) ->
    if byte_size(Buf) >= N ->
        erlang:cancel_timer(TimerRef),
        <<ReturnChunk:N/binary, RestBuf/binary>> = Buf,
        gen_server:reply(From, {ok, ReturnChunk}),
        State#state{buffer = RestBuf, pending_read = undefined};
    true -> State
    end.