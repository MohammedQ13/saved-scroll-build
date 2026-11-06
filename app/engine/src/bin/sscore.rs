//! sscore: the laptop side of Saved Scroll's signing (Windows/macOS/Linux, USB or Wi-Fi).
//!
//!   sscore install <app.ipa> <storage_dir>                                   (USB)
//!   sscore install <app.ipa> <storage_dir> wifi=IP:PORT pairing=FILE         (Wi-Fi, no cable)
//!
//! Wi-Fi: IP:PORT is the phone's `_remotepairing._tcp` service, FILE the RemotePairing record
//! (`lab/rp_pairing_file.plist`, host name `saved-scroll`). Prints `SSCORE_OK <bundle id>` at the end.
//!
//! Signs with the user's free Apple ID exactly like the phone's self-refresh does (same library, same
//! certificate name, bundle id `com.savedscroll.engine.<team>`), and installs over USB. `storage_dir` keeps
//! the Apple login identity and the certificate; `sslab app install` then copies it into the app, so the
//! phone's own refreshes reuse the same certificate and identity (no second 2FA, no second certificate).
//! The Apple ID, password and 2FA code are typed here by the user; the password can be kept in Windows
//! Credential Manager (asked once) so later installs need no typing.

use std::io::{BufRead, Write};
use std::path::PathBuf;

use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::developer_session::DeveloperSession,
    sideload::{
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
        SideloaderBuilder, TeamSelection,
    },
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
        fs_storage::FsStorage,
    },
};

fn ask(prompt: &str) -> String {
    print!("{prompt}");
    std::io::stdout().flush().ok();
    let mut s = String::new();
    std::io::stdin().lock().read_line(&mut s).ok();
    s.trim().to_string()
}

