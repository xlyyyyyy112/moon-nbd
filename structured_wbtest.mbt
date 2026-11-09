///|
async fn structured_chunk(
  tcp : @socket.Tcp,
  kind : UInt32,
  flags : UInt32,
  cookie : UInt64,
  payload : Bytes,
) -> Unit {
  let out : Array[Byte] = []
  put32(out, 0x668e33efU)
  put16(out, flags)
  put16(out, kind)
  put64(out, cookie)
  put32(out, payload.length().reinterpret_as_uint())
  for b in payload {
    out.push(b)
  }
  tcp.write(Bytes::from_array(out))
}

///|
async fn structured_test_peer(
  send : async (@socket.Tcp) -> Unit,
  check : async (@socket.Tcp) -> Unit,
) -> Unit {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        send(tcp)
      }
      let tcp = @socket.Tcp::connect_to_host(
        "127.0.0.1",
        port=listener.addr.port(),
      )
      defer tcp.close()
      check(tcp)
    }
  })
}

///|
async test "structured read reassembles out-of-order data and hole" {
  structured_test_peer(
    tcp => {
      let data : Array[Byte] = []
      put64(data, 102UL)
      data.push(b'c')
      data.push(b'd')
      structured_chunk(tcp, 1U, 0U, 42UL, Bytes::from_array(data))
      let hole : Array[Byte] = []
      put64(hole, 100UL)
      put32(hole, 2U)
      structured_chunk(tcp, 2U, 1U, 42UL, Bytes::from_array(hole))
    },
    tcp => {
      assert_eq(
        read_structured(tcp, tcp.read_exactly(16), 42UL, 100UL, 4),
        b"\x00\x00cd",
      )
    },
  )
}

///|
async test "structured read rejects overlapping chunks" {
  structured_test_peer(
    tcp => {
      let first : Array[Byte] = []
      put64(first, 0UL)
      first.push(b'a')
      first.push(b'b')
      structured_chunk(tcp, 1U, 0U, 1UL, Bytes::from_array(first))
      let second : Array[Byte] = []
      put64(second, 1UL)
      second.push(b'x')
      structured_chunk(tcp, 1U, 1U, 1UL, Bytes::from_array(second))
    },
    tcp => {
      try read_structured(tcp, tcp.read_exactly(16), 1UL, 0UL, 2) catch {
        Protocol(_) => ()
        e => raise e
      } noraise {
        _ => fail("overlap accepted")
      }
    },
  )
}

///|
async test "structured read rejects incomplete success" {
  structured_test_peer(tcp => structured_chunk(tcp, 0U, 1U, 3UL, b""), tcp => {
    try read_structured(tcp, tcp.read_exactly(16), 3UL, 0UL, 10) catch {
      Protocol(_) => ()
      e => raise e
    } noraise {
      _ => fail("incomplete read accepted")
    }
  })
}
