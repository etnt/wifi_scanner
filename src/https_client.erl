%%%-------------------------------------------------------------------
%%% @doc Minimal HTTPS POST client using AtomVM's ssl module.
%%%
%%% Provides a simple function to POST binary data to an HTTPS
%%% endpoint and return the response body.
%%% @end
%%%-------------------------------------------------------------------
-module(https_client).

-export([post/5]).

%% @doc Perform an HTTPS POST request.
%% Host: hostname string
%% Port: port number (typically 443)
%% Path: request path (e.g., "/clls/wloc")
%% Body: binary request body
%% Headers: list of {Name, Value} tuples (binaries)
%% Returns {ok, ResponseBody} | {error, Reason}
-spec post(string(), inet:port_number(), string(), binary(), [{binary(), binary()}]) ->
    {ok, binary()} | {error, any()}.
post(Host, Port, Path, Body, Headers) ->
    ok = ssl:start(),
    case net:getaddrinfo(Host) of
        {ok, [#{addr := AddrMap} | _]} ->
            #{addr := IpAddr} = AddrMap,
            TLSOpts = [
                binary,
                {active, false},
                {verify, verify_none},
                {server_name_indication, Host}
            ],
            case ssl:connect(IpAddr, Port, TLSOpts) of
                {ok, Socket} ->
                    Request = build_http_request(Host, Path, Body, Headers),
                    case ssl:send(Socket, Request) of
                        ok ->
                            Result = recv_response(Socket, <<>>),
                            ssl:close(Socket),
                            Result;
                        {error, SendErr} ->
                            ssl:close(Socket),
                            {error, {send_failed, SendErr}}
                    end;
                {error, ConnErr} ->
                    {error, {connect_failed, ConnErr}}
            end;
        {error, DnsErr} ->
            {error, {dns_failed, DnsErr}}
    end.

%%%===================================================================
%%% Internal
%%%===================================================================

%% Build a raw HTTP/1.1 POST request.
build_http_request(Host, Path, Body, ExtraHeaders) ->
    ContentLength = integer_to_list(byte_size(Body)),
    HeaderLines = lists:map(fun({Name, Value}) ->
        [Name, <<": ">>, Value, <<"\r\n">>]
    end, ExtraHeaders),
    iolist_to_binary([
        "POST ", Path, " HTTP/1.1\r\n",
        "Host: ", Host, "\r\n",
        "Content-Length: ", ContentLength, "\r\n",
        "Connection: close\r\n",
        HeaderLines,
        "\r\n",
        Body
    ]).

%% Receive the full HTTP response.
%% Server closes connection (Connection: close), so we read until closed.
recv_response(Socket, Acc) ->
    case ssl:recv(Socket, 0) of
        {ok, Data} ->
            recv_response(Socket, <<Acc/binary, Data/binary>>);
        {error, closed} ->
            parse_http_response(Acc);
        {error, Reason} ->
            case byte_size(Acc) > 0 of
                true -> parse_http_response(Acc);
                false -> {error, {recv_failed, Reason}}
            end
    end.

%% Parse HTTP response: split headers from body at \r\n\r\n.
parse_http_response(Raw) ->
    case binary:split(Raw, <<"\r\n\r\n">>) of
        [Headers, Body] ->
            %% Handle chunked transfer encoding
            case binary:match(Headers, <<"chunked">>) of
                nomatch ->
                    {ok, Body};
                _ ->
                    {ok, dechunk(Body)}
            end;
        _ ->
            {error, malformed_response}
    end.

%% Decode chunked transfer encoding body.
dechunk(Data) ->
    dechunk(Data, <<>>).

dechunk(<<>>, Acc) ->
    Acc;
dechunk(Data, Acc) ->
    case binary:split(Data, <<"\r\n">>) of
        [ChunkSizeHex, Rest] ->
            ChunkSize = hex_to_int(ChunkSizeHex),
            case ChunkSize of
                0 -> Acc;
                _ ->
                    <<Chunk:ChunkSize/binary, _Sep/binary>> = Rest,
                    %% Skip the chunk data + \r\n after it
                    Remaining = case byte_size(Rest) > ChunkSize + 2 of
                        true ->
                            <<_:ChunkSize/binary, "\r\n", R/binary>> = Rest,
                            R;
                        false ->
                            <<>>
                    end,
                    dechunk(Remaining, <<Acc/binary, Chunk/binary>>)
            end;
        _ ->
            Acc
    end.

hex_to_int(Bin) ->
    hex_to_int(Bin, 0).

hex_to_int(<<>>, Acc) ->
    Acc;
hex_to_int(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    hex_to_int(Rest, Acc * 16 + (C - $0));
hex_to_int(<<C, Rest/binary>>, Acc) when C >= $a, C =< $f ->
    hex_to_int(Rest, Acc * 16 + (C - $a + 10));
hex_to_int(<<C, Rest/binary>>, Acc) when C >= $A, C =< $F ->
    hex_to_int(Rest, Acc * 16 + (C - $A + 10));
hex_to_int(_, Acc) ->
    Acc.
