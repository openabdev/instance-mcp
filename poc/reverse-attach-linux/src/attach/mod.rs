//! Reverse-attach grants: registry, Connect `MacGrant` shape, session/URL validation and the §9.2 disposition table.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

pub mod client;

// Shared grant registry
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct GrantInfo {
    id: String,
    runtime: String,
    session: String,
    profile: String,
    principal: String,
    state: String,
    ended: Option<String>,
    expires_at_epoch_secs: u64,
    cancelled: Arc<AtomicBool>,
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
            g.ended = None;
        }
    }
}

fn set_ended(registry: &Registry, grant_id: &str, reason: &str) {
    if let Ok(mut map) = registry.lock() {
        if let Some(g) = map.get_mut(grant_id) {
            g.state = "ended".to_string();
            g.ended = Some(reason.to_string());
        }
    }
}

/// Exact Swift `MacGrant` shape consumed by OpenAB Connect/Remote. Fields not
/// present in the early PoC (`runtime`, `principal`, standard `id`/state) made a
/// successful POST decode as a generic client parse failure.
fn grant_json(g: &GrantInfo) -> Value {
    let mut out = json!({
        "id": g.id,
        "runtime": g.runtime,
        "session": g.session,
        "profile": g.profile,
        "principal": g.principal,
        "state": g.state,
        "expires_in_secs": g.expires_at_epoch_secs.saturating_sub(now_epoch_secs()),
    });
    if let Some(ended) = &g.ended {
        out["ended"] = Value::String(ended.clone());
    }
    out
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

fn valid_session(s: &str) -> bool {
    // ^[a-z0-9-]{1,32}$
    let len = s.len();
    if !(1..=32).contains(&len) {
        return false;
    }
    s.bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn strip_trailing_slashes(s: &str) -> &str {
    s.trim_end_matches('/')
}

fn attach_url(runtime: &str, session: &str) -> String {
    format!(
        "{}/tools/attach/{}",
        strip_trailing_slashes(runtime),
        session
    )
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
        4001 => Disposition::Stop("grant_expired".to_string()),
        4002 => Disposition::Stop("replaced".to_string()),
        4004 => Disposition::Stop("session_ended".to_string()),
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
        _ => Disposition::Stop(format!("handshake_rejected_{status}")),
    }
}

// ---------------------------------------------------------------------------
