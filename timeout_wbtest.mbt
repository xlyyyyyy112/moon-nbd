///|
async test "handshake timeout closes the connection" {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        @async.sleep(200)
      }
      try
        Client::connect("127.0.0.1", listener.addr.port(), b"", timeout_ms=50)
      catch {
        @async.TimeoutError => ()
        e => raise e
      } noraise {
        client => {
          client.close()
          fail("stalled handshake accepted")
        }
      }
    }
  })
}

///|
async test "write timeout reports unknown outcome and closes session" {
  negotiation_peer(
    tcp => {
      send_test_export(tcp)
      option_reply(tcp, 7U, 1U, b"")
      let request = tcp.read_exactly(28)
      assert_eq(get16(request, 6), 1U)
      assert_eq(tcp.read_exactly(1), b"x")
      @async.sleep(300)
    },
    port => {
      let client = Client::connect("127.0.0.1", port, b"", timeout_ms=100)
      defer client.close()
      try client.write_at(0UL, b"x") catch {
        OutcomeUnknown(_) => ()
        e => raise e
      } noraise {
        _ => fail("lost write reply was accepted")
      }
      try client.read_at(0UL, 1) catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("broken connection was reused")
      }
    },
  )
}

///|
async test "wrong write cookie reports unknown outcome" {
  negotiation_peer(
    tcp => {
      send_test_export(tcp)
      option_reply(tcp, 7U, 1U, b"")
      let req = tcp.read_exactly(28)
      ignore(tcp.read_exactly(1))
      let response : Array[Byte] = []
      put32(response, 0x67446698U)
      put32(response, 0U)
      put64(response, get64(req, 8) + 1UL)
      tcp.write(Bytes::from_array(response))
    },
    port => {
      let client = Client::connect("127.0.0.1", port, b"")
      defer client.close()
      try client.write_at(0UL, b"x") catch {
        OutcomeUnknown(_) => ()
        e => raise e
      } noraise {
        _ => fail("wrong cookie accepted")
      }
    },
  )
}

///|
async test "one read timeout covers both header and payload" {
  negotiation_peer(
    tcp => {
      send_test_export(tcp)
      option_reply(tcp, 7U, 1U, b"")
      let request = tcp.read_exactly(28)
      @async.sleep(250)
      let reply : Array[Byte] = []
      put32(reply, 0x67446698U)
      put32(reply, 0U)
      put64(reply, get64(request, 8))
      tcp.write(Bytes::from_array(reply))
      @async.sleep(250)
      tcp.write(b"x") catch {
        _ => ()
      }
    },
    port => {
      let client = Client::connect("127.0.0.1", port, b"", timeout_ms=400)
      defer client.close()
      try client.read_at(0UL, 1) catch {
        @async.TimeoutError => ()
        e => raise e
      } noraise {
        _ => fail("read exceeded its overall request timeout")
      }
    },
  )
}
