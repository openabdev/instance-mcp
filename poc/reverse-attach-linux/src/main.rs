// reverse-attach: makes a Linux node a lendable "hands" node for openab-pty
// reverse-attach. Single self-contained binary: a minimal HTTP/1.1 control
// server (POST /attach, GET /attachments) plus a WebSocket dialer that
// connects outbound to a runtime and serves an MCP tool surface.
//
// Synchronous, std threads only. Deps: serde_json + tungstenite (which
// re-exports `http`). Target: aarch64 Debian 13, Rust 1.98.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use tungstenite::http::Request;
use tungstenite::Message;

// ---------------------------------------------------------------------------
// Shared grant registry
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct GrantInfo {
    grant_id: String,
    session: String,
    profile: String,
    state: String,
}

type Registry = Arc<Mutex<HashMap<String, GrantInfo>>>;

static GRANT_COUNTER: AtomicU64 = AtomicU64::new(1);

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn new_grant_id() -> String {
    let n = GRANT_COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("grant-{}-{}", now_epoch_secs(), n)
}

fn set_state(registry: &Registry, grant_id: &str, state: &str) {
    if let Ok(mut map) = registry.lock() {
        if let Some(g) = map.get_mut(grant_id) {
            g.state = state.to_string();
        }
    }
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

fn valid_session(s: &str) -> bool {
    // ^[a-z0-9-]{1,32}$
    let len = s.len();
    if len < 1 || len > 32 {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn strip_trailing_slashes(s: &str) -> &str {
    s.trim_end_matches('/')
}

fn attach_url(runtime: &str, session: &str) -> String {
    format!("{}/tools/attach/{}", strip_trailing_slashes(runtime), session)
}

// ---------------------------------------------------------------------------
// Disposition state machine
// ---------------------------------------------------------------------------

enum Disposition {
    Stop(String),
    Redial,
}

fn disposition_close(code: u16) -> Disposition {
    match code {
        4001 => Disposition::Stop("grantExpired".to_string()),
        4002 => Disposition::Stop("replaced".to_string()),
        4004 => Disposition::Stop("sessionEnded".to_string()),
        4010 => Disposition::Stop("revoked".to_string()),
        _ => Disposition::Redial,
    }
}

fn disposition_handshake(status: u16) -> Disposition {
    match status {
        101 => Disposition::Redial,
        200..=299 => Disposition::Redial,
        429 => Disposition::Redial,
        500..=599 => Disposition::Redial,
        _ => Disposition::Stop(format!("handshakeRejected({status})")),
    }
}

// ---------------------------------------------------------------------------
// mint(): replicate the Swift runtimeMintRequest contract (http/ws only)
// ---------------------------------------------------------------------------

fn mint(
    runtime: &str,
    session: &str,
    admin_credential: &str,
    ttl_secs: u64,
) -> Result<(String, u64), String> {
    // Map scheme ws->http, wss->https. Only plain http (ws://) is supported.
    let http_base: String = if runtime.starts_with("wss://") {
        return Err(
            "https mint not supported in PoC; use ws:// runtime or pass a pre-minted secret"
                .to_string(),
        );
    } else if let Some(rest) = runtime.strip_prefix("ws://") {
        format!("http://{}", rest)
    } else {
        return Err(format!("unsupported runtime scheme for mint: {}", runtime));
    };

    let base = strip_trailing_slashes(&http_base).to_string();
    let url = format!("{}/admin/sessions/{}/tools-attach", base, session);

    // Parse http://host[:port]/path
    let after_scheme = url
        .strip_prefix("http://")
        .ok_or_else(|| "internal: expected http scheme".to_string())?;
    let (authority, path) = match after_scheme.find('/') {
        Some(idx) => (&after_scheme[..idx], &after_scheme[idx..]),
        None => (after_scheme, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) => (
            h.to_string(),
            p.parse::<u16>().map_err(|_| "bad port".to_string())?,
        ),
        None => (authority.to_string(), 80u16),
    };

    let body = json!({ "ttl_secs": ttl_secs }).to_string();
    let request = format!(
        "POST {path} HTTP/1.1\r\n\
         Host: {authority}\r\n\
         Authorization: Bearer {cred}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {len}\r\n\
         Connection: close\r\n\
         \r\n\
         {body}",
        path = path,
        authority = authority,
        cred = admin_credential,
        len = body.len(),
        body = body,
    );

    let addr = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| format!("resolve failed: {e}"))?
        .next()
        .ok_or_else(|| "no address resolved".to_string())?;

    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(10))
        .map_err(|e| format!("connect failed: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(15)))
        .ok();
    stream
        .write_all(request.as_bytes())
        .map_err(|e| format!("write failed: {e}"))?;

    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|e| format!("read failed: {e}"))?;
    let text = String::from_utf8_lossy(&raw).to_string();

    // Split headers / body on the first blank line.
    let sep = text
        .find("\r\n\r\n")
        .map(|i| (i, 4))
        .or_else(|| text.find("\n\n").map(|i| (i, 2)));
    let (head, resp_body) = match sep {
        Some((i, off)) => (&text[..i], &text[i + off..]),
        None => (text.as_str(), ""),
    };

    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|s| s.parse::<u16>().ok())
        .unwrap_or(0);

    if !(200..=299).contains(&status) {
        return Err(format!("mint HTTP {status}: {}", resp_body.trim()));
    }

    let v: Value = serde_json::from_str(resp_body.trim())
        .map_err(|e| format!("mint response parse error: {e}"))?;

    let secret = v
        .get("secret")
        .and_then(|s| s.as_str())
        .ok_or_else(|| "mint response missing secret".to_string())?
        .to_string();

    let expires_in = v
        .get("expires_in")
        .or_else(|| v.get("expiresIn"))
        .and_then(|e| e.as_u64())
        .unwrap_or(ttl_secs);

    Ok((secret, expires_in))
}

// ---------------------------------------------------------------------------
// WebSocket dial loop
// ---------------------------------------------------------------------------

fn dial_loop(
    runtime: String,
    session: String,
    secret: String,
    profile: String,
    deadline_epoch_secs: u64,
    registry: Registry,
    grant_id: String,
) {
    let mut backoff: u64 = 1;
    let cap: u64 = 30;

    loop {
        if now_epoch_secs() >= deadline_epoch_secs {
            break;
        }

        set_state(&registry, &grant_id, "dialing");
        let url = attach_url(&runtime, &session);

        // Build a WS handshake request with the Authorization header.
        let req = match build_ws_request(&url, &secret) {
            Ok(r) => r,
            Err(e) => {
                set_state(&registry, &grant_id, &format!("error({e})"));
                // treat as redial-able transient error
                if !sleep_until_backoff(deadline_epoch_secs, &mut backoff, cap) {
                    break;
                }
                continue;
            }
        };

        match tungstenite::connect(req) {
            Ok((mut socket, _resp)) => {
                set_state(&registry, &grant_id, "attached");
                loop {
                    match socket.read() {
                        Ok(Message::Text(t)) => {
                            if let Some(reply) = answer(t.as_str(), &profile) {
                                if socket.send(Message::Text(reply)).is_err() {
                                    break;
                                }
                            }
                        }
                        Ok(Message::Binary(b)) => {
                            let t = String::from_utf8_lossy(&b).to_string();
                            if let Some(reply) = answer(&t, &profile) {
                                if socket.send(Message::Text(reply)).is_err() {
                                    break;
                                }
                            }
                        }
                        Ok(Message::Ping(p)) => {
                            let _ = socket.send(Message::Pong(p));
                        }
                        Ok(Message::Pong(_)) => {}
                        Ok(Message::Close(frame)) => {
                            // tungstenite queues the Close reply on read; flush it so the
                            // runtime sees a clean close handshake rather than a bare EOF.
                            let _ = socket.flush();
                            let code = frame
                                .as_ref()
                                .map(|f| u16::from(f.code))
                                .unwrap_or(1000);
                            match disposition_close(code) {
                                Disposition::Stop(reason) => {
                                    set_state(
                                        &registry,
                                        &grant_id,
                                        &format!("stopped({reason})"),
                                    );
                                    return;
                                }
                                Disposition::Redial => break,
                            }
                        }
                        Ok(Message::Frame(_)) => {}
                        Err(_) => break,
                    }
                }
            }
            Err(e) => {
                // Map handshake HTTP status if we can extract one.
                if let Some(status) = handshake_status(&e) {
                    match disposition_handshake(status) {
                        Disposition::Stop(reason) => {
                            set_state(&registry, &grant_id, &format!("stopped({reason})"));
                            return;
                        }
                        Disposition::Redial => {}
                    }
                }
                // else: transient connect error -> redial
            }
        }

        // Redial with backoff.
        if !sleep_until_backoff(deadline_epoch_secs, &mut backoff, cap) {
            break;
        }
    }

    set_state(&registry, &grant_id, "ended(deadline)");
}

// Sleep min(backoff, remaining_to_deadline); grow backoff. Returns false if
// the deadline has already passed (caller should stop).
fn sleep_until_backoff(deadline_epoch_secs: u64, backoff: &mut u64, cap: u64) -> bool {
    let now = now_epoch_secs();
    if now >= deadline_epoch_secs {
        return false;
    }
    let remaining = deadline_epoch_secs - now;
    let nap = (*backoff).min(remaining);
    if nap > 0 {
        thread::sleep(Duration::from_secs(nap));
    }
    *backoff = (*backoff * 2).min(cap);
    now_epoch_secs() < deadline_epoch_secs
}

fn build_ws_request(url: &str, secret: &str) -> Result<Request<()>, String> {
    use tungstenite::handshake::client::generate_key;

    // Determine host authority for the Host header.
    let after_scheme = url
        .strip_prefix("wss://")
        .or_else(|| url.strip_prefix("ws://"))
        .ok_or_else(|| "attach url missing ws scheme".to_string())?;
    let authority = match after_scheme.find('/') {
        Some(idx) => &after_scheme[..idx],
        None => after_scheme,
    };
    let host = authority
        .rsplit_once(':')
        .map(|(h, _)| h)
        .unwrap_or(authority);
    let _ = host;

    Request::builder()
        .method("GET")
        .uri(url)
        .header("Host", authority)
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header("Sec-WebSocket-Key", generate_key())
        .header("Authorization", format!("Bearer {secret}"))
        .body(())
        .map_err(|e| format!("failed to build request: {e}"))
}

// Extract an HTTP status code from a tungstenite handshake error, if present.
fn handshake_status(err: &tungstenite::Error) -> Option<u16> {
    match err {
        tungstenite::Error::Http(resp) => Some(resp.status().as_u16()),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// answer(): MCP JSON-RPC dispatch
// ---------------------------------------------------------------------------

fn answer(text: &str, profile: &str) -> Option<String> {
    let req: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return None,
    };

    // Notifications have no id -> no response.
    let id = req.get("id").cloned();
    if id.is_none() {
        return None;
    }
    let id = id.unwrap();

    let method = req.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = req.get("params").cloned().unwrap_or(Value::Null);

    let result: Result<Value, (i64, String)> = match method {
        "initialize" => Ok(json!({
            "protocolVersion": "2024-11-05",
            "capabilities": { "tools": {} },
            "serverInfo": {
                "name": "instance-mcp-rpi",
                "version": "0.3.0"
            }
        })),
        "tools/list" => Ok(json!({ "tools": tool_list(profile) })),
        "tools/call" => handle_tool_call(&params, profile),
        other => Err((-32601, format!("method not found: {other}"))),
    };

    let response = match result {
        Ok(res) => json!({ "jsonrpc": "2.0", "id": id, "result": res }),
        Err((code, message)) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": message }
        }),
    };

    Some(response.to_string())
}

