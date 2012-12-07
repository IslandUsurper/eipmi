%%%=============================================================================
%%% Copyright (c) 2012 Lindenbaum GmbH
%%%
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% @doc
%%% A module providing reading and decoding functionality for the System
%%% Event Log (SEL).
%%% @end
%%%=============================================================================

-module(eipmi_sel).

-export([read/2,
         clear/1]).

-include("eipmi.hrl").

-define(READ, {?IPMI_NETFN_STORAGE_REQUEST, ?GET_SEL_ENTRY}).
-define(GET_INFO, {?IPMI_NETFN_STORAGE_REQUEST, ?GET_SEL_INFO}).
-define(RESERVE, {?IPMI_NETFN_STORAGE_REQUEST, ?RESERVE_SEL}).
-define(CLEAR, {?IPMI_NETFN_STORAGE_REQUEST, ?CLEAR_SEL}).

-type record_type() :: system_event | oem_timestamped | oem_non_timestamped.

-type entry() ::
        {record_type(),
         [{record_id, non_neg_integer()} |
          {type, record_type()} |
          {oem_type, non_neg_integer()} |
          {time, non_neg_integer()} |
          {manufacturer_id, non_neg_integer()} |
          {data, binary()} |
          {revision, non_neg_integer()} |
          {sensor_type, eipmi_sensor:type()} |
          {sensor_number, non_neg_integer()} |
          {raw_reading, binary()} |
          {raw_threshold, binary()} |
          eipmi_sensor:value() |
          eipmi_sensor:addr()]}.

