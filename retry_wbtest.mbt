///|
async test "read retry reconnects after a transport failure" {
  let disk = MemoryExport::new(1024)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        // Complete negotiation for the first connection, then drop its first
        // read request. A second connection is served normally.
        let (first, _) = listener.accept()
        let greeting : Array[Byte] = []
        put64(greeting, 0x4e42444d41474943UL)
        put64(greeting, 0x49484156454f5054UL)
        put16(greeting, 3U)
        first.write(Bytes::from_array(greeting))
        ignore(first.read_exactly(4))
        let option = first.read_exactly(24)
        assert_eq(get32(option, 8), 7U)
        let info : Array[Byte] = []
        put16(info, 0U)
        put64(info, 1024UL)
        put16(info, 1U)
        option_reply(first, 7U, 3U, Bytes::from_array(info))
        option_reply(first, 7U, 1U, b"")
        ignore(first.read_exactly(28))
        first.close()
        let (second, _) = listener.accept()
        defer second.close()
        disk.serve_connection(second)
      }
      let config = ClientConfig::new("127.0.0.1", listener.addr.port(), b"")
      assert_eq(
        config.read_at_retry(0UL, 16, retries=1),
        Bytes::make(16, b'\x00'),
      )
    }
  })
}

///|
test "client configuration rejects unsafe retry settings" {
  try ClientConfig::new("127.0.0.1", 1, b"", allocation=true) catch {
    InvalidArgument(_) => ()
    e => raise e
  } noraise {
    _ => fail("allocation without structured replies was accepted")
  }
}
