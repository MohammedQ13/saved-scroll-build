//! Saved Scroll on-phone engine.
//!
//! Serves the SS Remote HTTP API (same as `remote/firmware` and `lab/home_remote.py`) on 127.0.0.1, so the
//! Saved Scroll brain (Scriptable) drives it unchanged, and turns commands into real touches through a
//! [`Device`]. On the iPhone the device is [`phone::PhoneDevice`] (iOS 27 CoreDevice HID over the loopback
//! VPN); in tests it's [`MockDevice`].
//!
//! Coordinates are normalised 0..=65535 (0,0 = top-left). Swipe length `dy` uses the board's units:
//! 1000 = the full screen height (default 400 = 40%). Positive dy = finger up = the grid scrolls down.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

#[cfg(feature = "phone")]
pub mod phone;
#[cfg(feature = "phone")]
pub mod pairing;
#[cfg(feature = "refresh")]
pub mod refresh;
pub mod ffi;

pub const VERSION: &str = "phone-0.1.0";
pub const FULL: i64 = 65535;
const PAIR_WINDOW: Duration = Duration::from_secs(180);

/// When the app last came to the front (ms since the Unix epoch). Reopens the 3-minute pairing window,
/// so the user never has to force-close the app to connect (set by `ss_engine_app_active`).
pub static APP_ACTIVE_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub static APP_IN_FRONT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn log_tile_retry(stage: i32) {
    #[cfg(target_os = "ios")]
    unsafe {
        extern "C" { fn ss_macro_retry_event(stage: i32); }
        ss_macro_retry_event(stage);
    }
    #[cfg(not(target_os = "ios"))]
    let _ = stage;
}

/// Something that can touch the screen. Calls are made from one thread (a current-thread runtime).
#[allow(async_fn_in_trait)]
pub trait Device {
    /// Connect (or reconnect) to the phone. Returns a human-readable error when it can't.
    async fn connect(&mut self) -> Result<(), String>;
    /// Open the touch session (on the phone: the screen media stream that gates HID). Gestures between
    /// `begin` and `end` share it, since starting one costs about a second.
    async fn begin(&mut self) -> Result<(), String>;
    async fn end(&mut self);
    async fn drag(&mut self, x1: u16, y1: u16, x2: u16, y2: u16, steps: u32, delay_ms: u64) -> Result<(), String>;
    async fn tap(&mut self, x: u16, y: u16) -> Result<(), String>;
    async fn screen_anchor(&mut self, _kind: i32) -> Option<u16> { Some(1) }
    fn connected(&self) -> bool;
}

