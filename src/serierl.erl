%% @doc An Erlang application to communicate with a serial device.
%% License: Apache 2.0
-module(serierl).
-behaviour(gen_server).

%% API
-export([
    start_link/0,
    open/2, open/3,
    write/2,
    read/1, read/2, readline/1, read_until/2,
    set_rts/2, set_dtr/2, get_signals/1,
    reset_input_buffer/1, reset_output_buffer/1, flush/1,
    close/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% --- Types ---

-type parity() :: none | odd | even | mark | space.
-type stopbits() :: 1 | 2.
-type bytesize() :: 5 | 6 | 7 | 8.

-type serial_option() ::
    {baudrate, pos_integer()} |
    {bytesize, bytesize()} |
    {parity, parity()} |
    {stopbits, stopbits()} |
    {xonxoff, boolean()} |
    {rtscts, boolean()} |
    {dsrdtr, boolean()} |
    {exclusive, boolean()} |
    {drop_reads, boolean()} |
    {timeout, float() | infinity} |
    {write_timeout, float() | infinity}.

-type serial_options() :: [serial_option()].

-type signal_map() :: #{
    cts => boolean(),
    dsr => boolean(),
    ri  => boolean(),
    cd  => boolean()
}.

%% pending_ack tracks a caller waiting for a simple ok/error acknowledgement
%% from the C port (open, modem_set, buffer_op, get_signals, write).
-type pending_ack() ::
    {From :: gen_server:from(), TimerRef :: reference(), AckType :: atom()}
    | undefined.

-record(state, {
    port         :: port() | undefined,
    opts         = #{} :: map(),
    is_open      = false :: boolean(),
    drop_reads   = false :: boolean(),
    buffer       = <<>> :: binary(),
    pending_read = undefined :: {gen_server:from(), reference(), tuple()} | undefined,
    pending_ack  = undefined :: pending_ack()
}).

%% Internal message tags for ack timeouts
-define(ACK_TIMEOUT_MS, 5000).

%% --- API ---

%% @doc Starts the serial port manager process.
%%
%% Spawns the serierl gen_server and immediately launches the isolated OS-level
%% C binary (serierl_port). At this stage, no physical hardware port is opened.
%%
%% Returns {ok, Pid} on success.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% @doc Opens a connection to a serial port using default 9600 8N1 settings.
%%
%% Equivalent to calling open(Pid, PortName, []).
-spec open(pid(), string() | binary()) -> ok | {error, term()}.
open(Pid, PortName) ->
    open(Pid, PortName, []).

%% @doc Opens a connection to a serial port with specific hardware configurations.
%%
%% This function instructs the underlying C binary to open the POSIX device descriptor
%% (e.g., /dev/ttyUSB0) and apply the requested hardware configurations via the termios API.
%%
%% It blocks the calling process until the OS confirms the port is successfully configured.
%%
%% **Default Options:**
%% * baudrate: 9600
%% * bytesize: 8
%% * parity: none
%% * stopbits: 1
%% * timeout: 5.0 (seconds)
%% * write_timeout: 5.0 (seconds)
%%
%% Returns ok if the hardware is ready, or {error, Reason} (e.g., permission denied, device not found).
-spec open(pid(), string() | binary(), serial_options()) -> ok | {error, term()}.
open(Pid, PortName, Opts) ->
    Defaults = #{
        baudrate => 9600, bytesize => 8, parity => none, stopbits => 1,
        xonxoff => false, rtscts => false, dsrdtr => false, exclusive => false,
        drop_reads => false, timeout => 5.0, write_timeout => 5.0
    },
    MergedOpts = maps:merge(Defaults, maps:from_list(Opts)),
    gen_server:call(Pid, {open, PortName, MergedOpts}, infinity).

