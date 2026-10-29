//! Dial-side negatives for reverse attach, run against a plain TCP listener
//! standing in for the runtime. They pin what the Rust dialer sends on the
//! upgrade and how it reads a refused upgrade (the Swift oracle is
//! `ReverseAttachNegativeTests`).

use std::net::TcpListener;
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use tungstenite::handshake::server::{
    ErrorResponse, Request as ServerRequest, Response as ServerResponse,
};
use tungstenite::http::{Request, Response};

use super::*;

/// What the one-shot runtime saw on the upgrade request.
#[derive(Clone, Debug, Default)]
struct Seen {
    connections: usize,
    authorization: Option<String>,
    upgrade: Option<String>,
    connection: Option<String>,
}

/// Accept one upgrade on 127.0.0.1:0. A request whose `Authorization` is not
/// exactly `Bearer <expected>` gets 401. Returns the port and a join handle that
/// yields what was seen, after a short wait for any second connection.
fn one_shot_runtime(expected: &'static str) -> (u16, thread::JoinHandle<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let seen = Arc::new(Mutex::new(Seen {
            connections: 1,
            ..Seen::default()
        }));
        let cb_seen = seen.clone();
        let want = format!("Bearer {expected}");
        #[allow(clippy::result_large_err)] // ErrorResponse is fixed by tungstenite's callback type
        let callback = move |req: &ServerRequest,
                             resp: ServerResponse|
              -> Result<ServerResponse, ErrorResponse> {
            let header = |name: &str| {
                req.headers()
                    .get(name)
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned)
            };
            let mut s = cb_seen.lock().unwrap();
            s.authorization = header("authorization");
            s.upgrade = header("upgrade");
            s.connection = header("connection");
            if s.authorization.as_deref() == Some(want.as_str()) {
                Ok(resp)
            } else {
                Err(Response::builder().status(401).body(None).unwrap())
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let _ = tungstenite::accept_hdr(stream, callback);

        // A dialer that retried on its own would show up here as a second connection.
        thread::sleep(Duration::from_millis(300));
        listener.set_nonblocking(true).unwrap();
        let extra = listener.accept().is_ok() as usize;
        let mut out = seen.lock().unwrap().clone();
        out.connections += extra;
        out
    });
    (port, handle)
}

/// Accept one connection and read what arrives first. Used to see whether a
/// `wss://` dial sends anything that looks like HTTP to a plaintext listener.
fn plaintext_listener() -> (u16, thread::JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut buf = vec![0u8; 512];
        let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
        buf.truncate(n);
        buf
    });
    (port, handle)
}

fn upgrade_url(port: u16) -> String {
    format!("ws://127.0.0.1:{port}/tools/attach/s1")
}

/// The same request `build_ws_request` builds, minus the `Authorization` header.
fn upgrade_without_authorization(url: &str) -> Request<()> {
    Request::builder()
        .method("GET")
        .uri(url)
        .header(
            "Host",
            url.trim_start_matches("ws://").split('/').next().unwrap(),
        )
        .header("Connection", "Upgrade")
        .header("Upgrade", "websocket")
        .header("Sec-WebSocket-Version", "13")
        .header(
            "Sec-WebSocket-Key",
            tungstenite::handshake::client::generate_key(),
        )
        .body(())
        .unwrap()
}

#[test]
fn right_bearer_upgrades_with_the_expected_headers() {
    let (port, server) = one_shot_runtime("s3cret");
    let req = build_ws_request(&upgrade_url(port), "s3cret").unwrap();
    let (_socket, resp) = match tungstenite::connect(req) {
        Ok(ok) => ok,
        Err(e) => panic!("upgrade with the right bearer was refused: {e}"),
    };
    assert_eq!(resp.status().as_u16(), 101);
    let seen = server.join().unwrap();
    assert_eq!(seen.authorization.as_deref(), Some("Bearer s3cret"));
    assert_eq!(
        seen.upgrade
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("websocket")
    );
    assert!(seen
        .connection
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase()
        .contains("upgrade"));
    assert_eq!(seen.connections, 1);
}

#[test]
fn same_length_wrong_bearer_is_refused_once_and_stops() {
    let (port, server) = one_shot_runtime("s3cret");
    let req = build_ws_request(&upgrade_url(port), "s3crXt").unwrap();
    let err = match tungstenite::connect(req) {
        Err(e) => e,
        Ok(_) => panic!("a wrong bearer must not upgrade"),
    };
    assert_eq!(handshake_status(&err), Some(401));
    assert!(matches!(
        disposition_handshake(401),
        Disposition::Stop(ref r) if r == "handshake_rejected_401"
    ));
    assert_eq!(server.join().unwrap().connections, 1);
}

#[test]
fn empty_bearer_is_refused_once_and_stops() {
    let (port, server) = one_shot_runtime("s3cret");
    let req = build_ws_request(&upgrade_url(port), "").unwrap();
    let err = match tungstenite::connect(req) {
        Err(e) => e,
        Ok(_) => panic!("an empty bearer must not upgrade"),
    };
    assert_eq!(handshake_status(&err), Some(401));
    assert_eq!(server.join().unwrap().connections, 1);
}

#[test]
fn missing_authorization_header_is_refused_once_and_stops() {
    let (port, server) = one_shot_runtime("s3cret");
    let req = upgrade_without_authorization(&upgrade_url(port));
    let err = match tungstenite::connect(req) {
        Err(e) => e,
        Ok(_) => panic!("an upgrade without Authorization must not succeed"),
    };
    assert_eq!(handshake_status(&err), Some(401));
    assert!(matches!(
        disposition_handshake(401),
        Disposition::Stop(ref r) if r == "handshake_rejected_401"
    ));
    let seen = server.join().unwrap();
    assert_eq!(seen.authorization, None);
    assert_eq!(seen.connections, 1);
}

#[test]
fn wss_to_a_plaintext_listener_fails_without_falling_back() {
    let (port, server) = plaintext_listener();
    let url = format!("wss://127.0.0.1:{port}/tools/attach/s1");
    let req = build_ws_request(&url, "s3cret").unwrap();
    // The Linux build has no process-level rustls CryptoProvider, so tungstenite can
    // panic while it sets up TLS. That is a separate, pre-existing gap (a wss:// runtime
    // would panic the dial thread), reported rather than fixed here. For this test both
    // a TLS error and that panic mean the dial did not succeed.
    let dialed = std::panic::catch_unwind(AssertUnwindSafe(|| tungstenite::connect(req).is_ok()));
    assert!(
        !matches!(dialed, Ok(true)),
        "wss to a plaintext listener upgraded"
    );
    let bytes = server.join().unwrap();
    assert!(
        !bytes.starts_with(b"GET "),
        "dialer fell back to plaintext HTTP"
    );
    assert!(
        !bytes.windows(4).any(|w| w == b"HTTP"),
        "dialer sent an HTTP request"
    );
}