fn tool_list(profile: &str) -> Value {
    let sys_info = json!({
        "name": "sys_info",
        "description": "Report OS, CPU, memory, architecture and hostname of this node.",
        "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
    });
    let screenshot = json!({
        "name": "screenshot",
        "description": "Capture a screenshot of the current display via grim.",
        "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
    });
    let exec = json!({
        "name": "exec",
        "description": "Run a shell command via sh -c and return stdout/stderr/exit.",
        "inputSchema": {
            "type": "object",
            "properties": { "command": { "type": "string" } },
            "required": ["command"],
            "additionalProperties": false
        }
    });

    if profile == "sandbox" {
        json!([sys_info, screenshot])
    } else {
        // owner (default)
        json!([sys_info, screenshot, exec])
    }
}

fn handle_tool_call(params: &Value, profile: &str) -> Result<Value, (i64, String)> {
    let name = params
        .get("name")
        .and_then(|n| n.as_str())
        .ok_or_else(|| (-32602, "missing tool name".to_string()))?;
    let arguments = params.get("arguments").cloned().unwrap_or(Value::Null);

    match name {
        "sys_info" => Ok(tool_result(tool_sys_info())),
        "screenshot" => Ok(tool_result(tool_screenshot())),
        "exec" => {
            if profile == "sandbox" {
                return Err((-32601, "exec not available in sandbox profile".to_string()));
            }
            Ok(tool_result(tool_exec(&arguments)))
        }
        other => Err((-32601, format!("unknown tool: {other}"))),
    }
}