%% @doc Writes binary data to the physical serial port.
%%
%% Pushes the provided data to the OS-level transmission buffer. This function is
%% synchronous and blocks the caller until the OS confirms the write succeeded, or
%% until write_timeout expires.
%%
%% Note: A successful return means the OS accepted the data, not necessarily that the
%% physical hardware has finished transmitting every byte over the wire. Use flush/1
%% if you need absolute transmission confirmation.
-spec write(pid(), iodata()) -> ok | {error, term()}.
write(Pid, Data) ->
    %% FIX: send Data and let the gen_server look up write_timeout itself,
    %% avoiding the previous two-call race condition.
    gen_server:call(Pid, {write, iolist_to_binary(Data)}, infinity).

%% @doc Reads all currently buffered data without blocking.
%%
%% Instantly retrieves whatever data currently resides in the Erlang gen_server's
%% memory buffer. Returns {ok, <<>>} if no data has arrived yet.
-spec read(pid()) -> {ok, binary()}.
read(Pid) ->
    gen_server:call(Pid, read_all).

%% @doc Blocks until exactly N bytes are read.
%%
%% Suspends the calling process until the hardware receives exactly the specified
%% number of bytes.
%%
%% **Timeout Behavior:** If the timeout (configured during open/3) expires before N
%% bytes arrive, returns whatever partial data was collected. Returns {ok, <<>>} if
%% nothing arrived.
-spec read(pid(), pos_integer()) -> {ok, binary()} | {error, term()}.
read(Pid, N) when is_integer(N), N > 0 ->
    gen_server:call(Pid, {read_size, N}, infinity).

%% @doc Blocks until a newline character (\n) is read.
%%
%% A convenience wrapper for read_until. Commonly used for reading
%% ASCII-based protocols or AT command responses.
%%
%% **Timeout Behavior:** Returns partial data if the timeout expires before a newline.
-spec readline(pid()) -> {ok, binary()} | {error, term()}.
readline(Pid) ->
    read_until(Pid, <<"\n">>).

%% @doc Blocks until a specific binary sequence is encountered.
%%
%% Suspends the calling process and continuously buffers incoming data until the
%% exact Expected sequence is found. The returned binary includes the expected
%% sequence at the very end.
%%
%% **Timeout Behavior:** Returns partial data if the timeout expires before the sequence.
-spec read_until(pid(), binary()) -> {ok, binary()} | {error, term()}.
read_until(Pid, Expected) when is_binary(Expected) ->
    gen_server:call(Pid, {read_until, Expected}, infinity).

%% @doc Sets the state of the Request To Send (RTS) hardware pin.
%%
%% Manually forces the RTS line high (true) or low (false). Only effective if
%% hardware flow control (rtscts) is disabled.
-spec set_rts(pid(), boolean()) -> ok | {error, term()}.
set_rts(Pid, Value) when is_boolean(Value) ->
    IntVal = case Value of true -> 1; false -> 0 end,
    gen_server:call(Pid, {modem_set, 0, IntVal}).

%% @doc Sets the state of the Data Terminal Ready (DTR) hardware pin.
%%
%% Manually forces the DTR line high (true) or low (false). Often used to trigger
%% physical resets on connected microcontrollers (e.g., Arduino).
-spec set_dtr(pid(), boolean()) -> ok | {error, term()}.
set_dtr(Pid, Value) when is_boolean(Value) ->
    IntVal = case Value of true -> 1; false -> 0 end,
    gen_server:call(Pid, {modem_set, 1, IntVal}).

%% @doc Retrieves the current boolean state of the hardware input pins.
%%
%% Queries the OS for the physical voltage status of the incoming modem control lines.
%% Returns a map containing:
%% * cts: Clear To Send
%% * dsr: Data Set Ready
%% * ri: Ring Indicator
%% * cd: Carrier Detect
-spec get_signals(pid()) -> {ok, signal_map()} | {error, term()}.
get_signals(Pid) ->
    gen_server:call(Pid, get_signals).

%% @doc Clears all unread data from the input buffers.
%%
%% Instructs the OS to discard any incoming data currently held in the kernel buffer,
%% then empties the Erlang gen_server memory buffer.
-spec reset_input_buffer(pid()) -> ok | {error, term()}.
reset_input_buffer(Pid) ->
    gen_server:call(Pid, {buffer_op, 1}).

