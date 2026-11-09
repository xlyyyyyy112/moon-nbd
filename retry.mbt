///|
/// Reusable immutable connection settings for read-only retry workflows.
pub(all) struct ClientConfig {
  host : String
  port : Int32
  export_name : Bytes
  structured : Bool
  allocation : Bool
  timeout_ms : Int32
}

///|
pub fn ClientConfig::new(
  host : String,
  port : Int32,
  export_name : Bytes,
  structured~ : Bool = false,
  allocation~ : Bool = false,
  timeout_ms~ : Int32 = 30000,
) -> ClientConfig raise {
  if port <= 0 ||
    port > 65535 ||
    export_name.length() > 4096 ||
    (allocation && !structured) ||
    timeout_ms <= 0 {
    raise InvalidArgument("invalid client connection settings")
  }
  { host, port, export_name, structured, allocation, timeout_ms, }
}

///|
pub async fn ClientConfig::connect(self : ClientConfig) -> Client {
  Client::connect(
    self.host,
    self.port,
    self.export_name,
    structured=self.structured,
    allocation=self.allocation,
    timeout_ms=self.timeout_ms,
  )
}

///|
fn retryable_read_error(error : Error) -> Bool {
  match error {
    InvalidArgument(_) | Server(_) | Protocol(_) => false
    _ => true
  }
}

///|
/// Read once or reconnect and retry after a transport failure.
///
/// This function is safe only for a stable export: a reconnect can observe a
/// different version of mutable storage. It never retries writes, flushes,
/// trims, or write-zeroes because their outcome can be unknown after a lost
/// connection. `retries` counts additional attempts after the first one.
pub async fn ClientConfig::read_at_retry(
  self : ClientConfig,
  offset : UInt64,
  length : Int32,
  retries~ : Int32 = 1,
) -> Bytes {
  if retries < 0 || retries > 16 {
    raise InvalidArgument("retry count must be between 0 and 16")
  }
  let mut attempt = 0
  while true {
    let client = self.connect()
    let result = try {
      let data = client.read_at(offset, length)
      client.disconnect()
      Ok(data)
    } catch {
      error => {
        client.close()
        Err(error)
      }
    }
    match result {
      Ok(data) => return data
      Err(error) => {
        if attempt >= retries || !retryable_read_error(error) {
          raise error
        }
        attempt += 1
      }
    }
  } nobreak {
    fail("unreachable retry loop exit")
  }
}