// Wrap a structured value into the MCP tool result shape.
fn tool_result(structured: Value) -> Value {
    let text = serde_json::to_string_pretty(&structured)
        .unwrap_or_else(|_| structured.to_string());
    json!({
        "content": [ { "type": "text", "text": text } ],
        "structuredContent": structured
    })
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

fn read_file_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn tool_sys_info() -> Value {
    // PRETTY_NAME from /etc/os-release
    let pretty_name = std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|content| {
            content.lines().find_map(|line| {
                line.strip_prefix("PRETTY_NAME=").map(|v| {
                    v.trim().trim_matches('"').to_string()
                })
            })
        })
        .unwrap_or_else(|| "unknown".to_string());

    // processor count from /proc/cpuinfo
    let cpu_count = std::fs::read_to_string("/proc/cpuinfo")
        .map(|c| {
            c.lines()
                .filter(|l| l.starts_with("processor"))
                .count()
        })
        .unwrap_or(0);

    // MemTotal from /proc/meminfo
    let mem_total = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|content| {
            content.lines().find_map(|line| {
                line.strip_prefix("MemTotal:").map(|v| v.trim().to_string())
            })
        })
        .unwrap_or_else(|| "unknown".to_string());

    let arch = std::env::consts::ARCH;

    let hostname = read_file_trim("/proc/sys/kernel/hostname")
        .unwrap_or_else(|| "unknown".to_string());

    json!({
        "os": pretty_name,
        "cpu_count": cpu_count,
        "mem_total": mem_total,
        "arch": arch,
        "hostname": hostname
    })
}

