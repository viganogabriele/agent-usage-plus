# Packaged Omarchy RPC reader before the compatibility fix. Keep the source
# shape here so the patch regression runs on CI without an Omarchy install.
def rpc_request(proc, request_id, method, params=None, timeout=8):
  payload = {"id": request_id, "method": method, "params": params or {}}
  proc.stdin.write(json.dumps(payload) + "\n")
  proc.stdin.flush()
  deadline = time.time() + timeout
  while time.time() < deadline:
    ready, _, _ = select.select([proc.stdout], [], [], 0.25)
    if not ready:
      continue
    line = proc.stdout.readline()
    if not line:
      break
    try:
      message = json.loads(line)
    except Exception:
      continue
    if message.get("id") == request_id:
      return message
  raise TimeoutError(method)
