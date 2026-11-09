///|
async fn read_option(tcp : @socket.Tcp, expected : UInt32) -> Bytes {
  let header = tcp.read_exactly(16)
  assert_eq(get64(header, 0), 0x49484156454f5054UL)
  assert_eq(get32(header, 8), expected)
  let size = get32(header, 12)
  assert_true(size <= 65536U)
  tcp.read_exactly(size.reinterpret_as_int())
}

///|
async test "allocation scan follows partial block status replies" {
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
        tcp.write(Bytes::from_array(greeting))
        ignore(tcp.read_exactly(4))
        ignore(read_option(tcp, 8U))
        option_reply(tcp, 8U, 1U, b"")
        ignore(read_option(tcp, 10U))
        let context : Array[Byte] = []
        put32(context, 11U)
        for b in b"base:allocation" {
          context.push(b)
        }
        option_reply(tcp, 10U, 4U, Bytes::from_array(context))
        option_reply(tcp, 10U, 1U, b"")
        ignore(read_option(tcp, 7U))
        let info : Array[Byte] = []
        put16(info, 0U)
        put64(info, 16UL)
        put16(info, 1U)
        option_reply(tcp, 7U, 3U, Bytes::from_array(info))
        option_reply(tcp, 7U, 1U, b"")
        for i in 0..<2 {
          let req = tcp.read_exactly(28)
          assert_eq(get16(req, 6), 7U)
          assert_eq(get64(req, 16), (i * 2).to_uint64())
          let payload : Array[Byte] = []
          put32(payload, 11U)
          put32(payload, 2U)
          put32(payload, if i == 0 { 2U } else { 0U })
          structured_chunk(
            tcp,
            5U,
            1U,
            get64(req, 8),
            Bytes::from_array(payload),
          )
        }
      }
      let client = Client::connect(
        "127.0.0.1",
        server.addr.port(),
        b"",
        structured=true,
        allocation=true,
      )
      defer client.close()
      let extents = client.scan_allocation(0UL, 4UL)
      assert_eq(extents.length(), 2)
      assert_true(extents[0].is_zero())
      assert_eq(extents[1].offset, 2UL)
      assert_false(extents[1].is_zero())
    }
  })
}

///|
test "metadata queries validate length and select requested context" {
  let data : Array[Byte] = []
  put32(data, 0U)
  put32(data, 1U)
  put32(data, 15U)
  for b in b"base:allocation" {
    data.push(b)
  }
  let disk = ExportBackend::Memory(MemoryExport::new(1))
  assert_eq(parse_allocation_query(Bytes::from_array(data), disk), Ok(true))
  data.pop() |> ignore
  assert_true(parse_allocation_query(Bytes::from_array(data), disk) is Err(_))
}
