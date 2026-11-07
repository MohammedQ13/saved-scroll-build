//! C API for the iOS app (Swift). The engine runs on its own thread (current-thread runtime + LocalSet).
//!
//!   char *ss_engine_start(const char *pairing_path, uint16_t port, const char *token_or_null);  // JSON
//!   char *ss_engine_status(void);                                                                  // JSON
//!   void  ss_engine_stop_dive(void);
//!   void  ss_string_free(char *);

use std::ffi::{c_char, CStr, CString};
use std::sync::{Arc, Mutex, OnceLock};

use crate::Status;

struct Shared {
    status: Arc<Mutex<Status>>,
    token: String,
    port: u16,
    stop_tx: tokio::sync::mpsc::UnboundedSender<()>,
}
static SHARED: OnceLock<Shared> = OnceLock::new();

pub(crate) fn out(v: serde_json::Value) -> *mut c_char {
    CString::new(v.to_string()).unwrap_or_default().into_raw()
}

/// Starts the engine once (later calls return the running engine's info). `pairing_path` is the
/// RemotePairing record; empty = simulated device (UI development).
#[no_mangle]
pub extern "C" fn ss_engine_start(pairing_path: *const c_char, port: u16, token: *const c_char) -> *mut c_char {
    if let Some(s) = SHARED.get() {
        return out(serde_json::json!({"ok": true, "already": true, "port": s.port, "token": s.token}));
    }
    let path = if pairing_path.is_null() { String::new() } else { unsafe { CStr::from_ptr(pairing_path) }.to_string_lossy().to_string() };
    let tok = if token.is_null() { None } else { Some(unsafe { CStr::from_ptr(token) }.to_string_lossy().to_string()).filter(|t| !t.is_empty()) };
    let (status_tx, status_rx) = std::sync::mpsc::channel();
    let (stop_tx, mut stop_rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    std::thread::Builder::new().name("ssengine".into()).spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
        let local = tokio::task::LocalSet::new();
        local.block_on(&rt, async move {
            macro_rules! go {
                ($dev:expr) => {{
                    let engine = crate::Engine::new($dev, tok);
                    let _ = status_tx.send((engine.status.clone(), engine.token.clone()));
                    let e2 = engine.clone();
                    tokio::task::spawn_local(async move { while stop_rx.recv().await.is_some() { e2.stop_now().await; } });
                    let _ = engine.serve(port).await;
                }};
            }
            #[cfg(feature = "phone")]
            {
                if path.is_empty() { go!(crate::MockDevice::new()) } else { go!(crate::phone::PhoneDevice::new(&path, None)) }
            }
            #[cfg(not(feature = "phone"))]
            {
                let _ = &path;
                go!(crate::MockDevice::new())
            }
        });
    }).expect("thread");
    match status_rx.recv_timeout(std::time::Duration::from_secs(5)) {
        Ok((status, token)) => {
            let _ = SHARED.set(Shared { status, token: token.clone(), port, stop_tx });
            out(serde_json::json!({"ok": true, "port": port, "token": token}))
        }
        Err(_) => out(serde_json::json!({"ok": false, "error": "engine didn't start"})),
    }
}

/// Live status for the app's overlay: {"busy", "done", "planned", "checking", "connected", "error"}.
#[no_mangle]
pub extern "C" fn ss_engine_status() -> *mut c_char {
    match SHARED.get() {
        Some(s) => {
            let st = s.status.lock().unwrap().clone();
            out(serde_json::json!({"ok": true, "busy": st.busy, "checking": st.checking, "done": st.done, "planned": st.planned,
                                   "preDone": st.pre_done, "pre": st.pre, "connected": st.connected, "error": st.last_error,
                                   "checkEndMs": st.check_end_ms, "checkFailed": st.check_failed}))
        }
        None => out(serde_json::json!({"ok": false, "error": "not started"})),
    }
}

/// The app came to the front: reopen the 3-minute pairing window.
#[no_mangle]
pub extern "C" fn ss_engine_app_active() {
    crate::APP_IN_FRONT.store(true, std::sync::atomic::Ordering::Relaxed);
    crate::APP_ACTIVE_MS.store(crate::now_ms(), std::sync::atomic::Ordering::Relaxed);
}

#[no_mangle]
pub extern "C" fn ss_engine_app_background() {
    crate::APP_IN_FRONT.store(false, std::sync::atomic::Ordering::Relaxed);
}

/// Stop button in the overlay.
#[no_mangle]
pub extern "C" fn ss_engine_stop_dive() {
    if let Some(s) = SHARED.get() { let _ = s.stop_tx.send(()); }
}

#[no_mangle]
pub extern "C" fn ss_string_free(s: *mut c_char) {
    if !s.is_null() { unsafe { drop(CString::from_raw(s)); } }
}
