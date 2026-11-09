///|
async test "compare coalesces differences across read chunks and enforces limits" {
  let left_disk = MemoryExport::new(1048580)
  let right_disk = MemoryExport::new(1048580)
  right_disk.data[2] = b'a'
  right_disk.data[1048575] = b'b'
  right_disk.data[1048576] = b'c'
  let left_server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let right_server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer left_server.close()
  defer right_server.close()
  @async.with_timeout(10000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = left_server.accept()
        defer tcp.close()
        left_disk.serve_connection(tcp)
      }
      group.spawn_bg() <| () => {
        let (tcp, _) = right_server.accept()
        defer tcp.close()
        right_disk.serve_connection(tcp)
      }
      let left = Client::connect("127.0.0.1", left_server.addr.port(), b"")
      defer left.close()
      let right = Client::connect("127.0.0.1", right_server.addr.port(), b"")
      defer right.close()
      let diffs = compare_ranges(left, right, 0UL, 1048580UL)
      assert_eq(diffs.length(), 2)
      assert_eq(diffs[0].offset, 2UL)
      assert_eq(diffs[0].length, 1UL)
      assert_eq(diffs[1].offset, 1048575UL)
      assert_eq(diffs[1].length, 2UL)
      try compare_ranges(left, right, 0UL, 1048580UL, max_ranges=1) catch {
        LimitExceeded(_) => ()
        e => raise e
      } noraise {
        _ => fail("range limit was ignored")
      }
      left.disconnect()
      right.disconnect()
    }
  })
}
