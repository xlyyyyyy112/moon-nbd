///|
async fn main {
  let client = @nbd.Client::connect(
    "127.0.0.1",
    11089,
    b"",
    structured=true,
    allocation=true,
  )
  defer client.close()
  client.write_at(7UL, b"moon-nbd")
  client.flush()
  let data = client.read_at(7UL, 8)
  println("export_size=\{client.size}, bytes_read=\{data.length()}")
  assert_eq(data, b"moon-nbd")
  let extents = client.block_status(0UL, 512)
  assert_true(extents.length() > 0)
  let all = client.scan_allocation(0UL, 1048576UL)
  assert_true(all.length() > 0)
  client.disconnect()
}