/// Records gestures instead of touching a phone.
#[derive(Default)]
pub struct MockDevice {
    pub log: Vec<String>,
    pub sessions: u32,
    pub ok: bool,
    pub off_grid: bool,
    pub miss_grid_once: bool,
    pub miss_share_once: bool,
    pub off_grid_after_first_tap: bool,
    pub missing_anchor: Option<i32>,
    pub connect_ms: u64,
    pub activate_on_tap: Option<(u16, u16)>,
}
impl MockDevice {
    pub fn new() -> Self { Self { ok: true, ..Default::default() } }
}
impl Device for MockDevice {
    async fn connect(&mut self) -> Result<(), String> {
        if self.connect_ms > 0 { tokio::time::sleep(Duration::from_millis(self.connect_ms)).await; }
        if self.ok { Ok(()) } else { Err("not connected".into()) }
    }
    async fn begin(&mut self) -> Result<(), String> { self.sessions += 1; Ok(()) }
    async fn end(&mut self) {}
    async fn drag(&mut self, x1: u16, y1: u16, x2: u16, y2: u16, steps: u32, delay_ms: u64) -> Result<(), String> {
        self.log.push(format!("drag {x1} {y1} {x2} {y2} {steps} {delay_ms}"));
        tokio::time::sleep(Duration::from_millis(steps as u64 * delay_ms / 20)).await;
        Ok(())
    }
    async fn tap(&mut self, x: u16, y: u16) -> Result<(), String> {
        self.log.push(format!("tap {x} {y}"));
        if self.off_grid_after_first_tap { self.off_grid = true; }
        if self.activate_on_tap == Some((x, y)) {
            APP_ACTIVE_MS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
        Ok(())
    }
    async fn screen_anchor(&mut self, kind: i32) -> Option<u16> {
        if kind == 0 && std::mem::take(&mut self.miss_grid_once) { return None; }
        if kind == 1 && std::mem::take(&mut self.miss_share_once) { return None; }
        (!((kind == 0 || kind == 3) && self.off_grid) && self.missing_anchor != Some(if kind == 3 { 0 } else { kind })).then_some(1)
    }
    fn connected(&self) -> bool { self.ok }
}

/// Live state, readable from other threads (the app's PiP overlay reads it through the FFI).
#[derive(Clone, Debug, Default)]
pub struct Status {
    pub busy: bool,
    pub checking: bool,
    pub done: u32,
    pub planned: u32,
    pub pre_done: u32,
    pub pre: u32,
    pub connected: bool,
    pub last_error: String,
    /// When the last check macro finished (ms since 1970), so the app can tell it was brought forward by it.
    pub check_end_ms: u64,
    pub check_failed: bool,
    pub run_id: u64,
    pub motion_ms: u64,
}

pub struct Engine<D: Device> {
    pub dev: Rc<RefCell<D>>,
    pub status: Arc<Mutex<Status>>,
    pub token: String,
    pub check_macro: RefCell<String>,
    /// Alternate rows used to corroborate a landing.
    alternate_checks: RefCell<[String; 8]>,
    pub auto_check: RefCell<bool>,
    started: Instant,
    stop: Rc<RefCell<bool>>,
    task: RefCell<Option<tokio::task::JoinHandle<()>>>,
    motion_gate: tokio::sync::Mutex<()>,
    stop_gate: tokio::sync::Mutex<()>,
    cancel_generation: Cell<u64>,
    pub swipe_x: u16,
    pub swipe_y: u16,
}

pub fn random_token() -> String {
    use rand::Rng;
    let mut r = rand::thread_rng();
    (0..16).map(|_| format!("{:x}", r.gen_range(0..16))).collect()
}

/// One swipe: (x1, y1, x2, y2, steps, delay_ms). dy: board units, 1000 = screen height.
pub fn swipe_gesture(swipe_x: u16, swipe_y: u16, dy: i64, dur_ms: u64) -> (u16, u16, u16, u16, u32, u64) {
    let length = FULL * dy.abs().min(900) / 1000;
    let y1 = if dy > 0 { swipe_y as i64 } else { swipe_y as i64 - length };
    let y1 = y1.clamp(2000, FULL - 2000);
    let y2 = (if dy > 0 { y1 - length } else { y1 + length }).clamp(1000, FULL - 1000);
    let steps = ((dur_ms / 16).max(6)) as u32;
    let delay = (dur_ms / steps as u64).max(1);
    (swipe_x, y1 as u16, swipe_x, y2 as u16, steps, delay)
}

impl<D: Device + 'static> Engine<D> {
    pub fn new(dev: D, token: Option<String>) -> Rc<Self> {
        Rc::new(Self {
            dev: Rc::new(RefCell::new(dev)),
            status: Arc::new(Mutex::new(Status::default())),
            token: token.unwrap_or_else(random_token),
            check_macro: RefCell::new(String::new()),
            alternate_checks: RefCell::new(Default::default()),
            auto_check: RefCell::new(false),
            started: Instant::now(),
            stop: Rc::new(RefCell::new(false)),
            task: RefCell::new(None),
            motion_gate: tokio::sync::Mutex::new(()),
            stop_gate: tokio::sync::Mutex::new(()),
            cancel_generation: Cell::new(0),
            swipe_x: (FULL / 2) as u16,
            swipe_y: (FULL * 72 / 100) as u16,
        })
    }

    pub fn status_json(&self) -> serde_json::Value {
        let s = self.status.lock().unwrap().clone();
        serde_json::json!({
            "ok": true, "version": VERSION, "kind": "phone", "ble": s.connected,
            "busy": s.busy && !s.checking, "checking": s.checking, "done": s.done, "planned": s.planned,
            "preDone": s.pre_done, "pre": s.pre, "autoCheck": *self.auto_check.borrow(), "checkEndMs": s.check_end_ms,
            "hasCheckMacro": !self.check_macro.borrow().is_empty(), "error": s.last_error,
            "runId": s.run_id, "checkFailed": s.check_failed,
            "motionMs": s.motion_ms,
            "verifiedDives": true,
            "probeSlots": 1 + self.alternate_checks.borrow().iter().filter(|check| !check.is_empty()).count(),
        })
    }

    fn set<F: FnOnce(&mut Status)>(&self, f: F) { f(&mut self.status.lock().unwrap()); }

