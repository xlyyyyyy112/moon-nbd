///|
async test "copy exports complete data and refuses nonempty output" {
  let dir = @fs.tmpdir(prefix="moon-nbd-copy")
  let path = "\{dir}/copy.raw"
  let file = @fs.open(path[:], mode=ReadWrite, create_mode=CreateNew)
  let disk = MemoryExport::new(1024)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp)
      }
      let client = Client::connect(
        "127.0.0.1",
        listener.addr.port(),
        b"",
        structured=true,
      )
      defer client.close()
      client.write_at(10UL, b"backup")
      assert_eq(client.copy_to_file(file), 1024UL)
      assert_eq(file.read_exactly_at(6, position=10L), b"backup")
      try client.copy_to_file(file) catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("nonempty output was accepted")
      }
      client.disconnect()
    }
  })
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}

///|
async test "sparse copy preserves unknown allocation extents" {
  let dir = @fs.tmpdir(prefix="moon-nbd-sparse")
  let path = "\{dir}/copy.raw"
  let file = @fs.open(path[:], mode=ReadWrite, create_mode=CreateNew)
  let disk = MemoryExport::new(4096)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp)
      }
      let client = Client::connect(
        "127.0.0.1",
        listener.addr.port(),
        b"",
        structured=true,
        allocation=true,
      )
      defer client.close()
      client.write_at(1024UL, b"sparse export")
      let stats = client.copy_sparse_to_file(file)
      assert_eq(stats.logical_bytes, 4096UL)
      // MemoryExport intentionally reports allocation as unknown, so the
      // conservative path copies all bytes instead of guessing that holes zero.
      assert_eq(stats.data_bytes, 4096UL)
      assert_eq(stats.zero_bytes, 0UL)
      assert_eq(stats.extents, 1)
      assert_eq(file.size(), 4096L)
      assert_eq(file.read_exactly_at(13, position=1024L), b"sparse export")
      client.disconnect()
    }
  })
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}

///|
async test "sparse copy requires negotiated allocation metadata" {
  let dir = @fs.tmpdir(prefix="moon-nbd-sparse-meta")
  let path = "\{dir}/copy.raw"
  let file = @fs.open(path[:], mode=ReadWrite, create_mode=CreateNew)
  let disk = MemoryExport::new(512)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp)
      }
      let client = Client::connect("127.0.0.1", listener.addr.port(), b"")
      defer client.close()
      try client.copy_sparse_to_file(file) catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("sparse copy accepted an unnegotiated context")
      }
      assert_eq(file.size(), 0L)
      client.disconnect()
    }
  })
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}