fn tool_screenshot() -> Value {
    let path = "/tmp/instance-mcp-shot.png";
    let output = std::process::Command::new("grim").arg(path).output();

    match output {
        Ok(out) if out.status.success() => {
            let bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            json!({ "ok": true, "path": path, "bytes": bytes })
        }
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            json!({ "ok": false, "path": path, "bytes": 0, "error": stderr.trim() })
        }
        Err(e) => {
            json!({ "ok": false, "path": path, "bytes": 0, "error": e.to_string() })
        }
    }
}

fn tool_exec(arguments: &Value) -> Value {
    let command = arguments
        .get("command")
        .and_then(|c| c.as_str())
        .unwrap_or("");

    if command.is_empty() {
        return json!({ "stdout": "", "stderr": "missing command", "exit": -1 });
    }

    let output = std::process::Command::new("sh")
        .arg("-c")
        .arg(command)
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            let exit = out.status.code().unwrap_or(-1);
            json!({ "stdout": stdout, "stderr": stderr, "exit": exit })
        }
        Err(e) => json!({ "stdout": "", "stderr": e.to_string(), "exit": -1 }),
    }
}

// ---------------------------------------------------------------------------
// HTTP control server
// ---------------------------------------------------------------------------

fn main() {
    let bind = std::env::var("BIND").unwrap_or_else(|_| "127.0.0.1:8790".to_string());
    let registry: Registry = Arc::new(Mutex::new(HashMap::new()));

    let listener = match TcpListener::bind(&bind) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("failed to bind {bind}: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("reverse-attach control server listening on {bind}");

    for stream in listener.incoming() {
        match stream {
            Ok(s) => {
                let reg = registry.clone();
                thread::spawn(move || {
                    if let Err(e) = handle_conn(s, reg) {
                        eprintln!("connection error: {e}");
                    }
                });
            }
            Err(e) => eprintln!("accept error: {e}"),
        }
    }
}

struct HttpRequest {
    method: String,
    path: String,
    body: String,
}

fn read_http_request(stream: &mut TcpStream) -> Result<HttpRequest, String> {
    stream.set_read_timeout(Some(Duration::from_secs(30))).ok();

    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 4096];

    // Read until we have the full headers.
    let header_end = loop {
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        let n = stream.read(&mut tmp).map_err(|e| format!("read: {e}"))?;
        if n == 0 {
            if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
                break pos + 4;
            }
            return Err("connection closed before headers complete".to_string());
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.len() > 1_048_576 {
            return Err("request headers too large".to_string());
        }
    };

    let header_text = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let mut lines = header_text.lines();
    let request_line = lines.next().ok_or_else(|| "empty request".to_string())?;
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let path = parts.next().unwrap_or("").to_string();

    // Content-Length
    let mut content_length: usize = 0;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.trim().eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse::<usize>().unwrap_or(0);
            }
        }
    }

    // Read remaining body bytes.
    let mut body_bytes: Vec<u8> = buf[header_end..].to_vec();
    while body_bytes.len() < content_length {
        let n = stream.read(&mut tmp).map_err(|e| format!("read body: {e}"))?;
        if n == 0 {
            break;
        }
        body_bytes.extend_from_slice(&tmp[..n]);
    }
    body_bytes.truncate(content_length);

    let body = String::from_utf8_lossy(&body_bytes).to_string();

    Ok(HttpRequest { method, path, body })
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

