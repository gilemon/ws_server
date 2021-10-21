%%%-------------------------------------------------------------------
%% @doc ws_server public API
%% @end
%%%-------------------------------------------------------------------

-module(ws_server_app).

-behaviour(application).

-export([start/2, stop/1, accept/3]).

start(_StartType, _StartArgs) ->
	% Listen for incoming connexion requests
	lists:map(fun({LineTrigram, PortNumber}) -> listen(LineTrigram, PortNumber) end, [{"ISL", 50002}]),
    ws_server_sup:start_link().

stop(_State) ->
    ok.

%% internal functions

listen(LineTrigram, PortNumber) ->
	%[{local_ip_alias, LocalIpAlias}] = context:get(?MODULE, local_ip_alias),
	{ok, LocalIpAddress} = inet:getaddr("localhost", inet),
	case gen_tcp:listen(PortNumber, [binary, {keepalive, true}, {nodelay, true}, {packet, raw}, {reuseaddr, true}, {ip, LocalIpAddress}]) of
		{ok, ListenSocket} ->
			%logger ! {log, info, self(), "Listening on port ~p for ~s~n", [PortNumber, LineTrigram]},
			
			% Spawn the accepting process
			spawn(?MODULE, accept, [ListenSocket, LineTrigram, 1]);
		{error, Reason} ->
			%logger ! {log, error, self(), "Unable to listen on port ~p for ~s: ~p~n", [PortNumber, LineTrigram, Reason]},
            ok = io:format("Unable to listen on port ~p for ~s: ~p~n", [PortNumber, LineTrigram, Reason]),
			listen(LineTrigram, PortNumber)
	end.
    
accept(ListenSocket, LineTrigram, InterfaceNumber) ->
	% Register the new MIMIC interface
	ProcessName = lists:concat([mimic_interface_, LineTrigram, "_", InterfaceNumber]),
	register(list_to_atom(ProcessName), self()),
	%logger ! {log, info, self(), "Registered ~p as ~p~n", [self(), ProcessName]},
    ok = io:format("Registered ~p as ~p~n", [self(), ProcessName]),

	
	% Initialize context
    ok = io:format("Initializing context~n"),
	context:new(),
	%lists:map(fun(X) -> context:set(X) end, MimicInterfaceParameters),
	context:set({link_status, disconnected}),
	context:set({sequence_number_in, 0}),
	context:set({sequence_number_out, 0}),
	context:set({current_websocket_length, 0}),
	context:set({current_websocket_data, <<>>}),
	context:set({current_tcp_data, <<>>}),
	%{atomic, LineKey} = mnesia:sync_transaction(fun(X) ->
	%			MatchingLineRecord = #lines{key = '$1', trigram = X, _ = '_'},
	%			[Key] = mnesia:select(lines, [{MatchingLineRecord, [], ['$1']}], read),
	%			Key
	%	end, [LineTrigram]),
	%context:set({line_key, LineKey}),
	
	case gen_tcp:accept(ListenSocket) of
		{ok, AcceptSocket} ->
			% Send a request to increase the number of clients
			%?MODULE ! {clients, increase, self()},

			% Store the socket reference
            ok = io:format("Accepted connexion on socket: ~p~n", [AcceptSocket]),
			context:set({accept_socket, AcceptSocket}),
			
			% Spawn the health status request timeout
			%start_health_status_request_timer(),
			
			% Read incoming messages
            ok = io:format("Read incoming messages~n"),
			read_messages(ListenSocket, AcceptSocket, LineTrigram, InterfaceNumber);
		
		{error, Reason} ->
			ok = io:format("Unable to accept socket: ~p~nExiting~n", [Reason]),
			close_socket_and_exit()
	end.
    
close_socket_and_exit() ->
	% Close the socket
    ok = io:format("Closing socket~n"),
	[{accept_socket, Socket}] = context:get(accept_socket),
	ok = gen_tcp:close(Socket),
    
	% Decrease the number of clients
	?MODULE ! {clients, decrease, self()},
	receive
		{ok, decreased} ->
			% Stop the process
			ok = io:format("Link is disconnected (process stopping)~n")
	end,
	exit(ok).