    async fn sleep_or_stop(stop: &Rc<RefCell<bool>>, ms: u64) {
        let end = Instant::now() + Duration::from_millis(ms);
        while Instant::now() < end && !*stop.borrow() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    async fn dive(self: &Rc<Self>, n: u32, iv: u64, dy: i64, dur: u64, pn: u32, piv: u64, pdy: i64, check: String, verify: bool) -> serde_json::Value {
        // Finish with any running dive first: it holds the device while mid-swipe.
        let generation = self.cancel_generation.get();
        let checking = self.status.lock().unwrap().checking;
        if !checking && self.stop_and_join().await["stopped"] != true {
            return serde_json::json!({"ok": false, "error": "previous movement is still stopping"});
        }
        let running = self.task.borrow_mut().take();
        if let Some(mut h) = running { // let a running check finish its last tap
            if tokio::time::timeout(Duration::from_secs(4), &mut h).await.is_err() {
                self.task.borrow_mut().replace(h);
                return serde_json::json!({"ok": false, "error": "previous landing check is still finishing"});
            }
        }
        if generation != self.cancel_generation.get() {
            return serde_json::json!({"ok": false, "error": "start cancelled"});
        }
        *self.stop.borrow_mut() = false;
        if let Err(e) = self.dev.borrow_mut().connect().await {
            self.set(|s| { s.connected = false; s.last_error = e.clone(); });
            return serde_json::json!({"ok": false, "error": format!("iPhone services not reachable: {e}")});
        }
        if *self.stop.borrow() {
            return serde_json::json!({"ok": false, "error": "start cancelled"});
        }
        self.set(|s| s.connected = true);
        self.set(|s| {
            s.busy = true; s.done = 0; s.planned = n; s.pre_done = 0; s.pre = pn;
            s.last_error.clear(); s.check_failed = false; s.check_end_ms = 0; s.run_id += 1; s.motion_ms = 0;
        });
        let run_id = self.status.lock().unwrap().run_id;
        let me = self.clone();
        let h = tokio::task::spawn_local(async move { me.run_dive(n, iv, dy, dur, pn, piv, pdy, &check, verify).await; });
        *self.task.borrow_mut() = Some(h);
        serde_json::json!({"ok": true, "planned": n, "pre": pn, "runId": run_id, "seconds": (n as u64 * iv + pn as u64 * piv) / 1000})
    }

    async fn run_dive(self: &Rc<Self>, n: u32, iv: u64, dy: i64, dur: u64, pn: u32, piv: u64, pdy: i64, check: &str, verify: bool) {
        let in_front = || APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed);
        let stop = self.stop.clone();
        // A manual landing can queue a legacy continuation before the app reopens TikTok.
        for _ in 0..30 {
            if !in_front() || *stop.borrow() { break; }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if in_front() || *stop.borrow() {
            self.set(|s| { s.busy = false; s.last_error = "Open TikTok's Saved grid".into(); });
            return;
        }
        let check_only = n == 0 && pn == 0 && *self.auto_check.borrow() &&
            check.split(';').map(str::trim).filter(|step| !step.is_empty())
                .find(|step| step.split_whitespace().next() != Some("W"))
                .is_some_and(|step| step.split_whitespace().take(2).eq(["A", "0"]));
        // The first macro tap already gets its own fresh Saved-grid anchor.
        // Motion legs still verify the grid before opening a gesture session.
        if verify && !check_only && self.dev.borrow_mut().screen_anchor(0).await.is_none() {
            self.set(|s| { s.busy = false; s.last_error = "Open TikTok's Saved grid".into(); });
            return;
        }
        if let Err(e) = self.dev.borrow_mut().begin().await {
            self.set(|s| { s.busy = false; s.last_error = e; });
            return;
        }
        for i in 0..pn {
            if *stop.borrow() || in_front() { break; }
            let t0 = Instant::now();
            let (x1, y1, x2, y2, st, d) = swipe_gesture(self.swipe_x, self.swipe_y, pdy, dur);
            let _ = self.dev.borrow_mut().drag(x1, y1, x2, y2, st, d).await;
            self.set(|s| s.pre_done = i + 1);
            Self::sleep_or_stop(&stop, piv.saturating_sub(t0.elapsed().as_millis() as u64)).await;
        }
        if pn > 0 { Self::sleep_or_stop(&stop, 1500).await; }
        let motion_started = Instant::now();
        for i in 0..n {
            if *stop.borrow() || in_front() { break; }
            let t0 = Instant::now();
            let (x1, y1, x2, y2, st, d) = swipe_gesture(self.swipe_x, self.swipe_y, dy, dur);
            if let Err(e) = self.dev.borrow_mut().drag(x1, y1, x2, y2, st, d).await {
                self.set(|s| s.last_error = e);
                break;
            }
            self.set(|s| s.done = i + 1);
            Self::sleep_or_stop(&stop, iv.saturating_sub(t0.elapsed().as_millis() as u64)).await;
        }
        self.set(|s| s.motion_ms = motion_started.elapsed().as_millis() as u64);
        let run_check = !*stop.borrow() && !in_front() && *self.auto_check.borrow() && !check.is_empty() &&
            self.status.lock().unwrap().last_error.is_empty();
        if run_check {
            self.set(|s| s.checking = true);
            if !check_only { Self::sleep_or_stop(&stop, 800).await; }
            self.run_macro(check).await;
            self.set(|s| s.check_end_ms = now_ms());
        }
        self.dev.borrow_mut().end().await;
        self.set(|s| { s.busy = false; s.checking = false; });
    }

    pub async fn stop_now(&self) -> serde_json::Value {
        self.cancel_generation.set(self.cancel_generation.get().wrapping_add(1));
        self.stop_and_join().await
    }

    async fn stop_and_join(&self) -> serde_json::Value {
        *self.stop.borrow_mut() = true;
        let Ok(_gate) = self.stop_gate.try_lock() else {
            return serde_json::json!({"ok": true, "stopped": false});
        };
        let h = self.task.borrow_mut().take();
        if let Some(mut h) = h {
            if tokio::time::timeout(Duration::from_secs(3), &mut h).await.is_err() {
                self.task.borrow_mut().replace(h);
                return serde_json::json!({"ok": true, "stopped": false});
            }
        }
        self.set(|s| { s.busy = false; s.checking = false; });
        serde_json::json!({"ok": true, "stopped": true})
    }

    /// Steps separated by ';' with normalised coordinates. R tries the status-bar return link, then PiP.
    pub async fn run_macro(&self, steps: &str) {
        let mut last_tile: Option<(u16, u16, u16)> = None;
        for st in steps.split(';').map(str::trim).filter(|s| !s.is_empty()) {
            if *self.stop.borrow() { break; }
            let mut it = st.split_whitespace();
            let op = it.next().unwrap_or("");
            if APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed) { break; }
            let a: Vec<i64> = it.filter_map(|v| v.parse::<f64>().ok().map(|f| f as i64)).collect();
            let u = |i: usize| a.get(i).copied().unwrap_or(0).clamp(0, FULL) as u16;
            match op {
                "T" => { let _ = self.dev.borrow_mut().tap(u(0), u(1)).await; }
                "D" => {
                    let ms = a.get(4).copied().unwrap_or(250).max(30) as u64;
                    let _ = self.dev.borrow_mut().drag(u(0), u(1), u(2), u(3), 12, ms / 12).await;
                }
                "W" => Self::sleep_or_stop(&self.stop, a.first().copied().unwrap_or(0).max(0) as u64).await,
                "G" => {
                    let mut saved = self.dev.borrow_mut().screen_anchor(0).await.is_some();
                    if !saved {
                        Self::sleep_or_stop(&self.stop, 400).await;
                        if *self.stop.borrow() || APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed) { break; }
                        saved = self.dev.borrow_mut().screen_anchor(0).await.is_some();
                    }
                    if !saved {
                        self.set(|s| { s.check_failed = true; s.last_error = "Could not verify the Saved grid".into(); });
                        break;
                    }
                }
                // A verifies the screen and taps at the observed anchor plus a row offset.
                "A" => {
                    let kind = u(0) as i32;
                    // Kind 3 performs the same Saved guard while collecting a
                    // shadow descriptor from this already-required frame.
                    let mut anchor = self.dev.borrow_mut().screen_anchor(if kind == 0 { 3 } else { kind }).await;
                    if *self.stop.borrow() || APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed) { break; }
                    if kind == 1 && anchor.is_none() {
                        log_tile_retry(1); // Share was not recognized.
                        if let Some((x, y, saved_anchor)) = last_tile {
                            let current = self.dev.borrow_mut().screen_anchor(0).await;
                            if *self.stop.borrow() || APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed) { break; }
                            if current.is_some_and(|now| now.abs_diff(saved_anchor) <= 200) {
                                log_tile_retry(2); // The same Saved geometry was recognized.
                                // An explicitly held, stationary contact is a
                                // bounded retry, not a scroll or long press.
                                if let Err(error) = self.dev.borrow_mut().drag(x, y, x, y, 3, 40).await {
                                    self.set(|s| { s.check_failed = true; s.last_error = error; });
                                    break;
                                }
                                Self::sleep_or_stop(&self.stop, 1800).await;
                                if *self.stop.borrow() || APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed) { break; }
                                anchor = self.dev.borrow_mut().screen_anchor(1).await;
                                log_tile_retry(if anchor.is_some() { 3 } else { 4 });
                                if *self.stop.borrow() || APP_IN_FRONT.load(std::sync::atomic::Ordering::Relaxed) { break; }
                            }
                        }
                    }
                    let Some(y) = anchor.and_then(|y| y.checked_add(u(2))).filter(|&y| y < 59000) else {
                        let error = match kind {
                            0 => "Could not verify a visible Saved tile",
                            1 => "Could not locate Share on the post",
                            _ => "Could not locate Copy link in the share sheet",
                        };
                        self.set(|s| { s.check_failed = true; s.last_error = error.into(); });
                        break;
                    };
                    if let Err(error) = self.dev.borrow_mut().tap(u(1), y).await {
                        self.set(|s| { s.check_failed = true; s.last_error = error; });
                        break;
                    }
                    if kind == 0 { last_tile = anchor.map(|base| (u(1), y, base)); }
                }
                "R" => {
                    use std::sync::atomic::Ordering::Relaxed;
                    let before = APP_ACTIVE_MS.load(Relaxed);
                    let _ = self.dev.borrow_mut().tap(u(0), u(1)).await;
                    Self::sleep_or_stop(&self.stop, 750).await;
                    if !*self.stop.borrow() && APP_ACTIVE_MS.load(Relaxed) == before {
                        let _ = self.dev.borrow_mut().tap(u(2), u(3)).await;
                        Self::sleep_or_stop(&self.stop, 800).await;
                        if !*self.stop.borrow() && APP_ACTIVE_MS.load(Relaxed) == before {
                            let _ = self.dev.borrow_mut().tap(u(4), u(5)).await;
                            Self::sleep_or_stop(&self.stop, 750).await;
                        }
                    }
                    self.set(|s| s.check_failed = APP_ACTIVE_MS.load(Relaxed) == before);
                }
                "S" => {
                    let (x1, y1, x2, y2, s, d) = swipe_gesture(self.swipe_x, self.swipe_y, a.first().copied().unwrap_or(400), a.get(1).copied().unwrap_or(180).max(30) as u64);
                    let _ = self.dev.borrow_mut().drag(x1, y1, x2, y2, s, d).await;
                }
                _ => {}
            }
        }
    }

    fn pair_open(&self) -> bool {
        let since_active = now_ms().saturating_sub(APP_ACTIVE_MS.load(std::sync::atomic::Ordering::Relaxed));
        self.started.elapsed() < PAIR_WINDOW || since_active < PAIR_WINDOW.as_millis() as u64
    }

    /// Handle one API call. `q` = query parameters, `token` = X-Token header (or ?t=).
    pub async fn handle(self: &Rc<Self>, path: &str, q: &HashMap<String, String>, token: &str) -> (u16, serde_json::Value) {
        if path == "/pair" {
            return if self.pair_open() {
                (200, serde_json::json!({"ok": true, "token": self.token, "version": VERSION}))
            } else {
                (403, serde_json::json!({"ok": false, "error": "pairing closed: open the Saved Scroll app for a second, then try again within 3 minutes"}))
            };
        }
        let tok = q.get("t").map(String::as_str).unwrap_or(token);
        if tok != self.token { return (401, serde_json::json!({"ok": false, "error": "bad token"})); }
        let num = |k: &str, d: i64| q.get(k).and_then(|v| v.parse::<f64>().ok()).map(|f| f as i64).unwrap_or(d);
        let busy = self.status.lock().unwrap().busy;
        match path {
            "/status" => (200, self.status_json()),
            "/dive" if busy && num("idle", 0) == 1 => (200, serde_json::json!({"ok": false, "error": "busy"})),
            "/dive" => (200, {
                let Ok(_gate) = self.motion_gate.try_lock() else {
                    return (200, serde_json::json!({"ok": false, "error": "busy"}));
                };
                let check = if num("check", 1) == 0 { String::new() } else {
                    match num("row", 0) {
                        r @ 1..=8 => self.alternate_checks.borrow()[(r - 1) as usize].clone(),
                        _ => self.check_macro.borrow().clone(),
                    }
                };
                self.dive(num("n", 10).clamp(0, 2000) as u32, num("iv", 1000).clamp(150, 10000) as u64, num("dy", 400).clamp(-2000, 2000),
                                     num("dur", 180).clamp(40, 2000) as u64, num("pn", 0).clamp(0, 2000) as u32, num("piv", 700).clamp(150, 10000) as u64,
                                     num("pdy", -400).clamp(-2000, 2000), check, num("guard", 0) == 1).await }),
            "/stop" => (200, self.stop_now().await),
            "/swipe" => {
                if busy { return (200, serde_json::json!({"ok": false, "error": "busy: stop the dive first"})); }
                let Ok(_gate) = self.motion_gate.try_lock() else {
                    return (200, serde_json::json!({"ok": false, "error": "busy"}));
                };
                if let Err(e) = self.dev.borrow_mut().connect().await { return (200, serde_json::json!({"ok": false, "error": e})); }
                let (x1, y1, x2, y2, s, d) = swipe_gesture(self.swipe_x, self.swipe_y, num("dy", 400), num("dur", 180).max(40) as u64);
                let mut dev = self.dev.borrow_mut();
                let r = async { dev.begin().await?; let r = dev.drag(x1, y1, x2, y2, s, d).await; dev.end().await; r }.await;
                (200, serde_json::json!({"ok": r.is_ok(), "error": r.err()}))
            }
            "/macro" => {
                let s = q.get("s").cloned().unwrap_or_default();
                if q.get("save").map(String::as_str) == Some("check") && !s.is_empty() {
                    *self.check_macro.borrow_mut() = s;
                    return (200, serde_json::json!({"ok": true, "saved": "check"}));
                }
                if let Some(row) = q.get("save").and_then(|v| v.strip_prefix("check")).and_then(|v| v.parse::<usize>().ok()) {
                    if (1..=8).contains(&row) && !s.is_empty() {
                        self.alternate_checks.borrow_mut()[row - 1] = s;
                        return (200, serde_json::json!({"ok": true}));
                    }
                }
                if busy { return (200, serde_json::json!({"ok": false, "error": "busy"})); }
                let Ok(_gate) = self.motion_gate.try_lock() else {
                    return (200, serde_json::json!({"ok": false, "error": "busy"}));
                };
                let m = if s.is_empty() { self.check_macro.borrow().clone() } else { s };
                *self.stop.borrow_mut() = false;
                if let Err(e) = self.dev.borrow_mut().connect().await { return (200, serde_json::json!({"ok": false, "error": e})); }
                if let Err(e) = self.dev.borrow_mut().begin().await { return (200, serde_json::json!({"ok": false, "error": e})); }
                self.run_macro(&m).await;
                self.dev.borrow_mut().end().await;
                (200, serde_json::json!({"ok": true}))
            }
            "/checkmacros" => {
                let rows: Option<Vec<String>> = (0..9)
                    .map(|i| q.get(&format!("row{i}")).filter(|s| !s.is_empty()).cloned())
                    .collect();
                let Some(mut rows) = rows else {
                    return (200, serde_json::json!({"ok": false, "error": "missing check probe"}));
                };
                let first = rows.remove(0);
                let alternate: [String; 8] = rows.try_into().expect("validated nine probes");
                *self.check_macro.borrow_mut() = first;
                *self.alternate_checks.borrow_mut() = alternate;
                *self.auto_check.borrow_mut() = num("on", 0) == 1;
                (200, self.status_json())
            }
            "/autocheck" => { *self.auto_check.borrow_mut() = num("on", 0) != 0; (200, self.status_json()) }
            _ => (404, serde_json::json!({"ok": false, "error": "not found"})),
        }
    }

    /// Minimal HTTP/1.1 server (GET only, one request per connection), bound to 127.0.0.1.
    pub async fn serve(self: Rc<Self>, port: u16) -> std::io::Result<()> {
        let listener = TcpListener::bind(("127.0.0.1", port)).await?;
        loop {
            let (mut sock, _) = listener.accept().await?;
            let me = self.clone();
            tokio::task::spawn_local(async move {
                let mut buf = vec![0u8; 8192];
                let mut len = 0;
                while len < buf.len() {
                    match sock.read(&mut buf[len..]).await { Ok(0) | Err(_) => break, Ok(n) => len += n }
                    if buf[..len].windows(4).any(|w| w == b"\r\n\r\n") { break; }
                }
                let req = String::from_utf8_lossy(&buf[..len]).to_string();
                let (path, q, token) = parse_request(&req);
                let (code, body) = me.handle(&path, &q, &token).await;
                let body = body.to_string();
                let reason = match code { 200 => "OK", 401 => "Unauthorized", 403 => "Forbidden", _ => "Not Found" };
                let resp = format!("HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            });
        }
    }
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => { out.push(b' '); i += 1; }
            b'%' if i + 2 < b.len() => {
                match u8::from_str_radix(&s[i + 1..i + 3], 16) { Ok(v) => { out.push(v); i += 3; } Err(_) => { out.push(b'%'); i += 1; } }
            }
            c => { out.push(c); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

/// Returns (path, query params, X-Token header).
pub fn parse_request(req: &str) -> (String, HashMap<String, String>, String) {
    let first = req.lines().next().unwrap_or("");
    let target = first.split_whitespace().nth(1).unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let q = query.split('&').filter(|p| !p.is_empty()).map(|p| {
        let (k, v) = p.split_once('=').unwrap_or((p, ""));
        (pct_decode(k), pct_decode(v))
    }).collect();
    let token = req.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        if k.trim().eq_ignore_ascii_case("x-token") { Some(v.trim().to_string()) } else { None }
    }).unwrap_or_default();
    (path.to_string(), q, token)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(pairs: &[(&str, &str)]) -> HashMap<String, String> { pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect() }

    fn run<F: std::future::Future>(f: F) -> F::Output {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        tokio::task::LocalSet::new().block_on(&rt, f)
    }

    #[test]
    fn parses_requests() {
        let (p, qs, t) = parse_request("GET /macro?s=T%2010%2020%3BW%2050&save=check HTTP/1.1\r\nHost: x\r\nX-Token: abc\r\n\r\n");
        assert_eq!(p, "/macro");
        assert_eq!(qs["s"], "T 10 20;W 50");
        assert_eq!(qs["save"], "check");
        assert_eq!(t, "abc");
    }

    #[test]
    fn swipe_geometry() {
        let (x1, y1, x2, y2, _, _) = swipe_gesture(32767, 47185, 400, 180);
        assert_eq!(x1, x2);
        assert!(y1 > y2, "finger up = scroll down");
        assert!(((y1 - y2) as f64 / 65535.0 - 0.4).abs() < 0.01);
        let (_, u1, _, u2, _, _) = swipe_gesture(32767, 47185, -400, 180);
        assert!(u1 < u2, "negative dy scrolls back up");
    }

    #[test]
    fn auth_pairing_and_unknown() {
        run(async {
            let e = Engine::new(MockDevice::new(), Some("tok".into()));
            assert_eq!(e.handle("/pair", &q(&[]), "").await.1["token"], "tok");
            assert_eq!(e.handle("/status", &q(&[]), "nope").await.0, 401);
            assert_eq!(e.handle("/status", &q(&[("t", "tok")]), "").await.0, 200);
            assert_eq!(e.handle("/nope", &q(&[]), "tok").await.0, 404);
        });
    }

    #[test]
    fn dive_progress_stop_and_one_session() {
        run(async {
            let e = Engine::new(MockDevice::new(), Some("tok".into()));
            let r = e.handle("/dive", &q(&[("n", "40"), ("iv", "150"), ("dur", "60")]), "tok").await.1;
            assert_eq!(r["ok"], true);
            tokio::time::sleep(Duration::from_millis(500)).await;
            let s = e.handle("/status", &q(&[]), "tok").await.1;
            assert_eq!(s["busy"], true);
            assert!(s["done"].as_u64().unwrap() >= 1);
            assert_eq!(e.handle("/stop", &q(&[]), "tok").await.1["stopped"], true);
            let d1 = e.status_json()["done"].as_u64().unwrap();
            tokio::time::sleep(Duration::from_millis(400)).await;
            assert_eq!(e.status_json()["done"].as_u64().unwrap(), d1, "nothing after stop");
            assert!(d1 < 40);
            assert_eq!(e.dev.borrow().sessions, 1);
        });
    }

    #[test]
    fn two_phase_then_saved_check_macro() {
        run(async {
            let e = Engine::new(MockDevice::new(), Some("tok".into()));
            e.handle("/macro", &q(&[("s", "T 100 200;W 20;T 300 400"), ("save", "check")]), "tok").await;
            e.handle("/autocheck", &q(&[("on", "1")]), "tok").await;
            e.handle("/dive", &q(&[("n", "2"), ("iv", "150"), ("dur", "40"), ("pn", "1"), ("piv", "150")]), "tok").await;
            for _ in 0..80 {
                tokio::time::sleep(Duration::from_millis(50)).await;
                let s = e.status_json();
                if s["busy"] == false && s["checking"] == false { break; }
            }
            let log = e.dev.borrow().log.clone();
            let drags: Vec<_> = log.iter().filter(|l| l.starts_with("drag")).collect();
            assert_eq!(drags.len(), 3);
            let first: Vec<i64> = drags[0].split_whitespace().skip(1).map(|v| v.parse().unwrap()).collect();
            assert!(first[1] < first[3], "phase 1 goes back up");
            assert_eq!(log.iter().filter(|l| l.starts_with("tap")).cloned().collect::<Vec<_>>(), vec!["tap 100 200", "tap 300 400"]);
        });
    }

    #[test]
    fn nudge_with_check_0_skips_the_check_macro() {
        run(async {
            let e = Engine::new(MockDevice::new(), Some("tok".into()));
            e.handle("/macro", &q(&[("s", "T 100 200"), ("save", "check")]), "tok").await;
            e.handle("/autocheck", &q(&[("on", "1")]), "tok").await;
            e.handle("/dive", &q(&[("n", "2"), ("iv", "150"), ("dur", "40"), ("check", "0")]), "tok").await;
            for _ in 0..80 {
                tokio::time::sleep(Duration::from_millis(50)).await;
                let s = e.status_json();
                if s["busy"] == false && s["checking"] == false { break; }
            }
            let log = e.dev.borrow().log.clone();
            assert_eq!(log.iter().filter(|l| l.starts_with("drag")).count(), 2);
            assert_eq!(log.iter().filter(|l| l.starts_with("tap")).count(), 0, "no check after a nudge");
        });
    }

    #[test]
    fn guarded_dive_never_touches_an_unverified_screen() {
        run(async {
            let mut device = MockDevice::new();
            device.off_grid = true;
            let e = Engine::new(device, Some("tok".into()));
            e.handle("/dive", &q(&[("n", "2"), ("guard", "1")]), "tok").await;
            tokio::task::yield_now().await;
            assert_eq!(e.status_json()["busy"], false);
            assert_eq!(e.status_json()["done"], 0);
            assert_eq!(e.status_json()["error"], "Open TikTok's Saved grid");
            assert!(e.dev.borrow().log.is_empty());
            assert_eq!(e.dev.borrow().sessions, 0);
        });
    }

    #[test]
    fn macro_grid_guard_skips_tile_and_share_taps() {
        run(async {
            let mut device = MockDevice::new();
            device.off_grid = true;
            let e = Engine::new(device, Some("tok".into()));
            e.run_macro("G;T 100 200;R 101 201 301 401 501 601").await;
            assert!(e.dev.borrow().log.is_empty());
            assert_eq!(e.status_json()["error"], "Could not verify the Saved grid");
        });
    }

    #[test]
    fn check_only_dive_uses_the_macro_guard_before_any_tap() {
        run(async {
            let mut device = MockDevice::new();
            device.off_grid = true;
            let e = Engine::new(device, Some("tok".into()));
            *e.auto_check.borrow_mut() = true;
            e.run_dive(0, 1000, 400, 180, 0, 1000, 400, "W 1;A 0 100 200;T 300 400", true).await;
            assert!(e.dev.borrow().log.is_empty());
            assert_eq!(e.status_json()["error"], "Could not verify a visible Saved tile");
        });
    }

    #[test]
    fn return_guard_allows_one_delayed_saved_frame() {
        run(async {
            let mut device = MockDevice::new();
            device.miss_grid_once = true;
            let e = Engine::new(device, Some("tok".into()));
            e.run_macro("G;T 100 200").await;
            assert_eq!(e.dev.borrow().log, ["tap 100 200"]);
            assert_eq!(e.status_json()["checkFailed"], false);
        });
    }

    #[test]
    fn macro_stops_before_copy_and_return_if_share_sheet_is_unverified() {
        run(async {
            let mut device = MockDevice::new();
            device.missing_anchor = Some(2);
            let e = Engine::new(device, Some("tok".into()));
            e.run_macro("A 0 100 200;A 1 300 0;A 2 500 0;D 2 20 850 20 300;R 101 201 301 401 501 601").await;
            assert_eq!(e.dev.borrow().log, ["tap 100 201", "tap 300 1"]);
            assert_eq!(e.status_json()["checkFailed"], true);
        });
    }

    #[test]
    fn unopened_tile_is_retried_once_only_on_the_same_verified_grid() {
        run(async {
            let mut device = MockDevice::new();
            device.miss_share_once = true;
            let e = Engine::new(device, Some("tok".into()));
            e.run_macro("A 0 100 200;A 1 300 0").await;
            assert_eq!(e.dev.borrow().log, ["tap 100 201", "drag 100 201 100 201 3 40", "tap 300 1"]);
            assert_eq!(e.status_json()["checkFailed"], false);
        });
    }

    #[test]
    fn missing_share_never_retries_a_tile_without_a_verified_grid() {
        run(async {
            let mut device = MockDevice::new();
            device.miss_share_once = true;
            device.off_grid_after_first_tap = true;
            let e = Engine::new(device, Some("tok".into()));
            e.run_macro("A 0 100 200;A 1 300 0").await;
            assert_eq!(e.dev.borrow().log, ["tap 100 201"]);
            assert_eq!(e.status_json()["checkFailed"], true);
        });
    }

    #[test]
    fn stop_cancels_a_start_even_if_connect_is_still_pending() {
        run(async {
            let mut device = MockDevice::new();
            device.connect_ms = 90;
            let e = Engine::new(device, Some("tok".into()));
            let first = e.clone();
            let pending = tokio::task::spawn_local(async move {
                first.handle("/dive", &q(&[("n", "2"), ("idle", "1")]), "tok").await.1
            });
            tokio::time::sleep(Duration::from_millis(10)).await;
            let repeat = e.handle("/dive", &q(&[("n", "2"), ("idle", "1")]), "tok").await.1;
            assert_eq!(repeat["error"], "busy");
            e.stop_now().await;
            assert_eq!(pending.await.unwrap()["error"], "start cancelled");
            assert_eq!(e.dev.borrow().sessions, 0);
            assert!(e.dev.borrow().log.is_empty());
        });
    }

    #[test]
    fn macro_returns_through_the_status_link_or_uses_the_window_as_fallback() {
        run(async {
            let mut device = MockDevice::new();
            device.activate_on_tap = Some((101, 201));
            let e = Engine::new(device, Some("tok".into()));
            let macro_text = "R 101 201 301 401 501 601";
            e.run_macro(macro_text).await;
            assert_eq!(e.dev.borrow().log, ["tap 101 201"]);
            assert_eq!(e.status_json()["checkFailed"], false);
            {
                let mut device = e.dev.borrow_mut();
                device.log.clear();
                device.activate_on_tap = Some((501, 601));
            }
            e.run_macro(macro_text).await;
            assert_eq!(e.dev.borrow().log, ["tap 101 201", "tap 301 401", "tap 501 601"]);
            assert_eq!(e.status_json()["checkFailed"], false);
        });
    }
}
