///|
async test "file export writes and flushes existing file without truncation" {
  let dir = @fs.tmpdir(prefix="moon-nbd-test")
  let path = "\{dir}/disk.raw"
  @fs.write_file(path[:], "0123456789", create_mode=CreateNew)
  let disk = FileExport::open(path, read_only=false)
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
      assert_eq(client.size, 10UL)
      client.write_at(3UL, b"abc")
      client.flush()
      assert_eq(client.read_at(0UL, 10), b"012abc6789")
      client.disconnect()
    }
  })
  disk.close()
  let file = @fs.open(path[:], mode=ReadOnly)
  assert_eq(file.read_exactly_at(10, position=0L), b"012abc6789")
  file.close()
  @fs.remove(path[:])
  @fs.rmdir(dir[:])
}

///|
async test "file export rejects directory" {
  let dir = @fs.tmpdir(prefix="moon-nbd-directory")
  try FileExport::open(dir) catch {
    InvalidArgument(_) => ()
    e => raise e
  } noraise {
    disk => {
      disk.close()
      fail("directory accepted")
    }
  }
  @fs.rmdir(dir[:])
}