read_messages(ListenSocket, AcceptSocket, LineTrigram, InterfaceNumber) ->
	receive
		{ok, increased} ->			
			% Calculate the next interface number
			NextInterfaceNumber = InterfaceNumber + 1,

			% Create a new listening process for the next client
			spawn(?MODULE, accept, [ListenSocket, LineTrigram, NextInterfaceNumber]);

		{error, full} ->
			% Calculate the next interface number
			NextInterfaceNumber = InterfaceNumber + 1,

			% Create a new listening process for the next client
			spawn(?MODULE, accept, [ListenSocket, LineTrigram, NextInterfaceNumber]),
			close_socket_and_exit();

		% Send the new HMI status if updated
		%{mnesia_table_event, {write, _, NewRecord, [OldRecord], _}} ->
		%	[{line_key, LineKey}] = context:get(line_key),
		%	case database:is_on_line(NewRecord, LineKey) of
		%		true ->
		%			case database:compare_records(hmi_fields, OldRecord, NewRecord) of
		%				different ->
		%					logger ! {log, debug, self(), "New status received: ~p~n", [NewRecord]},
		%					{atomic, {ok, Message}} = mnesia:sync_transaction(fun mimic_interface:message/1, [NewRecord]),
		%					send_websockets_message(Message);
		%				_ ->
		%					ok
		%			end;
		%		_ ->
		%			noop
		%	end;
		
		% Read the tcp frame
		{tcp, AcceptSocket, Data} ->
			% Bufferize received TCP data
			[{current_tcp_data, CurrentTcpData}] = context:get(current_tcp_data),
			BufferedData = <<CurrentTcpData/binary, Data/binary>>,
			context:set({current_tcp_data, BufferedData}),
			
			% Examine data
			ok = io:format("TCP buffered data :~n~p~n", [BufferedData]),
			examine_tcp_data();
		{tcp_closed, AcceptSocket} ->
			ok = io:format("TCP socket closed by peer~n"),
			close_socket_and_exit();
		{tcp_error, AcceptSocket, Reason} ->
			ok = io:format("TCP Socket error: ~p~n", [Reason]),
			close_socket_and_exit();
		{health_status_request_timeout} ->
			ok = io:format("Health status request timeout~n"),
			send_close(1000),
			close_socket_and_exit();
		{shell, Command} ->
			ok = io:format("Shell command: ~p~n", [Command]),
			shell_command(Command);
		Msg ->
			ok = io:format("Webserver received unexpected message:~n~p~n", [Msg])
	end,
	read_messages(ListenSocket, AcceptSocket, LineTrigram, InterfaceNumber).
    
examine_tcp_data() ->
	[{current_tcp_data, CurrentTcpData}] = context:get(current_tcp_data),
	[{link_status, LinkStatus}] = context:get(link_status),
	case LinkStatus of
		disconnected ->
			Tokens = string:tokens(binary_to_list(CurrentTcpData), "\r\n"),
			case decode_http_handshake(Tokens) of
				true ->
					% Send the handshake reply
					ok = send_http_handshake(),
					
					% Update the link status
					context:set({link_status, connected}),
					ok = io:format("Updating link status: disconnected -> connected~n"),
					
					% Pop the handshake from TCP data
					context:set({current_tcp_data, <<>>});
				_ ->
					ok = io:format("Invalid handshake~n")
			end;
		_ ->
			% Decode as a websockets frame
			case decode_websocket_header(CurrentTcpData) of
				{true, header_too_short} ->
					noop;
				{Fin, OpCode, MaskingKey, Length, HeaderLastIndex} ->
					if
						byte_size(CurrentTcpData) < (HeaderLastIndex + Length) ->
							% Wait for complete message
							ok = io:format("Expecting ~p bytes, got only ~p, bufferizing~n", [HeaderLastIndex + Length, byte_size(CurrentTcpData)]);
						true ->
							% Message complete, get the payload
							ok = io:format("Expecting ~p bytes, got ~p, treating message~n", [HeaderLastIndex + Length, byte_size(CurrentTcpData)]),
							
							% Pop the message from the TCP data
							<<_:HeaderLastIndex/binary, Payload:Length/binary, Rest/binary>> = CurrentTcpData,
							context:set({current_tcp_data, Rest}),
							
							% Get current buffer details
							[{current_websocket_data, CurrentWebsocketData}] = context:get(current_websocket_data),
							[{current_websocket_length, CurrentWebsocketLength}] = context:get(current_websocket_length),
							case OpCode of
								0 ->
									% Bufferize the continuation payload
									UnmaskedPayload = mask_toggle(MaskingKey, Payload),
									ok = io:format("Got unmasked continuation payload:~n~p~n", [binary_to_list(UnmaskedPayload)]),
									context:set({current_websocket_data, <<CurrentWebsocketData/binary, UnmaskedPayload/binary>>}),
									context:set({current_websocket_length, CurrentWebsocketLength + Length});
								1 ->
									case CurrentWebsocketData of
										<<>> ->
											% Bufferize the initial payload
											UnmaskedPayload = mask_toggle(MaskingKey, Payload),
											ok = io:format("Got unmasked initial payload:~n~p~n", [binary_to_list(UnmaskedPayload)]),
											context:set({current_websocket_data, <<UnmaskedPayload/binary>>}),
											context:set({current_websocket_length, CurrentWebsocketLength + Length});
										_ ->
											% Received initial payload while expecting continuation payload
											ok = io:format("Received initial payload while expecting continuation payload~n"),
											send_close(1002),
											close_socket_and_exit()
									end;
								_ ->
									ok = io:format("Invalid Op code: ~p~n", [OpCode]),
									send_close(1002),
									close_socket_and_exit()
							end,
							
							case Fin of
								1 ->
									% Treat finalized frame
									ok = io:format("Websocket frame is finalized~n"),
									[{current_websocket_data, Message}] = context:get(current_websocket_data),
									XmlMessage = binary_to_list(Message),
									ok = io:format("Total websocket frame: ~n~s~n", [XmlMessage]),
									% Decode the message
									ok = io:format("Decode XML message~n"),
									decode_websocket_message(XmlMessage),
									context:set({current_websocket_data, <<>>}),
									context:set({current_websocket_length, 0});
								_ ->
									noop
							end,
							% Treat next message
							examine_tcp_data()
					end;
				{MaskingKey, StatusCodeField, HeaderLastIndex} ->
					% Pop the message from the TCP data
					<<_:HeaderLastIndex/binary, Rest/binary>> = CurrentTcpData,
					context:set({current_tcp_data, Rest}),
					
					% Treat the message
					<<StatusCode:16/big-unsigned-integer>> = mask_toggle(MaskingKey, StatusCodeField),
					ok = io:format("Websockets connection closed by peer with status code: ~p~n", [StatusCode]),
					send_close(StatusCode),
					close_socket_and_exit();
				_ ->
					ok = io:format("Unable to decode websocket header~n"),
					send_close(1002),
					close_socket_and_exit()
			end
	end.
    
