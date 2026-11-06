//! ssprobe: run the app's real phone layer (phone.rs) from the laptop against the iPhone over Wi-Fi, so
//! engine fixes can be checked without an iPhone build or the user's time.
//!
//!   ssprobe <ip:port> <rp_pairing_file.plist> [tap|swipe]
//!
//! <ip:port>: the phone's `_remotepairing._tcp` service (browse with zeroconf; e.g. 192.168.1.20:49152).
//! Same steps the app does through LocalDevVPN (10.7.0.1): pair-verify → tunnel → disk image → touch session.
//! `tap` taps the status bar (harmless); `swipe` does one short scroll-down swipe in the middle.

use ssengine::{phone::PhoneDevice, Device};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: ssprobe <ip:port> <rp_pairing_file.plist> [tap|swipe]");
        std::process::exit(2);
    }
    let addr: std::net::SocketAddr = args[1].parse().expect("ip:port");
    let action = args.get(3).cloned().unwrap_or_default();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let local = tokio::task::LocalSet::new();
    let ok = local.block_on(&rt, async move {
        let mut d = PhoneDevice::new(&args[2], Some(addr));
        let t = std::time::Instant::now();
        match d.connect().await {
            Ok(()) => println!("1. tunnel: OK ({} ms){}", t.elapsed().as_millis(),
                               if d.ddi_note.is_empty() { String::new() } else { format!("  [disk image: {}]", d.ddi_note) }),
            Err(e) => { println!("1. tunnel: FAILED: {e}"); return false; }
        }
        let t = std::time::Instant::now();
        match d.begin().await {
            Ok(()) => println!("2. touch session: OK ({} ms)", t.elapsed().as_millis()),
            Err(e) => { println!("2. touch session: FAILED: {e}"); return false; }
        }
        let r = match action.as_str() {
            "tap" => d.tap(32768, 1500).await.map(|_| "3. tap status bar: OK"),
            "swipe" => d.drag(32768, 47185, 32768, 21000, 12, 15).await.map(|_| "3. swipe: OK"),
            _ => Ok("3. (no touch requested)"),
        };
        d.end().await;
        match r { Ok(m) => { println!("{m}"); true } Err(e) => { println!("3. touch: FAILED: {e}"); false } }
    });
    std::process::exit(if ok { 0 } else { 1 });
}
