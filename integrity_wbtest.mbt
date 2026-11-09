///|
test "crc32 uses the standard IEEE value" {
  assert_eq(crc32(b"123456789"), 0xcbf43926U)
  assert_eq(crc32(b""), 0U)
}

///|
test "integrity manifest encoding rejects corrupt framing" {
  let manifest : IntegrityManifest = {
    export_size: 1024UL,
    chunk_size: 512U,
    checksums: [1U, 2U],
  }
  let encoded = manifest.encode()
  assert_eq(IntegrityManifest::decode(encoded).checksums, [1U, 2U])
  try IntegrityManifest::decode(encoded[0:12].to_owned()) catch {
    InvalidArgument(_) => ()
    e => raise e
  } noraise {
    _ => fail("truncated manifest was accepted")
  }
}

///|
async test "client manifest detects exactly the changed block" {
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
      client.write_at(512UL, b"manifest mutation")
      let manifest = client.create_integrity_manifest(512)
      assert_eq(manifest.checksums.length(), 2)
      assert_eq(client.verify_integrity_manifest(manifest).length(), 0)
      client.write_at(512UL, b"X")
      let mismatch = client.verify_integrity_manifest(manifest)
      assert_eq(mismatch.length(), 1)
      assert_eq(mismatch[0].offset, 512UL)
      assert_eq(mismatch[0].length, 512U)
      client.disconnect()
    }
  })
}