decode_http_handshake(Tokens) ->
	% Decode handshake marker
	[Token | Rest] = Tokens,
	case Token of
		"GET /websession HTTP/1.1" ->
			% Store the session properties
			ok = decode_http_handshake_fields(Rest),
			ok = update_accept(),
			ok = io:format("Handshake message~n"),
			true;
		"GET / HTTP/1.1" ->
			% Store the session properties
			ok = decode_http_handshake_fields(Rest),
			ok = update_accept(),
			ok = io:format("Handshake message~n"),
			true;
		_ ->
			ok = io:format("Not a handshake message~n"),
			false
	end.

decode_http_handshake_fields(Tokens) ->
	% Decode handshake fields and store websockets options
    %<<"GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: febC5D/X50865tu8gISmcg==\r\nHost: localhost:50002\r\nSec-WebSocket-Protocol: echo-protocol\r\n\r\n">>
	case Tokens of
		[] ->
			ok;
		[Token | Rest] ->
			case string:str(Token, ": ") of
				0 ->
					ok;
				Position ->
					Field = string:left(Token, Position - 1),
					Value = string:right(Token, string:len(Token) - (Position + 1)),
					case Field of
						"Host" -> context:set({host, Value});
						"Upgrade" -> context:set({upgrade, Value});
						"Connection" -> context:set({connection, Value});
						"Sec-WebSocket-Key" -> context:set({key, Value});
						"Origin" -> context:set({origin, Value});
						"Sec-WebSocket-Protocol" -> context:set({protocol, Value});
						"Sec-WebSocket-Version" -> context:set({version, Value});
						"Pragma" -> noop;
						"Cache-Control" -> noop;
						"User-Agent" -> noop;
						"Accept-Encoding" -> noop;
						"Accept-Language" -> noop;
						"Sec-WebSocket-Extensions" -> noop;
						_ -> ok = io:format("Unknown field: ~p~n", [Field])
					end,
					decode_http_handshake_fields(Rest)
			end
	end.