fn write_response(stream: &mut TcpStream, status: u16, reason: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {len}\r\n\
         Connection: close\r\n\
         \r\n\
         {body}",
        status = status,
        reason = reason,
        len = body.len(),
        body = body,
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn handle_conn(mut stream: TcpStream, registry: Registry) -> Result<(), String> {
    let req = read_http_request(&mut stream)?;

    // Strip query string from path for routing.
    let route = req.path.split('?').next().unwrap_or("").to_string();

    match (req.method.as_str(), route.as_str()) {
        ("POST", "/attach") => handle_attach(&mut stream, &req.body, registry),
        ("GET", "/attachments") => handle_attachments(&mut stream, registry),
        _ => {
            let body = json!({ "error": "not found" }).to_string();
            write_response(&mut stream, 404, "Not Found", &body);
            Ok(())
        }
    }
}

fn bad_request(stream: &mut TcpStream, message: &str) -> Result<(), String> {
    let body = json!({ "error": message }).to_string();
    write_response(stream, 400, "Bad Request", &body);
    Ok(())
}

fn handle_attach(
    stream: &mut TcpStream,
    body: &str,
    registry: Registry,
) -> Result<(), String> {
    let parsed: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return bad_request(stream, &format!("invalid JSON: {e}")),
    };

    let runtime = parsed.get("runtime").and_then(|v| v.as_str()).unwrap_or("");
    let session = parsed.get("session").and_then(|v| v.as_str()).unwrap_or("");
    let profile = parsed
        .get("profile")
        .and_then(|v| v.as_str())
        .unwrap_or("owner")
        .to_string();
    let ttl_secs = parsed
        .get("ttl_secs")
        .and_then(|v| v.as_u64())
        .unwrap_or(3600);
    let secret = parsed.get("secret").and_then(|v| v.as_str()).unwrap_or("");
    let admin_credential = parsed
        .get("admin_credential")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // Validation.
    if !(runtime.starts_with("ws://") || runtime.starts_with("wss://")) {
        return bad_request(stream, "runtime must start with ws:// or wss://");
    }
    if !valid_session(session) {
        return bad_request(stream, "session must match ^[a-z0-9-]{1,32}$");
    }
    if !(1..=86400).contains(&ttl_secs) {
        return bad_request(stream, "ttl_secs must be in 1..=86400");
    }
    let has_secret = !secret.is_empty();
    let has_admin = !admin_credential.is_empty();
    if has_secret == has_admin {
        return bad_request(
            stream,
            "exactly one of secret / admin_credential must be provided",
        );
    }

    // Resolve secret + deadline.
    let (effective_secret, expires_in_secs): (String, u64) = if has_admin {
        match mint(runtime, session, admin_credential, ttl_secs) {
            Ok((s, expires_in)) => (s, ttl_secs.min(expires_in)),
            Err(e) => return bad_request(stream, &format!("mint failed: {e}")),
        }
    } else {
        (secret.to_string(), ttl_secs)
    };

    let deadline = now_epoch_secs() + expires_in_secs;
    let grant_id = new_grant_id();

    {
        let mut map = registry.lock().map_err(|_| "registry poisoned".to_string())?;
        map.insert(
            grant_id.clone(),
            GrantInfo {
                grant_id: grant_id.clone(),
                session: session.to_string(),
                profile: profile.clone(),
                state: "starting".to_string(),
            },
        );
    }

    // Spawn the dial loop thread.
    let reg = registry.clone();
    let runtime_owned = runtime.to_string();
    let session_owned = session.to_string();
    let profile_owned = profile.clone();
    let gid = grant_id.clone();
    thread::spawn(move || {
        dial_loop(
            runtime_owned,
            session_owned,
            effective_secret,
            profile_owned,
            deadline,
            reg,
            gid,
        );
    });

    let resp = json!({
        "grant_id": grant_id,
        "session": session,
        "profile": profile,
        "expires_in_secs": expires_in_secs
    })
    .to_string();
    write_response(stream, 200, "OK", &resp);
    Ok(())
}

fn handle_attachments(stream: &mut TcpStream, registry: Registry) -> Result<(), String> {
    let list: Vec<Value> = {
        let map = registry.lock().map_err(|_| "registry poisoned".to_string())?;
        map.values()
            .map(|g| {
                json!({
                    "grant_id": g.grant_id,
                    "session": g.session,
                    "profile": g.profile,
                    "state": g.state
                })
            })
            .collect()
    };
    let body = Value::Array(list).to_string();
    write_response(stream, 200, "OK", &body);
    Ok(())
}
