//! iOS 27 on-device pairing: the phone pairs with this app itself, no computer needed.
//!
//! The app advertises `_remotepairing-pairable-host._tcp` over Bonjour (Swift does the advertising with the
//! port, name and TXT records returned by `ss_pair_begin`). The user opens Settings › Privacy & Security ›
//! Developer Mode, taps "Pair with Saved Scroll" and types the 6-digit code we show. The phone then drives
//! the rppairing conversation with us as the responder (idevice `PairableHost`), and we save the
//! RemotePairing record the engine uses for pair-verify (`phone.rs`).
//!
//!   char *ss_pair_begin(const char *out_path);  // {"ok","port","name","txt":{...}}
//!   char *ss_pair_status(void);                 // {"state": idle|waiting|code|done|failed, "code", "error", "device"}

use std::ffi::{c_char, CStr};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};

/// Shown on the phone: "Pair with Saved Scroll".
pub const DISPLAY_NAME: &str = "Saved Scroll";
/// iOS lists pairable hosts as computers, so the model must be a Mac identifier.
const MODEL: &str = "Mac17,7";
/// How long we wait for the user to finish in Settings.
const WINDOW: Duration = Duration::from_secs(300);

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PairState {
    pub state: String,
    pub code: String,
    pub error: String,
    pub device: String,
}

fn cell() -> &'static Mutex<PairState> {
    static S: OnceLock<Mutex<PairState>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(PairState { state: "idle".into(), ..Default::default() }))
}
fn set(f: impl FnOnce(&mut PairState)) {
    f(&mut cell().lock().unwrap());
}
pub fn state() -> PairState {
    cell().lock().unwrap().clone()
}

/// What Swift advertises over Bonjour.
pub struct Advert {
    pub port: u16,
    pub name: String,
    pub txt: Vec<(String, String)>,
}

/// Binds a listener, then waits for the phone on a background thread (up to 5 minutes).
pub fn begin(out_path: String) -> Result<Advert, String> {
    if state().state == "waiting" || state().state == "code" {
        return Err("pairing already in progress".into());
    }
    let listener = std::net::TcpListener::bind(("0.0.0.0", 0)).map_err(|e| format!("listen: {e}"))?;
    listener.set_nonblocking(true).map_err(|e| format!("listen: {e}"))?;
    let port = listener.local_addr().map_err(|e| format!("listen: {e}"))?.port();
    let info = PairableHostInfo::generate(DISPLAY_NAME, MODEL);
    // The identifier comes from the host name, so it stays the same for every attempt and for pair-verify.
    let identifier = RpPairingFile::generate(crate::phone::HOST_NAME).identifier().to_string();
    let txt = info.mdns_txt_records(&identifier);
    set(|s| *s = PairState { state: "waiting".into(), ..Default::default() });
    std::thread::Builder::new()
        .name("sspair".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
            let result = rt.block_on(async move {
                let listener = tokio::net::TcpListener::from_std(listener).map_err(|e| format!("listen: {e}"))?;
                tokio::time::timeout(WINDOW, wait_for_phone(listener, info, &out_path))
                    .await
                    .map_err(|_| "timed out: nobody paired within 5 minutes".to_string())?
            });
            match result {
                Ok(device) => set(|s| {
                    s.state = "done".into();
                    s.device = device;
                    s.code.clear();
                }),
                Err(e) => set(|s| {
                    s.state = "failed".into();
                    s.error = e;
                }),
            }
        })
        .map_err(|e| format!("thread: {e}"))?;
    Ok(Advert { port, name: identifier, txt })
}

