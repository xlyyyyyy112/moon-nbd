///|
async test "cached client records hits and invalidates modified blocks" {
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
      let cache = CachedClient::connect(
        "127.0.0.1",
        listener.addr.port(),
        b"",
        1024,
        line_size=512,
        structured=true,
      )
      defer cache.close()
      assert_eq(cache.size(), 4096UL)
      assert_eq(cache.line_size(), 512U)
      assert_eq(cache.read_at(0UL, 512), Bytes::make(512, b'\x00'))
      let first = cache.stats()
      assert_eq(first.hits, 0UL)
      assert_eq(first.misses, 1UL)
      assert_eq(first.entries, 1)
      ignore(cache.read_at(0UL, 512))
      let second = cache.stats()
      assert_eq(second.hits, 1UL)
      assert_eq(second.misses, 1UL)
      cache.write_at(0UL, b"changed")
      assert_eq(cache.stats().entries, 0)
      assert_eq(cache.read_at(0UL, 512)[0:7].to_owned(), b"changed")
      let third = cache.stats()
      assert_eq(third.misses, 2UL)
      cache.disconnect()
    }
  })
}

///|
async test "cached client evicts least recently used line within its budget" {
  let disk = MemoryExport::new(2048)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp)
      }
      let cache = CachedClient::connect(
        "127.0.0.1",
        listener.addr.port(),
        b"",
        1024,
        line_size=512,
      )
      defer cache.close()
      ignore(cache.read_at(0UL, 512))
      ignore(cache.read_at(512UL, 512))
      ignore(cache.read_at(0UL, 512))
      ignore(cache.read_at(1024UL, 512))
      let stats = cache.stats()
      assert_eq(stats.entries, 2)
      assert_eq(stats.hits, 1UL)
      assert_eq(stats.misses, 3UL)
      assert_eq(stats.evictions, 1UL)
      cache.disconnect()
    }
  })
}
