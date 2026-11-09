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

///|
async test "range copy updates only requested bytes in an existing image" {
  let dir = @fs.tmpdir(prefix="moon-nbd-range-copy")
  let path = "\{dir}/target.raw"
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
      // Establish the logical target size and seed a byte outside the update.
      file.write_at(b"K", position=1023L)
      let client = Client::connect("127.0.0.1", listener.addr.port(), b"")
      defer client.close()
      client.write_at(512UL, b"incremental")
      let invalid_plan = RangeSet::new([
        { offset: 512UL, length: 11UL, },
        { offset: 2048UL, length: 1UL, },
      ])
      try client.copy_ranges_to_file(file, invalid_plan) catch {
        InvalidArgument(_) => ()
        e => raise e
      } noraise {
        _ => fail("out-of-range plan was accepted")
      }
      assert_eq(
        file.read_exactly_at(11, position=512L),
        Bytes::make(11, b'\x00'),
      )
      let ranges = client.range_set([{ offset: 512UL, length: 11UL, }])
      let stats = client.copy_ranges_to_file(file, ranges)
      assert_eq(stats.ranges, 1)
      assert_eq(stats.bytes, 11UL)
      assert_eq(file.read_exactly_at(11, position=512L), b"incremental")
      assert_eq(file.read_exactly_at(1, position=1023L), b"K")
      client.disconnect()
    }
  })
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}

///|
test "byte differences are expanded and merged at source block alignment" {
  let aligned = aligned_differences(
    [{ offset: 3UL, length: 1UL, }, { offset: 510UL, length: 4UL, }],
    512UL,
  )
  let plan = RangeSet::new(aligned, alignment=512UL)
  assert_eq(plan.ranges().length(), 1)
  assert_eq(plan.ranges()[0].offset, 0UL)
  assert_eq(plan.ranges()[0].length, 1024UL)
}

///|
async test "file import and byte comparison round trip through a remote export" {
  let dir = @fs.tmpdir(prefix="moon-nbd-file-transfer")
  let path = "\{dir}/image.raw"
  let file = @fs.open(path[:], mode=ReadWrite, create_mode=CreateNew)
  let source = Array::make(1024, b'\x00')
  for i in 0..<1024 {
    source[i] = (i % 251).to_byte()
  }
  file.write_at(Bytes::from_array(source), position=0L)
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
      let client = Client::connect("127.0.0.1", listener.addr.port(), b"")
      defer client.close()
      assert_eq(client.read_bytes(5UL, 13), Bytes::from_array(source[5:18]))
      assert_eq(client.read_bytes(1024UL, 0), b"")
      assert_eq(client.copy_from_file(file), 1024UL)
      let initial = client.compare_file(file, 0UL, 1024UL)
      assert_eq(initial.bytes_checked, 1024UL)
      assert_eq(initial.differences.length(), 0)

      file.write_at(b"X", position=513L)
      let changed = client.compare_file(file, 500UL, 24UL)
      assert_eq(changed.differences.length(), 1)
      assert_eq(changed.differences[0].offset, 513UL)
      assert_eq(changed.differences[0].length, 1UL)
      assert_eq(client.copy_differences_from_file(file, 500UL, 24UL), 1UL)
      assert_eq(disk.snapshot(), Bytes::from_array(source))
      client.disconnect()
    }
  })
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}

///|
async test "incremental copy handles a one-byte difference on a 512-byte client" {
  let dir = @fs.tmpdir(prefix="moon-nbd-difference-copy")
  let path = "\{dir}/baseline.raw"
  let file = @fs.open(path[:], mode=ReadWrite, create_mode=CreateNew)
  let source_disk = MemoryExport::new(1024)
  let baseline_disk = MemoryExport::new(1024)
  source_disk.data[3] = b'X'
  let source_server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let baseline_server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer source_server.close()
  defer baseline_server.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = source_server.accept()
        defer tcp.close()
        source_disk.serve_connection(tcp)
      }
      group.spawn_bg() <| () => {
        let (tcp, _) = baseline_server.accept()
        defer tcp.close()
        baseline_disk.serve_connection(tcp)
      }
      file.write_at(Bytes::make(1024, b'\x00'), position=0L)
      let raw = Client::connect("127.0.0.1", source_server.addr.port(), b"")
      // A client may voluntarily impose a stricter alignment than the server.
      let source = { ..raw, min_block: 512U, }
      defer source.close()
      let baseline = Client::connect(
        "127.0.0.1",
        baseline_server.addr.port(),
        b"",
      )
      defer baseline.close()
      let stats = copy_differences_to_file(source, baseline, file, 0UL, 1024UL)
      assert_eq(stats.ranges, 1)
      assert_eq(stats.bytes, 512UL)
      assert_eq(file.read_exactly_at(1024, position=0L), source_disk.snapshot())
      source.disconnect()
      baseline.disconnect()
    }
  })
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}