/// Accepts connections until one completes pairing. iOS may connect more than once (a probe, a retry after
/// a wrong code), so a failed attempt keeps the window open.
async fn wait_for_phone(listener: tokio::net::TcpListener, info: PairableHostInfo, out_path: &str) -> Result<String, String> {
    loop {
        let (stream, _) = listener.accept().await.map_err(|e| format!("accept: {e}"))?;
        let mut file = RpPairingFile::generate(crate::phone::HOST_NAME);
        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info.clone());
        let res = host
            .accept(&mut file, |code| async move {
                set(|s| {
                    s.state = "code".into();
                    s.code = code;
                })
            })
            .await;
        match res {
            Ok(peer) => {
                file.write_to_file(out_path).await.map_err(|e| format!("save pairing record: {e}"))?;
                return Ok(format!("{} ({})", peer.name, peer.model));
            }
            Err(e) => set(|s| {
                s.state = "waiting".into();
                s.error = format!("{e}");
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::remote_pairing::{RemotePairingClient, RpPairingSocketProvider};

    /// One pairing attempt by a fake iPhone (idevice's computer-side client). `wrong` types a wrong code.
    async fn attempt(port: u16, wrong: bool) {
        let stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.expect("connect");
        // The iPhone opens with a plain handshake (no pair-verify attempt, which the responder refuses);
        // idevice's client always tries verify first, so the test sends the iPhone's hello itself, then runs pair-setup.
        let mut socket = RpPairingSocket::new(stream);
        socket
            .send_plain(serde_json::json!({"request": {"_0": {"handshake": {"_0": {
                "hostOptions": {"attemptPairVerify": false}, "wireProtocolVersion": 26}}}}}), 0)
            .await
            .expect("hello");
        socket.recv_plain().await.expect("hello reply");
        let mut client = RemotePairingClient::new(socket, "test-iphone");
        let mut phone_side = RpPairingFile::generate("test-iphone");
        let typed = || async move {
            // the "user" reads the code off the app, like they would off the floating window
            for _ in 0..200 {
                let s = state();
                if s.state == "code" {
                    if !wrong { return s.code; }
                    let last = (s.code.as_bytes()[5] - b'0' + 1) % 10;
                    return format!("{}{}", &s.code[..5], last);
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            String::new()
        };
        let _ = tokio::time::timeout(Duration::from_secs(30), client.pair(&mut phone_side, typed)).await.expect("too slow");
    }

    async fn app_error_after_attempt() -> String {
        for _ in 0..200 {
            let s = state();
            if !s.error.is_empty() || s.state == "done" { return s.error; }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("the app never finished the attempt: {:?}", state());
    }

    /// Loopback pairing against our responder. A wrong code must be refused without closing the window;
    /// the right code must get through the whole SRP exchange and the encrypted M5 step. The last step
    /// needs the iPhone's own identity (`remotepairing_udid`), which only a real iPhone sends, so the test
    /// stops there (idevice's computer-side client can't play that part).
    #[tokio::test(flavor = "current_thread")]
    async fn phone_pairs_with_the_app_over_loopback() {
        let out = std::env::temp_dir().join(format!("ss-pair-{}.plist", std::process::id()));
        let ad = begin(out.to_string_lossy().to_string()).expect("begin");
        assert_eq!(ad.txt.iter().find(|(k, _)| k == "name").map(|(_, v)| v.as_str()), Some(DISPLAY_NAME));
        assert!(ad.txt.iter().any(|(k, v)| k == "identifier" && *v == ad.name));
        assert!(begin(out.to_string_lossy().to_string()).is_err(), "a second pairing while one is open");

        attempt(ad.port, true).await;
        let e1 = app_error_after_attempt().await;
        assert!(!e1.is_empty() && !e1.contains("remotepairing_udid"), "wrong code: {e1}");
        assert_eq!(state().state, "waiting", "the window stays open after a wrong code");

        set(|s| s.error.clear());
        attempt(ad.port, false).await;
        let e2 = app_error_after_attempt().await;
        assert!(e2.contains("remotepairing_udid"), "right code should pass SRP and M5, got: {e2}");
    }
}

// ---------------- C API ----------------
#[no_mangle]
pub extern "C" fn ss_pair_begin(out_path: *const c_char) -> *mut c_char {
    let path = if out_path.is_null() { String::new() } else { unsafe { CStr::from_ptr(out_path) }.to_string_lossy().to_string() };
    if path.is_empty() {
        return crate::ffi::out(serde_json::json!({"ok": false, "error": "no output path"}));
    }
    match begin(path) {
        Ok(a) => {
            let txt: serde_json::Map<String, serde_json::Value> = a.txt.into_iter().map(|(k, v)| (k, v.into())).collect();
            crate::ffi::out(serde_json::json!({"ok": true, "port": a.port, "name": a.name, "txt": txt}))
        }
        Err(e) => crate::ffi::out(serde_json::json!({"ok": false, "error": e})),
    }
}

#[no_mangle]
pub extern "C" fn ss_pair_status() -> *mut c_char {
    let s = state();
    crate::ffi::out(serde_json::json!({"ok": true, "state": s.state, "code": s.code, "error": s.error, "device": s.device}))
}
