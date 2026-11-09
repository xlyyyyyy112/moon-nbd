///|
test "network integers preserve full width" {
  let bytes : Array[Byte] = []
  put16(bytes, 0xabcdU)
  put32(bytes, 0x12345678U)
  put64(bytes, 0x123456789abcdef0UL)
  let data = Bytes::from_array(bytes)
  assert_eq(get16(data, 0), 0xabcdU)
  assert_eq(get32(data, 2), 0x12345678U)
  assert_eq(get64(data, 6), 0x123456789abcdef0UL)
}

///|
async test "client reads and writes against a fragmented fake server" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = server.accept()
        defer tcp.close()
        let greeting : Array[Byte] = []
        put64(greeting, 0x4e42444d41474943UL)
        put64(greeting, 0x49484156454f5054UL)
        put16(greeting, 3U)
        for b in greeting {
          tcp.write(Bytes::from_array([b]))
        }
        let setup = tcp.read_exactly(28)
        assert_eq(get32(setup, 0), 3U)
        assert_eq(get32(setup, 12), 7U)
        assert_eq(get32(setup, 16), 8U)
        assert_eq(get32(setup, 20), 0U)
        let info : Array[Byte] = []
        put16(info, 0U)
        put64(info, 1024UL)
        put16(info, 5U)
        option_reply(tcp, 7U, 3U, Bytes::from_array(info))
        option_reply(tcp, 7U, 1U, b"")
        for command in [0U, 1U, 3U] {
          let req = tcp.read_exactly(28)
          assert_eq(get32(req, 0), 0x25609513U)
          assert_eq(get16(req, 4), 0U)
          assert_eq(get16(req, 6), command)
          if command == 1U {
            assert_eq(tcp.read_exactly(3), b"abc")
          }
          let reply : Array[Byte] = []
          put32(reply, 0x67446698U)
          put32(reply, 0U)
          put64(reply, get64(req, 8))
          tcp.write(Bytes::from_array(reply))
          if command == 0U {
            tcp.write(b"xyz")
          }
        }
      }
      let client = Client::connect("127.0.0.1", server.addr.port(), b"")
      defer client.close()
      assert_eq(client.size, 1024UL)
      assert_eq(client.read_at(7UL, 3), b"xyz")
      try client.read_at(1023UL, 2) catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("out-of-range read was accepted")
      }
      client.write_at(7UL, b"abc")
      client.flush()
    }
  })
}

///|
async test "invalid handshake is rejected" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = server.accept()
        defer tcp.close()
        tcp.write(Bytes::make(18, b'\x00'))
      }
      try Client::connect("127.0.0.1", server.addr.port(), b"") catch {
        Protocol(_) => ()
        e => raise e
      } noraise {
        client => {
          client.close()
          fail("invalid handshake was accepted")
        }
      }
    }
  })
}