decode_websocket_header(Data) ->
	DataLength = byte_size(Data),
	if
		DataLength < 2 ->
			ok = io:format("Start of websocket header not yet received, bufferizing~n"),
			{true, header_too_short};
		true ->
			case Data of
				<<Fin:1/unsigned-integer, 0:3/unsigned-integer, OpCode:4/unsigned-integer, 1:1/unsigned-integer, 126:7/unsigned-integer, _/binary>> ->
					if
						DataLength < 8 ->
							ok = io:format("Medium size websocket header incomplete, bufferizing~n"),
							{true, header_too_short};
						true ->
							<<_:2/binary, Length:16/big-unsigned-integer, MaskingKey:4/binary, _/binary>> = Data,
							HeaderLastIndex = 8,
							ok = io:format("Medium size websocket header complete: ~p~n", [{Fin, OpCode, MaskingKey, Length, HeaderLastIndex}]),
							{Fin, OpCode, MaskingKey, Length, HeaderLastIndex}
					end;
				<<Fin:1/unsigned-integer, 0:3/unsigned-integer, OpCode:4/unsigned-integer, 1:1/unsigned-integer, 127:7/unsigned-integer, _/binary>> ->
					if
						DataLength < 14 ->
							ok = io:format("Big size websocket header incomplete, bufferizing~n"),
							{true, header_too_short};
						true ->
							<<_:2/binary, Length:64/big-unsigned-integer, MaskingKey:4/binary, _/binary>> = Data,
							HeaderLastIndex = 14,
							ok = io:format("Big size websocket header complete: ~p~n", [{Fin, OpCode, MaskingKey, Length, HeaderLastIndex}]),
							{Fin, OpCode, MaskingKey, Length, HeaderLastIndex}
					end;
				<<1:1/unsigned-integer, 0:3/unsigned-integer, 8:4/unsigned-integer, 1:1/unsigned-integer, 2:7/unsigned-integer, MaskingKey:4/binary, MaskedStatusCodeField:2/binary, _/binary>> = Data ->
					HeaderLastIndex = 6,
					ok = io:format("Control websocket header complete: ~p~n", [{MaskingKey, MaskedStatusCodeField, HeaderLastIndex}]),
					{MaskingKey, MaskedStatusCodeField, HeaderLastIndex};
				<<Fin:1/unsigned-integer, 0:3/unsigned-integer, OpCode:4/unsigned-integer, 1:1/unsigned-integer, Length:7/unsigned-integer, _/binary>> ->
					if
						DataLength < 6 ->
							ok = io:format("Small size websocket header incomplete, bufferizing~n"),
							{true, header_too_short};
						true ->
							<<_:2/binary, MaskingKey:4/binary, _/binary>> = Data,
							HeaderLastIndex = 6,
							ok = io:format("Small size websocket header complete: ~p~n", [{Fin, OpCode, MaskingKey, Length, HeaderLastIndex}]),
							{Fin, OpCode, MaskingKey, Length, HeaderLastIndex}
					end;
				_ ->
					ok = io:format("Invalid websocket header~n"),
					false
			end
	end.

decode_websocket_message(XmlMessage) ->
	case XmlMessage of
		"" ->
			ok = io:format("Finished decoding websocket message~n");
		_ ->
			% Decode XML header
			case decode_xml_header(XmlMessage) of
				{true, DocumentMessage} ->
					ok = io:format("Finished decoding XML header ~p~n", [DocumentMessage]);
				false ->
					ok = io:format("Failed to decode XML header~n")
			end
	end.

send_http_handshake() ->
	% Send a handshake reply
	[{accept_socket, Socket}] = context:get(accept_socket),
	[{accept, Accept}] = context:get(accept),
	[{upgrade, Upgrade}] = context:get(upgrade),
	[{connection, Connection}] = context:get(connection),
    [{protocol, Protocol}] = context:get(protocol),
	Handshake = lists:concat(["HTTP/1.1 101 Switching Protocols\r\n",
			"Upgrade: ", Upgrade, "\r\n",
			"Connection: ", Connection, "\r\n",
            "sec-websocket-protocol: ", Protocol, "\r\n",
			"Sec-WebSocket-Accept: ", Accept, "\r\n\r\n"]),
	case gen_tcp:send(Socket, Handshake) of
		ok ->
			ok = io:format("Handshake reply sent~n");
		{error, Reason} ->
			ok = io:format("Error trying to send handshake: ~p~n", [Reason]),
			ok = io:format("Exiting~n"),
			close_socket_and_exit()
	end,
	ok.


