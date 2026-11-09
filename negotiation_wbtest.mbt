///|
async fn negotiation_peer(
  respond : async (@socket.Tcp) -> Unit,
  client_action : async (Int32) -> Unit,
) -> Unit {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        let greeting : Array[Byte] = []
        put64(greeting, 0x4e42444d41474943UL)
        put64(greeting, 0x49484156454f5054UL)
        put16(greeting, 3U)
        tcp.write(Bytes::from_array(greeting))
        let request = tcp.read_exactly(28)
        assert_eq(get32(request, 12), 7U)
        respond(tcp)
      }
      client_action(listener.addr.port())
    }
  })
}

///|
async fn send_test_export(tcp : @socket.Tcp) -> Unit {
  let info : Array[Byte] = []
  put16(info, 0U)
  put64(info, 65536UL)
  put16(info, 1U)
  option_reply(tcp, 7U, 3U, Bytes::from_array(info))
}

///|
async test "GO block constraints reject misaligned requests before sending" {
  negotiation_peer(
    tcp => {
      send_test_export(tcp)
      let block : Array[Byte] = []
      put16(block, 3U)
      put32(block, 512U)
      put32(block, 4096U)
      put32(block, 32768U)
      option_reply(tcp, 7U, 3U, Bytes::from_array(block))
      option_reply(tcp, 7U, 1U, b"")
    },
    port => {
      let client = Client::connect("127.0.0.1", port, b"")
      defer client.close()
      assert_eq(client.min_block, 512U)
      assert_eq(client.max_block, 32768U)
      try client.read_at(1UL, 512) catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("unaligned request accepted")
      }
    },
  )
}

///|
async test "GO unsupported falls back to export name" {
  negotiation_peer(
    tcp => {
      option_reply(tcp, 7U, 0x80000001U, b"")
      let fallback = tcp.read_exactly(16)
      assert_eq(get32(fallback, 8), 1U)
      assert_eq(get32(fallback, 12), 0U)
      let info : Array[Byte] = []
      put64(info, 4096UL)
      put16(info, 1U)
      tcp.write(Bytes::from_array(info))
    },
    port => {
      let client = Client::connect("127.0.0.1", port, b"")
      defer client.close()
      assert_eq(client.size, 4096UL)
      assert_eq(client.min_block, 1U)
    },
  )
}

///|
async test "GO rejects invalid advertised block sizes" {
  negotiation_peer(
    tcp => {
      send_test_export(tcp)
      let block : Array[Byte] = []
      put16(block, 3U)
      put32(block, 3U)
      put32(block, 4096U)
      put32(block, 32768U)
      option_reply(tcp, 7U, 3U, Bytes::from_array(block))
    },
    port => {
      try Client::connect("127.0.0.1", port, b"") catch {
        Protocol(_) => ()
        e => raise e
      } noraise {
        client => {
          client.close()
          fail("invalid block size accepted")
        }
      }
    },
  )
}

///|
async test "GO accepts an unlimited maximum and rounds odd maxima down" {
  for advertised_max in [0xffffffffU, 32769U] {
    negotiation_peer(
      tcp => {
        send_test_export(tcp)
        let block : Array[Byte] = []
        put16(block, 3U)
        put32(block, 512U)
        put32(block, 4096U)
        put32(block, advertised_max)
        option_reply(tcp, 7U, 3U, Bytes::from_array(block))
        option_reply(tcp, 7U, 1U, b"")
      },
      port => {
        let client = Client::connect("127.0.0.1", port, b"")
        defer client.close()
        assert_eq(client.min_block, 512U)
        assert_eq(
          client.max_block,
          if advertised_max == 0xffffffffU {
            16777216U
          } else {
            32768U
          },
        )
      },
    )
  }
}