async fn two_factor(p: TwoFactorCallbackParams) -> Result<TwoFactorCallbackResponse, rootcause::Report> {
    if let Some(e) = &p.last_error { println!("({e})"); }
    let code = ask(if p.sms { "Code Apple texted you: " } else { "Code shown on your Apple devices: " });
    Ok(if code.is_empty() { TwoFactorCallbackResponse::Abort } else { TwoFactorCallbackResponse::SubmitCode(code) })
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 6 && args[1] == "push" {
        // sscore push <bundle id> <local file> <path under Documents> wifi=IP:PORT pairing=FILE  (no Apple sign-in)
        let opt = |k: &str| args.iter().skip(5).find_map(|a| a.strip_prefix(&format!("{k}=")).map(str::to_string));
        let (Some(addr), Some(pairing)) = (opt("wifi"), opt("pairing")) else {
            eprintln!("usage: sscore push <bundle id> <local file> <path> wifi=IP:PORT pairing=FILE");
            std::process::exit(2);
        };
        let _ = rustls::crypto::ring::default_provider().install_default();
        let bytes = std::fs::read(&args[3]).expect("read local file");
        match ssengine::refresh::push_documents(&pairing, addr.parse().expect("wifi=IP:PORT"), &args[2], &[(args[4].clone(), bytes)]).await {
            Ok(_) => println!("pushed {} to Documents/{}", args[3], args[4]),
            Err(e) => { eprintln!("push failed: {e}"); std::process::exit(1); }
        }
        return;
    }
    if args.len() >= 6 && args[1] == "pull" {
        // sscore pull <bundle id> <path under Documents> <out file> wifi=IP:PORT pairing=FILE  (no Apple sign-in)
        let opt = |k: &str| args.iter().skip(5).find_map(|a| a.strip_prefix(&format!("{k}=")).map(str::to_string));
        let (Some(addr), Some(pairing)) = (opt("wifi"), opt("pairing")) else {
            eprintln!("usage: sscore pull <bundle id> <path> <out> wifi=IP:PORT pairing=FILE");
            std::process::exit(2);
        };
        let _ = rustls::crypto::ring::default_provider().install_default();
        match ssengine::refresh::pull_document(&pairing, addr.parse().expect("wifi=IP:PORT"), &args[2], &args[3]).await {
            Ok(b) => { std::fs::write(&args[4], &b).expect("write out"); println!("pulled {} bytes", b.len()); }
            Err(e) => { eprintln!("pull failed: {e}"); std::process::exit(1); }
        }
        return;
    }
    if args.len() < 4 || args[1] != "install" {
        eprintln!("usage: sscore install <app.ipa> <storage_dir> [wifi=IP:PORT pairing=rp_pairing_file.plist]");
        std::process::exit(2);
    }
    let opt = |k: &str| args.iter().skip(4).find_map(|a| a.strip_prefix(&format!("{k}=")).map(str::to_string));
    let (ipa, storage) = (PathBuf::from(&args[2]), PathBuf::from(&args[3]));
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    std::fs::create_dir_all(&storage).expect("storage dir");

    // The email from the last install, and (if the user chose) the password from Windows Credential Manager,
    // so reinstalls need no typing. Typed values are only kept if the user says so.
    let saved_email = std::fs::read_to_string(storage.join("account.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
        .and_then(|v| v.get("email").and_then(|e| e.as_str()).map(str::to_string))
        .unwrap_or_default();
    let email = if saved_email.is_empty() {
        println!("Saved Scroll: sign in with the free Apple ID to sign the app.");
        ask("Apple ID email: ")
    } else {
        println!("Saved Scroll: signing with {saved_email}");
        saved_email
    };
    let entry = keyring::Entry::new("Saved Scroll (sscore)", &email).ok();
    let remembered = entry.as_ref().and_then(|e| e.get_password().ok()).filter(|p| !p.is_empty());
    let (password, from_store) = match remembered {
        Some(p) => { println!("Using the password saved in Windows Credential Manager."); (p, true) }
        None => (rpassword::prompt_password("Apple ID password (hidden): ").unwrap_or_default(), false),
    };

    let anisette = RemoteV3AnisetteProvider::default()
        .expect("anisette")
        .set_storage(Box::new(FsStorage::new(storage.clone())));
    let mut account = match AppleAccount::builder(&email).anisette_provider(anisette).login(&password, two_factor).await {
        Ok(a) => a,
        Err(e) => {
            if from_store { if let Some(en) = &entry { let _ = en.delete_credential(); } }
            eprintln!("Sign-in failed: {e}");
            std::process::exit(1);
        }
    };
    if !from_store {
        if let Some(en) = &entry {
            let a = ask("Save the password in Windows Credential Manager so future installs need no typing? [Y/n]: ");
            if !a.to_lowercase().starts_with('n') && en.set_password(&password).is_ok() {
                println!("Saved. (Remove it any time: Control Panel › Credential Manager › Windows Credentials.)");
            }
        }
    }
    let session = DeveloperSession::from_account(&mut account).await.expect("developer session");

    if let (Some(addr), Some(pairing)) = (opt("wifi"), opt("pairing")) {
        // Wi-Fi (HANDOFF Task H): the same tunnel and code path as the phone's own renewal, pointed at the
        // phone's `_remotepairing._tcp` address instead of the LocalDevVPN loopback. Then hand the signing
        // data to the app over the same kind of tunnel (house_arrest), like `sslab app install` does over USB.
        let addr: std::net::SocketAddr = addr.parse().expect("wifi=IP:PORT");
        println!("Signing and installing over Wi-Fi ({addr})...");
        let last = std::sync::atomic::AtomicU64::new(0);
        let bid = match ssengine::refresh::sign_and_install(session, &email, &storage, &ipa, "com.savedscroll.engine", &pairing, addr,
            |stage, p| {
                if stage == "installing" && p >= last.load(std::sync::atomic::Ordering::Relaxed) + 25 {
                    last.store(p, std::sync::atomic::Ordering::Relaxed);
                    println!("  installing {p}%");
                }
            }).await {
            Ok(b) => b,
            Err(e) => { eprintln!("Install failed: {e}"); std::process::exit(1); }
        };
        std::fs::write(storage.join("account.json"), serde_json::json!({"email": email}).to_string()).ok();
        let mut files = Vec::new();
        let mut stack = vec![storage.clone()];
        while let Some(dir) = stack.pop() {
            for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                let p = e.path();
                if p.is_dir() { stack.push(p); continue; }
                let rel = p.strip_prefix(&storage).unwrap().to_string_lossy().replace('\\', "/");
                if let Ok(b) = std::fs::read(&p) { files.push((format!(".signing/{rel}"), b)); }
            }
        }
        match ssengine::refresh::push_documents(&pairing, addr, &bid, &files).await {
            Ok(n) => println!("Installed {bid}; {n} signing files handed to the app. You can close this window."),
            Err(e) => { eprintln!("Installed {bid}, but handing the signing files over failed: {e}"); std::process::exit(3); }
        }
        println!("SSCORE_OK {bid}");
        return;
    }

    let mut mux = UsbmuxdConnection::default().await.expect("Apple Mobile Device service (install the Apple Devices app)");
    let dev = mux.get_devices().await.expect("devices").into_iter().next().expect("No iPhone on USB: plug it in, unlock it, tap Trust.");
    let provider = dev.to_provider(UsbmuxdAddr::default(), "saved-scroll");

    let mut sideloader = SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(session, email.clone())
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Revoke)
        .extensions_behavior(ExtensionsBehaviorSelection::Fixed(ExtensionsBehavior::ReuseMain))
        .storage(Box::new(FsStorage::new(storage.clone())))
        .machine_name(ssengine::refresh::MACHINE_NAME.to_string())
        .build();
    println!("Signing and installing...");
    match sideloader.install_app(&provider, ipa, false, None::<fn(f32) -> std::future::Ready<()>>, None).await {
        Ok(_) => {
            std::fs::write(storage.join("account.json"), serde_json::json!({"email": email}).to_string()).ok();
            println!("Installed. You can close this window.");
        }
        Err(e) => { eprintln!("Install failed: {e}"); std::process::exit(1); }
    }
}
