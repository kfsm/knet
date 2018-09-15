# Networking behaviour

The *do-notation* implements the **Given**/**When**/**Then** and connects cause-and-effect to the networking concept of input/process/output.

**Given** identify the communication context. The **url** is mandatory element that defines a target and communication protocol.  

```erlang
-spec Given() -> datum:m_state(_).
```

**When** defines key actions for the interaction with remote host. It specify the protocol parameters, such headers or socket options.

```erlang
-spec When() -> datum:m_state(_).
```

**Then** executes and interactions and observes output of remote hosts, validate its correctness and output the result. The implementation is responsible to transform a socket communication into appropriate typed-stream.

```erlang
-spec Then() -> datum:m_state(_).
```

## Network protocols

**L4/L6 connection-oriented protocols.**

*Given* and *When* setups the communication context, *Then* abstracts an incoming packets as byte stream, allowing to implement any arbitrary effect part.

```erlang
request() ->
   [kscript ||
      _ /= 'Given'(),
      _ /= url("tcp://127.0.0.1:3456"),
      
      _ /= 'When'(),
      _ /= send(<<"HELLO\r\n">>),
      
      _ /= 'Then'(),
      <<"OLLEH\r\n">> /= recv(7),
      
      _ /= send(<<"THERE\r\n">>) 
      <<"EREHT\r\n">> /= recv(7)
   ].
```

**L4 connection-less protocol.**

Same as above.

**L7 request/response protocols.**

*Given* and *When* setups the communication context, *Then* abstracts an incoming response into appropriate data type.

```erlang
request() ->
   [kscript ||
      _ /= 'Given'(),
      _ /= url("http://httpbin.org/ip"),
      
      _ /= 'When'(),
      _ /= header("Accept", "application/json"),
      
      _ /= 'Then'(),
      %% return json parsed as map
      %% #{<<"origin">> := <<"192.168.0.1">>} 
   ].
```

**L7 streaming protocols.**

*Given* and *When* setups the communication context, *Then* abstracts an incoming packets as typed stream, allowing to implement any arbitrary effect part.

```erlang
request() ->
   [kscript ||
      _ /= 'Given'(),
      _ /= url("ws://127.0.0.1:80/websocket"),
      
      _ /= 'When'(),
      _ /= header("Accept", "application/json"),
      
      _ /= 'Then'(),
      %% return a stream similar to L4
   ].
```