send_websockets_message(Message) ->
	% Create a websockets frame and send it
	[{accept_socket, Socket}] = context:get(accept_socket),
	ok = io:format("Sending websockets frame: ~n~s~n", [Message]),
	MessageBinary = erlang:list_to_binary(Message),
	Length = erlang:byte_size(MessageBinary),
	if
		Length =< 16#ff ->
			Frame = <<1:1/unsigned-integer, 0:3/unsigned-integer, 16#1:4/unsigned-integer, 0:1/unsigned-integer, Length:7/unsigned-integer, MessageBinary/binary>>;
		Length =< 16#ffff ->
			Frame = <<1:1/unsigned-integer, 0:3/unsigned-integer, 16#1:4/unsigned-integer, 0:1/unsigned-integer, 126:7/unsigned-integer, Length:16/unsigned-integer, MessageBinary/binary>>;
		true ->
			Frame = <<1:1/unsigned-integer, 0:3/unsigned-integer, 16#1:4/unsigned-integer, 0:1/unsigned-integer, 127:7/unsigned-integer, Length:64/unsigned-integer, MessageBinary/binary>>
	end,
	case gen_tcp:send(Socket, Frame) of
		ok ->
			ok = io:format("Message sent~n");
		{error, Reason} ->
			ok = io:format("Error trying to send message: ~p~n", [Reason]),
			ok = io:format("Exiting~n"),
			close_socket_and_exit()
	end.

send_close(Code) ->
	ok = io:format("Sending websocket close~n"),
	[{accept_socket, AcceptSocket}] = context:get(accept_socket),
	CloseMessage = <<1:1/unsigned-integer, 0:3/unsigned-integer, 16#8:4/unsigned-integer, 0:1/unsigned-integer, 2:7/unsigned-integer, Code:16/big-unsigned-integer>>,
	gen_tcp:send(AcceptSocket, CloseMessage).

shell_command(Command) ->
	[{line_key, LineKey}] = context:get(line_key),
	{atomic, {ok, ShellCommand}} = mnesia:sync_transaction(fun mimic_interface:message/1, [{shell_command, LineKey, Command}]),
	send_websockets_message(ShellCommand).

update_accept() ->
	% Update the session key
	[{key, Key}] = context:get(key),
	SessionString = string:concat(Key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"),
	BinarySessionString = list_to_binary(SessionString),
	% crypto:hash(sha, BinarySessionString) does NOT work wit version R15B01 (site)
	EncryptedSessionString = crypto:hash(sha, BinarySessionString),
	% EncryptedSessionString = crypto:sha(BinarySessionString),
	Accept = binary_to_list(base64:encode(EncryptedSessionString)),
	context:set({accept, Accept}),
	ok.

mask_toggle(MaskingKey, Data) ->
	% Mask/Unmask data
	list_to_binary(rmask(MaskingKey, Data)).

rmask(_,<<>>) ->
	% XOR the data with the masking key
	[<<>>];

rmask(MaskBin = <<Mask:4/integer-unit:8>>,
	<<Data:4/integer-unit:8, Rest/binary>>) ->
	Masked = Mask bxor Data,
	MaskedRest = rmask(MaskBin, Rest),
	[<<Masked:4/integer-unit:8>> | MaskedRest ];

rmask(<<Mask:3/integer-unit:8, _Rest/binary>>, <<Data:3/integer-unit:8>>) ->
	Masked = Mask bxor Data,
	[<<Masked:3/integer-unit:8>>];

rmask(<<Mask:2/integer-unit:8, _Rest/binary>>, <<Data:2/integer-unit:8>>) ->
	Masked = Mask bxor Data,
	[<<Masked:2/integer-unit:8>>];

rmask(<<Mask:1/integer-unit:8, _Rest/binary>>, <<Data:1/integer-unit:8>>) ->
	Masked = Mask bxor Data,
	[<<Masked:1/integer-unit:8>>].

decode_xml_header(Message) ->
	case string:str(Message, "<?xml ") of
		1 ->
			[{xml_version, XmlVersion}] = context:get(xml_version),
			case get_xml_attribute("version", Message) of
				XmlVersion ->
					[{document_encoding, DocumentEncoding}] = context:get(document_encoding),
					case get_xml_attribute("encoding", Message) of
						DocumentEncoding ->
							case string:str(Message, ">") of
								0 ->
									ok = io:format("Missing '>' in XML header~n"),
									false;
								Index ->
									ok = io:format("Valid XML header~n"),
									{true, string:substr(Message, Index + 1)}
							end;
						_ ->
							ok = io:format("Invalid encoding~n"),
							false
					end;
				_ ->
					ok = io:format("Invalid XML version~n"),
					false
			end;
		_ ->
			ok = io:format("Unable to parse XML header~n"),
			false
	end.
    
get_xml_attribute(Name, Message) ->
	case string:str(Message, Name) of
		0 ->
			ok = io:format("Attribute does not exist: ~p~n", Name),
			"";
		Index ->
			Rest = string:substr(Message, Index),
			[_, Value | _] = string:tokens(Rest, "\""),
			Value
	end.