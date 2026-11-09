///|
async test "memory export interoperates with client and preserves bytes" {
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
      assert_eq(client.size, 4096UL)
      client.write_at(200UL, b"test bytes")
      assert_eq(client.read_at(200UL, 10), b"test bytes")
      client.cache(0UL, 512)
      let extents = client.block_status(0UL, 512)
      assert_eq(extents.length(), 1)
      assert_eq(extents[0].offset, 0UL)
      assert_eq(extents[0].length, 512U)
      let all = client.scan_allocation(0UL, 4096UL)
      assert_eq(all.length(), 1)
      assert_eq(all[0].length, 4096U)
      client.write_zeroes(200UL, 4, no_hole=true)
      assert_eq(client.read_at(200UL, 10), b"\x00\x00\x00\x00 bytes")
      client.write_at(200UL, b"test bytes")
      client.trim(200UL, 4)
      assert_eq(client.read_at(200UL, 10), b"\x00\x00\x00\x00 bytes")
      client.write_at(200UL, b"test bytes")
      client.disconnect()
    }
  })
  assert_eq(disk.snapshot()[200:210].to_owned(), b"test bytes")
}

///|
async test "read only memory export rejects writes before sending" {
  let disk = MemoryExport::new(32, read_only=true)
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
      try client.write_at(0UL, b"x") catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("read-only write succeeded")
      }
      assert_eq(client.read_at(0UL, 1), b"\x00")
      client.disconnect()
    }
  })
}

///|
async test "client lists default export and aborts negotiation" {
  let disk = MemoryExport::new(64)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp)
      }
      let entries = list_exports("127.0.0.1", listener.addr.port())
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].name, b"")
    }
  })
}

///|
async test "client inspects export without entering transmission mode" {
  let disk = MemoryExport::new(1536)
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = listener.accept()
        defer tcp.close()
        disk.serve_connection(tcp)
      }
      let info = inspect_export("127.0.0.1", listener.addr.port(), b"")
      assert_eq(info.size, 1536UL)
      assert_true((info.flags & 1U) != 0U)
    }
  })
}

///|
async test "named export lists and accepts its own name" {
  let disk = MemoryExport::new(64, name=b"demo")
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        for _ in 0..<2 {
          let (tcp, _) = listener.accept()
          defer tcp.close()
          disk.serve_connection(tcp)
        }
      }
      let entries = list_exports("127.0.0.1", listener.addr.port())
      assert_eq(entries.length(), 1)
      assert_eq(entries[0].name, b"demo")
      let client = Client::connect(
        "127.0.0.1",
        listener.addr.port(),
        b"demo",
        structured=true,
        allocation=true,
      )
      defer client.close()
      assert_eq(client.read_at(0UL, 4), b"\x00\x00\x00\x00")
      assert_eq(client.block_status(0UL, 4).length(), 1)
      client.disconnect()
    }
  })
}

///|
test "export option distinguishes malformed and unknown names" {
  let disk = ExportBackend::Memory(MemoryExport::new(8, name=b"demo"))
  let unknown : Array[Byte] = []
  put32(unknown, 3U)
  for b in b"bad" {
    unknown.push(b)
  }
  put16(unknown, 0U)
  assert_eq(
    validate_export_option(Bytes::from_array(unknown), disk),
    Some(0x80000006U),
  )
  assert_eq(validate_export_option(b"\x00", disk), Some(0x80000003U))
}