-export_type([entry/0]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Read all entries from the system event log and optionally clear the log.
%% Reading the SEL without clearing it is implemented in a way that will only
%% send the least number of packets (no SEL reservation or info requests). Thus,
%% if a user knows that read SEL entries will be cleared automatically by the
%% BMC the user should not clear the SEL explicitly.
%% @end
%%------------------------------------------------------------------------------
-spec read(pid(), boolean()) -> [entry()].
read(SessionPid, true) ->
    {ok, SelInfo} = eipmi_session:rpc(SessionPid, ?GET_INFO, []),
    Entries = do_read(SessionPid, proplists:get_value(entries, SelInfo)),
    Operations = proplists:get_value(operations, SelInfo),
    ?EIPMI_CATCH(do_clear(SessionPid, lists:member(reserve, Operations))),
    Entries;
read(SessionPid, false) ->
    do_read(SessionPid, all).

%%------------------------------------------------------------------------------
%% @doc
%% Clear the system event log regardless whether events have been read/processed
%% by any user application.
%% @end
%%------------------------------------------------------------------------------
-spec clear(pid()) -> ok | {error, term()}.
clear(SessionPid) ->
    do_clear(SessionPid).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
do_read(_SessionPid, 0) ->
    [];
do_read(SessionPid, _NumEntries) ->
    do_read(SessionPid, 16#0000, []).
do_read(_SessionPid, 16#ffff, Acc) ->
    lists:reverse(Acc);
do_read(SessionPid, Id, Acc) ->
    case eipmi_session:rpc(SessionPid, ?READ, [{record_id, Id}]) of
        {ok, Entry} ->
            NextId = proplists:get_value(next_record_id, Entry),
            Sel = decode(proplists:get_value(data, Entry)),
            do_read(SessionPid, NextId, [Sel | Acc]);
        {error, {bmc_error, _}} ->
            Acc
    end.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
do_clear(SessionPid) ->
    {ok, SelInfo} = eipmi_session:rpc(SessionPid, ?GET_INFO, []),
    Operations = proplists:get_value(operations, SelInfo),
    do_clear(SessionPid, lists:member(reserve, Operations)).
do_clear(SessionPid, true) ->
    {ok, Reserve} = eipmi_session:rpc(SessionPid, ?RESERVE, []),
    ReservationId = proplists:get_value(reservation_id, Reserve),
    do_clear(SessionPid, ReservationId, true, false);
do_clear(SessionPid, false) ->
    do_clear(SessionPid, 16#0000, true, false).
do_clear(_SessionPid, _ReservationId, _Initiate, true) ->
    ok;
do_clear(SessionPid, ReservationId, Initiate, false) ->
    Args = [{reservation_id, ReservationId}, {initiate, Initiate}],
    {ok, Clr} = eipmi_session:rpc(SessionPid, ?CLEAR, Args),
    Completed = proplists:get_value(progress, Clr) =:= completed,
    do_clear(SessionPid, ReservationId, false, Completed).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode(<<Id:16/little, 16#02:8, Rest/binary>>) ->
    {system_event,
     decode_system_event0([{record_id, Id}, {type, system_event}], Rest)};
decode(<<Id:16/little, Type:8, Rest/binary>>)
  when Type >= 16#c0 andalso Type =< 16#df ->
    {oem_timestamped,
     decode_oem_timestamped(
       [{record_id, Id}, {type, oem_timestamped}, {oem_type, Type}], Rest)};
decode(<<Id:16/little, Type:8, Rest/binary>>)
  when Type >= 16#e0 andalso Type =< 16#ff ->
    {oem_non_timestamped,
     decode_oem_non_timestamped(
       [{record_id, Id}, {type, oem_non_timestamped}, {oem_type, Type}], Rest)}.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_system_event0(Acc, <<Time:32/little, Generator:2/binary, Rest/binary>>) ->
    NewAcc = Acc ++ [{time, Time}] ++ eipmi_sensor:get_addr(Generator),
    decode_system_event1(NewAcc, Rest).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_system_event1(Acc, <<16#04:8, SensorType:8, SensorNum:8, Assertion:1,
                            EventType:7, EventData/binary>>) ->
    Reading = {_, Sensor} = eipmi_sensor:get_type(EventType, SensorType),
    Acc ++ [{revision, 16#04}, {sensor_type, Sensor}, {sensor_number, SensorNum}]
        ++ decode_event_data(Reading, Assertion, EventData);
decode_system_event1(Acc, <<Revision:8, Data/binary>>) ->
    Acc ++ [{revision, Revision}, {data, Data}].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_oem_timestamped(Acc, <<Time:32/little, M:24/little, Data/binary>>) ->
    Acc ++ [{time, Time}, {manufacturer_id, M}, {data, Data}].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_oem_non_timestamped(Acc, <<Data/binary>>) ->
    Acc ++ [{data, Data}].

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_event_data({threshold, Type}, Assertion, Data) ->
    decode_threshold(Type, Assertion, pad_event_data(Data));
decode_event_data({discrete, Type}, Assertion, Data) ->
    decode_generic(Type, Assertion, pad_event_data(Data));
decode_event_data({{oem, _}, Type}, Assertion, Data) ->
    decode_oem(Type, Assertion, pad_event_data(Data)).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_threshold(Type, Assertion, <<1:2, 0:2, Offset:4, B2:8, _:8>>) ->
    eipmi_sensor:get_value(Type, Offset, Assertion, 16#ff, 16#ff)
        ++ [{raw_reading, <<B2:8>>}];
decode_threshold(Type, Assertion, <<1:2, 1:2, Offset:4, B2:8, B3:8>>) ->
    eipmi_sensor:get_value(Type, Offset, Assertion, 16#ff, 16#ff)
        ++ [{raw_reading, <<B2:8>>}, {raw_threshold, <<B3:8>>}];
decode_threshold(Type, Assertion, <<E2:2, E3:2, Offset:4, B2:8, B3:8>>) ->
    Byte2 = case E2 of 0 -> 16#ff; _ -> B2 end,
    Byte3 = case E3 of 0 -> 16#ff; _ -> B3 end,
    eipmi_sensor:get_value(Type, Offset, Assertion, Byte2, Byte3).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_generic(Type, Assertion, <<1:2, E3:2, Offset:4, SOff:4, POff:4, B3:8>>) ->
    Severity = maybe_value(severity_value, severity, SOff, 0),
    Previous = maybe_value(previous_value, Type, POff, Assertion),
    decode_generic(Type, Assertion, <<0:2, E3:2, Offset:4, 16#ff:8, B3:8>>)
        ++ Severity ++ Previous;
decode_generic(Type, Assertion, <<E2:2, E3:2, Offset:4, B2:8, B3:8>>) ->
    Byte2 = case E2 of 0 -> 16#ff; _ -> B2 end,
    Byte3 = case E3 of 0 -> 16#ff; _ -> B3 end,
    eipmi_sensor:get_value(Type, Offset, Assertion, Byte2, Byte3).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
decode_oem(Type, Assertion, <<1:2, E3:2, Offset:4, SOff:4, POff:4, B3:8>>) ->
    Severity = maybe_value(severity_value, severity, SOff, 0),
    Previous = maybe_value(previous_value, Type, POff, Assertion),
    decode_oem(Type, Assertion, <<0:2, E3:2, Offset:4, 16#ff:8, B3:8>>)
        ++ Severity ++ Previous;
decode_oem(Type, Assertion, <<E2:2, E3:2, Offset:4, B2:8, B3:8>>) ->
    Byte2 = case E2 of 2 -> B2; _ -> 16#ff end,
    Byte3 = case E3 of 2 -> B3; _ -> 16#ff end,
    eipmi_sensor:get_value(Type, Offset, Assertion, Byte2, Byte3).

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
pad_event_data(Data = <<_:1/binary>>) ->
    <<Data/binary, 16#ff:8, 16#ff:8>>;
pad_event_data(Data = <<_:2/binary>>) ->
    <<Data/binary, 16#ff:8>>;
pad_event_data(Data = <<_:3/binary>>) ->
    Data.

%%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
maybe_value(_Tag, _Type, 16#f, _Assert) ->
    [];
maybe_value(Tag, Type, Offset, Assert) ->
    Vs = eipmi_sensor:get_value(Type, Offset, Assert, 16#ff, 16#ff),
    [{Tag, proplists:get_value(sensor_value, Vs)}].