%% @doc Clears all unwritten data from the output buffer.
%%
%% Instructs the OS to discard any data sitting in the kernel's transmission queue
%% that has not yet been physically sent over the wire.
-spec reset_output_buffer(pid()) -> ok | {error, term()}.
reset_output_buffer(Pid) ->
    gen_server:call(Pid, {buffer_op, 2}).

%% @doc Blocks until the transmission queue is empty.
%%
%% Suspends the calling process until the OS confirms that every byte previously
%% queued via write/2 has been physically transmitted across the serial wire.
-spec flush(pid()) -> ok | {error, term()}.
flush(Pid) ->
    gen_server:call(Pid, {buffer_op, 4}, infinity).

%% @doc Gracefully closes the serial connection.
%%
%% Instructs the OS to release the file descriptor lock on the hardware device.
%% Any Erlang processes currently blocked on a read operation will be unblocked
%% and receive {error, closed}. The gen_server process stays alive and can be
%% re-opened via open/2,3.
-spec close(pid()) -> ok.
close(Pid) ->
    gen_server:call(Pid, close).

%% --- Callbacks ---

init([]) ->
    ExtPrg = filename:join(code:priv_dir(serierl), "serierl_port"),
    Port = open_port({spawn, ExtPrg}, [{packet, 2}, binary, exit_status]),
    {ok, #state{port = Port}}.

%% FIX: open/modem_set/buffer_op/get_signals/write all previously called
%% wait_for_ack/1 (a blocking receive) directly inside handle_call, which
%% froze the gen_server process for up to 5 seconds — preventing it from
%% receiving incoming serial data or any other messages during that window.
%%
%% They now use the async pending_ack pattern: store the caller's From
%% reference and a timeout timer in state, return {noreply, ...}, and resolve
%% the reply in handle_info when the C port's response arrives.

handle_call({open, PortName, Opts}, From, #state{pending_ack = undefined} = State) ->
    PortBin = case is_list(PortName) of true -> list_to_binary(PortName); false -> PortName end,

    Baudrate   = maps:get(baudrate, Opts),
    ByteSize   = maps:get(bytesize, Opts),
    ParityInt  = case maps:get(parity, Opts) of none->0; odd->1; even->2; mark->3; space->4 end,
    StopBitsInt = case maps:get(stopbits, Opts) of 1 -> 1; 2 -> 2 end,

    XonXoff  = case maps:get(xonxoff, Opts)  of true -> 1; false -> 0 end,
    RtsCts   = case maps:get(rtscts, Opts)   of true -> 1; false -> 0 end,
    DsrDtr   = case maps:get(dsrdtr, Opts)   of true -> 1; false -> 0 end,
    FlowMask = (XonXoff bsl 0) bor (RtsCts bsl 1) bor (DsrDtr bsl 2),

    ExclusiveInt = case maps:get(exclusive, Opts) of true -> 1; false -> 0 end,
    DropReads    = maps:get(drop_reads, Opts),

    Payload = <<1:8, Baudrate:32/big-unsigned-integer, ByteSize:8, ParityInt:8,
                StopBitsInt:8, FlowMask:8, ExclusiveInt:8, PortBin/binary, 0:8>>,

    port_command(State#state.port, Payload),
    TimerRef = erlang:send_after(?ACK_TIMEOUT_MS, self(), {ack_timeout, From}),
    NewState = State#state{
        opts       = Opts,
        drop_reads = DropReads,
        buffer     = <<>>,
        pending_ack = {From, TimerRef, {open, DropReads, Opts}}
    },
    {noreply, NewState};

handle_call({write, Data}, From, #state{pending_ack = undefined} = State) ->
    %% FIX: write now waits for a C-side ack so errors are no longer silently
    %% dropped. The C port sends <<0>> on success, <<1, Reason/binary>> on failure.
    %% write_timeout is looked up here, eliminating the old two-call race.
    WriteTimeoutMs = to_ms(maps:get(write_timeout, State#state.opts, infinity)),
    port_command(State#state.port, <<2:8, Data/binary>>),
    TimerRef = case WriteTimeoutMs of
        infinity -> erlang:send_after(?ACK_TIMEOUT_MS, self(), {ack_timeout, From});
        Ms       -> erlang:send_after(Ms, self(), {ack_timeout, From})
    end,
    {noreply, State#state{pending_ack = {From, TimerRef, write}}};

handle_call({modem_set, Pin, Val}, From, #state{pending_ack = undefined} = State) ->
    port_command(State#state.port, <<4:8, Pin:8, Val:8>>),
    TimerRef = erlang:send_after(?ACK_TIMEOUT_MS, self(), {ack_timeout, From}),
    {noreply, State#state{pending_ack = {From, TimerRef, modem_set}}};

handle_call({buffer_op, Action}, From, #state{pending_ack = undefined} = State) ->
    port_command(State#state.port, <<5:8, Action:8>>),
    TimerRef = erlang:send_after(?ACK_TIMEOUT_MS, self(), {ack_timeout, From}),
    {noreply, State#state{pending_ack = {From, TimerRef, {buffer_op, Action}}}};

handle_call(get_signals, From, #state{pending_ack = undefined} = State) ->
    port_command(State#state.port, <<6:8>>),
    TimerRef = erlang:send_after(?ACK_TIMEOUT_MS, self(), {ack_timeout, From}),
    {noreply, State#state{pending_ack = {From, TimerRef, get_signals}}};

%% Guard: reject new ack-requiring calls while one is already in flight.
handle_call(Call, _From, #state{pending_ack = {_, _, _}} = State)
  when element(1, Call) =:= open;
       element(1, Call) =:= write;
       element(1, Call) =:= modem_set;
       element(1, Call) =:= buffer_op;
       Call =:= get_signals ->
    {reply, {error, busy}, State};

handle_call(read_all, _From, State) ->
    {reply, {ok, State#state.buffer}, State#state{buffer = <<>>}};

handle_call({read_size, N}, From, State = #state{opts = Opts}) ->
    TimeoutMs = to_ms(maps:get(timeout, Opts, infinity)),
    TimerRef = case TimeoutMs of
        infinity -> make_ref();
        _        -> erlang:send_after(TimeoutMs, self(), {read_timeout, From})
    end,
    NewState = State#state{pending_read = {From, TimerRef, {size, N}}},
    {noreply, process_pending_read(NewState)};

handle_call({read_until, Expected}, From, State = #state{opts = Opts}) ->
    TimeoutMs = to_ms(maps:get(timeout, Opts, infinity)),
    TimerRef = case TimeoutMs of
        infinity -> make_ref();
        _        -> erlang:send_after(TimeoutMs, self(), {read_timeout, From})
    end,
    NewState = State#state{pending_read = {From, TimerRef, {until, Expected}}},
    {noreply, process_pending_read(NewState)};

handle_call(close, _From, State) ->
    %% Send close command to C port so it releases the serial fd cleanly.
    port_command(State#state.port, <<3:8>>),
    %% Unblock any pending read caller.
    case State#state.pending_read of
        {WaitingFrom, TimerRef, _} ->
            erlang:cancel_timer(TimerRef),
            gen_server:reply(WaitingFrom, {error, closed});
        undefined -> ok
    end,
    %% Cancel any in-flight ack waiter.
    case State#state.pending_ack of
        {AckFrom, AckTimer, _} ->
            erlang:cancel_timer(AckTimer),
            gen_server:reply(AckFrom, {error, closed});
        undefined -> ok
    end,
    {reply, ok, State#state{
        is_open      = false,
        buffer       = <<>>,
        pending_read = undefined,
        pending_ack  = undefined
    }}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% --- Ack responses from the C port ---

%% Simple ok ack (open, modem_set, buffer_op, write).
handle_info({Port, {data, <<0:8>>}}, #state{port = Port, pending_ack = {From, TimerRef, AckType}} = State) ->
    erlang:cancel_timer(TimerRef),
    NewState = case AckType of
        {open, DropReads, Opts} ->
            State#state{is_open = true, drop_reads = DropReads, opts = Opts, pending_ack = undefined};
        {buffer_op, Action} when Action =:= 1; Action =:= 3 ->
            State#state{buffer = <<>>, pending_ack = undefined};
        _ ->
            State#state{pending_ack = undefined}
    end,
    gen_server:reply(From, ok),
    {noreply, NewState};

%% Error ack (open, modem_set, buffer_op, write).
handle_info({Port, {data, <<1:8, Err/binary>>}}, #state{port = Port, pending_ack = {From, TimerRef, _}} = State) ->
    erlang:cancel_timer(TimerRef),
    gen_server:reply(From, {error, binary_to_list(Err)}),
    {noreply, State#state{pending_ack = undefined}};

%% Signals response: <<0, Mask>>.
handle_info({Port, {data, <<0:8, Mask:8>>}}, #state{port = Port, pending_ack = {From, TimerRef, get_signals}} = State) ->
    erlang:cancel_timer(TimerRef),
    Map = #{
        cts => (Mask band (1 bsl 0)) > 0,
        dsr => (Mask band (1 bsl 1)) > 0,
        ri  => (Mask band (1 bsl 2)) > 0,
        cd  => (Mask band (1 bsl 3)) > 0
    },
    gen_server:reply(From, {ok, Map}),
    {noreply, State#state{pending_ack = undefined}};

%% Ack timeout: the C port did not respond in time.
handle_info({ack_timeout, From}, #state{pending_ack = {From, _TimerRef, _}} = State) ->
    gen_server:reply(From, {error, timeout}),
    {noreply, State#state{pending_ack = undefined}};

handle_info({ack_timeout, _Stale}, State) ->
    {noreply, State};

%% --- Read timeout ---

handle_info({read_timeout, From}, State = #state{pending_read = {From, _Ref, _Criteria}}) ->
    gen_server:reply(From, {ok, State#state.buffer}),
    {noreply, State#state{buffer = <<>>, pending_read = undefined}};

handle_info({read_timeout, _StaleFrom}, State) ->
    {noreply, State};

%% --- Incoming serial data from the C port (cmd byte 2) ---

handle_info({Port, {data, <<2:8, Incoming/binary>>}}, #state{port = Port} = State) ->
    case State#state.drop_reads of
        true ->
            {noreply, State};
        false ->
            NewBuf   = <<(State#state.buffer)/binary, Incoming/binary>>,
            NewState = process_pending_read(State#state{buffer = NewBuf}),
            {noreply, NewState}
    end;

%% --- C port exited ---

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    %% Unblock any waiting callers before crashing.
    case State#state.pending_read of
        {ReadFrom, ReadTimer, _} ->
            erlang:cancel_timer(ReadTimer),
            gen_server:reply(ReadFrom, {error, port_crashed});
        undefined -> ok
    end,
    case State#state.pending_ack of
        {AckFrom, AckTimer, _} ->
            erlang:cancel_timer(AckTimer),
            gen_server:reply(AckFrom, {error, port_crashed});
        undefined -> ok
    end,
    {stop, {port_crashed, Status}, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.port of
        undefined -> ok;
        Port      -> port_close(Port)
    end.

%% --- Internal helpers ---

%% FIX: '1.5' stop bits removed — POSIX termios only supports 1 or 2.
%% The type spec has been narrowed to match. Passing '1.5' previously fell
%% through to the else branch in C and silently configured 1 stop bit.

-spec to_ms(infinity | float() | integer()) -> infinity | non_neg_integer().
to_ms(infinity)                      -> infinity;
to_ms(Seconds) when is_float(Seconds)   -> trunc(Seconds * 1000);
to_ms(Seconds) when is_integer(Seconds) -> Seconds * 1000.

-spec process_pending_read(#state{}) -> #state{}.
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
        nomatch ->
            State
    end;
process_pending_read(State = #state{pending_read = {From, TimerRef, {size, N}}, buffer = Buf}) ->
    case byte_size(Buf) >= N of
        true ->
            erlang:cancel_timer(TimerRef),
            <<ReturnChunk:N/binary, RestBuf/binary>> = Buf,
            gen_server:reply(From, {ok, ReturnChunk}),
            State#state{buffer = RestBuf, pending_read = undefined};
        false ->
            State
    end.
