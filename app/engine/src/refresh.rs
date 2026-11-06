//! Self-refresh: keeps the free 7-day signing from ever running out, with no computer and no taps.
//!
//! Free Apple ID signing lasts 7 days. This re-signs the app with the user's Apple ID (isideload, MIT)
//! and reinstalls it over the phone's own CoreDevice tunnel (the same LocalDevVPN loopback the touch
//! engine uses). The Apple login identity ("anisette" machine state) and the signing certificate are kept
//! in `storage_dir`, so after the first sign-in (one 2FA code) later refreshes log in with the saved
//! password and need nothing from the user. iOS closes the app when the new copy installs.
//!
//!   char *ss_refresh_start(const char *json);   // {"email","password","storage_dir","app_path","pairing_path","bundle_base"}
//!   void  ss_refresh_submit_code(const char *code);
//!   char *ss_refresh_status(void);              // {"state","progress","error","detail"}
//!
//! `app_path`: an .ipa (e.g. a newer build downloaded from the repo's releases) or this app's own bundle.
//! `bundle_base`: the bundle id before signing (com.savedscroll.engine); signing appends the team id,
//! which must match the installed copy so the install updates it in place.

use std::ffi::{c_char, CStr};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use idevice::RsdService;
use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{developer_session::DeveloperSession, device_type::DeveloperDeviceType, devices::DevicesApi},
    sideload::{
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
        install::install_app_rsd,
        SideloaderBuilder, TeamSelection,
    },
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
        fs_storage::FsStorage,
    },
};

/// The certificate's name in the Apple account (one cert, reused every week).
pub const MACHINE_NAME: &str = "Saved Scroll";

#[derive(Clone, Debug, Default)]
pub struct RefreshState {
    pub state: String, // idle | login | need_code | signing | installing | done | failed
    pub progress: u64,
    pub error: String,
    pub detail: String,
}

fn cell() -> &'static Mutex<RefreshState> {
    static S: OnceLock<Mutex<RefreshState>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(RefreshState { state: "idle".into(), ..Default::default() }))
}
fn set(f: impl FnOnce(&mut RefreshState)) {
    f(&mut cell().lock().unwrap());
}
pub fn state() -> RefreshState {
    cell().lock().unwrap().clone()
}
fn code_slot() -> &'static Mutex<Option<String>> {
    static C: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(None))
}

#[derive(Clone, Debug)]
pub struct Config {
    pub email: String,
    pub password: String,
    pub storage_dir: PathBuf,
    pub app_path: PathBuf,
    pub pairing_path: String,
    pub bundle_base: String,
}

impl Config {
    fn from_json(v: &serde_json::Value) -> Result<Self, String> {
        let s = |k: &str| v.get(k).and_then(|x| x.as_str()).map(str::to_string).filter(|x| !x.is_empty()).ok_or(format!("missing {k}"));
        Ok(Self {
            email: s("email")?,
            password: s("password")?,
            storage_dir: PathBuf::from(s("storage_dir")?),
            app_path: PathBuf::from(s("app_path")?),
            pairing_path: s("pairing_path")?,
            bundle_base: s("bundle_base").unwrap_or_else(|_| "com.savedscroll.engine".into()),
        })
    }
}

/// Copies an .app bundle and resets its bundle id, so signing yields `<base>.<team>` again (re-signing the
/// installed copy as-is would give `<base>.<team>.<team>` and install a second app).
pub fn prepare_bundle(app: &Path, bundle_base: &str, work: &Path) -> Result<PathBuf, String> {
    if app.is_file() {
        return Ok(app.to_path_buf()); // an .ipa from CI is already unsigned with the base id
    }
    let name = app.file_name().ok_or("bad app path")?;
    let dest = work.join("Payload").join(name);
    let _ = std::fs::remove_dir_all(work.join("Payload"));
    copy_dir(app, &dest).map_err(|e| format!("copy app: {e}"))?;
    let info = dest.join("Info.plist");
    let mut dict: plist::Dictionary = plist::from_file(&info).map_err(|e| format!("read Info.plist: {e}"))?;
    dict.insert("CFBundleIdentifier".into(), plist::Value::String(bundle_base.into()));
    plist::to_file_xml(&info, &dict).map_err(|e| format!("write Info.plist: {e}"))?;
    for stale in ["_CodeSignature", "embedded.mobileprovision"] {
        let p = dest.join(stale);
        let _ = if p.is_dir() { std::fs::remove_dir_all(p) } else { std::fs::remove_file(p) };
    }
    Ok(dest)
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() { copy_dir(&entry.path(), &target)?; } else { std::fs::copy(entry.path(), target)?; }
    }
    Ok(())
}

/// The 2FA callback: shows "need_code" and waits (up to 10 min) for the app to submit the code.
async fn wait_for_code(p: TwoFactorCallbackParams) -> Result<TwoFactorCallbackResponse, rootcause::Report> {
    set(|s| {
        s.state = "need_code".into();
        s.detail = if p.sms { "Apple texted you a code.".into() } else { "Apple sent a code to your devices.".into() };
        if let Some(e) = &p.last_error { s.error = e.clone(); }
    });
    for _ in 0..1200 {
        let got = code_slot().lock().unwrap().take();
        if let Some(code) = got {
            set(|s| { s.state = "login".into(); s.error.clear(); });
            return Ok(TwoFactorCallbackResponse::SubmitCode(code));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    Ok(TwoFactorCallbackResponse::Abort)
}

/// Logs in, signs and installs. Runs on its own thread with a multi-thread runtime.
pub async fn run(cfg: Config) -> Result<(), String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    let report = |what: &'static str| move |e: rootcause::Report| format!("{what}: {e}");
    std::fs::create_dir_all(&cfg.storage_dir).map_err(|e| format!("storage: {e}"))?;

    set(|s| { s.state = "login".into(); s.progress = 5; });
    let anisette = RemoteV3AnisetteProvider::default()
        .map_err(report("anisette"))?
        .set_storage(Box::new(FsStorage::new(cfg.storage_dir.clone())));
    let mut account = AppleAccount::builder(&cfg.email)
        .anisette_provider(anisette)
        .login(&cfg.password, wait_for_code)
        .await
        .map_err(report("Apple ID sign-in"))?;
    let session = DeveloperSession::from_account(&mut account).await.map_err(report("developer session"))?;

    set(|s| { s.state = "signing".into(); s.progress = 20; });
    let storage = cfg.storage_dir.clone();
    sign_and_install(session, &cfg.email, &cfg.storage_dir, &cfg.app_path, &cfg.bundle_base, &cfg.pairing_path,
                     crate::phone::default_addr(), move |stage, p| {
        if stage == "installing" && p == 0 {
            // Remember when, in case iOS closes us mid-install (it does when the new copy lands).
            let stamp = serde_json::json!({"installing_at": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)});
            let _ = std::fs::write(storage.join("last_refresh.json"), stamp.to_string());
        }
        match stage {
            "signing" => set(|s| s.progress = 20 + p * 30 / 100),
            _ => set(|s| { s.state = "installing".into(); s.progress = 50 + p / 2; }),
        }
    })
    .await
    .map(|_| ())
}

/// Signs `app_path` for the phone behind `addr` and installs it over a CoreDevice tunnel opened with the
/// RemotePairing record at `pairing_path`. On the phone `addr` is the LocalDevVPN loopback (10.7.0.1); from the
/// laptop it's the phone's Wi-Fi `_remotepairing._tcp` address (sscore, HANDOFF Task H). Same certificate and
/// login identity either way (`storage_dir`). `progress(stage, 0..=100)` with stage "signing" or "installing".
/// Returns the installed bundle id.
#[allow(clippy::too_many_arguments)]
pub async fn sign_and_install(
    session: DeveloperSession,
    email: &str,
    storage_dir: &Path,
    app_path: &Path,
    bundle_base: &str,
    pairing_path: &str,
    addr: std::net::SocketAddr,
    progress: impl Fn(&'static str, u64) + Send + Sync,
) -> Result<String, String> {
    let report = |what: &'static str| move |e: rootcause::Report| format!("{what}: {e}");
    let (mut adapter, mut hs, _) = crate::phone::open_tunnel(pairing_path, addr).await?;
    let mut ld = idevice::lockdown::LockdownClient::connect_rsd(&mut adapter, &mut hs)
        .await
        .map_err(|e| format!("lockdown: {e:?}"))?;
    let value = |v: Result<plist::Value, idevice::IdeviceError>| v.ok().and_then(|x| x.as_string().map(str::to_string)).unwrap_or_default();
    let udid = value(ld.get_value(Some("UniqueDeviceID"), None).await);
    let name = value(ld.get_value(Some("DeviceName"), None).await);
    if udid.is_empty() {
        return Err("couldn't read this iPhone's UDID".into());
    }

    let mut sideloader = SideloaderBuilder::<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>::new(session, email.to_string())
        .team_selection(TeamSelection::First)
        .max_certs_behavior(MaxCertsBehavior::Revoke)
        .extensions_behavior(ExtensionsBehaviorSelection::Fixed(ExtensionsBehavior::ReuseMain))
        .storage(Box::new(FsStorage::new(storage_dir.to_path_buf())))
        .machine_name(MACHINE_NAME.to_string())
        .delete_app_after_install(false)
        .build();
    let team = sideloader.get_team().await.map_err(report("team"))?;
    sideloader
        .get_dev_session()
        .ensure_device_registered(&team, &name, &udid, None::<DeveloperDeviceType>)
        .await
        .map_err(report("register this iPhone"))?;

    let work = std::env::temp_dir().join("ss-refresh");
    let app = prepare_bundle(app_path, bundle_base, &work)?;
    progress("signing", 50);
    let (signed, _) = sideloader
        .sign_app(app, Some(team), false, None::<fn(f32) -> std::future::Ready<()>>, None, Some(&udid))
        .await
        .map_err(report("sign"))?;
    let bundle_id = plist::from_file::<_, plist::Dictionary>(signed.join("Info.plist"))
        .ok()
        .and_then(|d| d.get("CFBundleIdentifier").and_then(|v| v.as_string()).map(str::to_string))
        .unwrap_or_default();

    progress("installing", 0);
    install_app_rsd(&mut adapter, &mut hs, &signed, |p| progress("installing", p))
        .await
        .map_err(report("install"))?;
    let _ = std::fs::remove_dir_all(&work);
    Ok(bundle_id)
}

/// Reads one file from an installed app's Documents folder (house_arrest) over a CoreDevice tunnel, e.g. the app's
/// own log `ss-log.txt`. `rel` is the path under Documents.
#[cfg(feature = "laptop")]
pub async fn pull_document(pairing_path: &str, addr: std::net::SocketAddr, bundle_id: &str, rel: &str) -> Result<Vec<u8>, String> {
    use idevice::afc::opcode::AfcFopenMode;
    let (mut adapter, mut hs, _) = crate::phone::open_tunnel(pairing_path, addr).await?;
    let ha = idevice::house_arrest::HouseArrestClient::connect_rsd(&mut adapter, &mut hs)
        .await
        .map_err(|e| format!("house_arrest: {e:?}"))?;
    let mut afc = ha.vend_documents(bundle_id).await.map_err(|e| format!("open the app's Documents: {e:?}"))?;
    let path = format!("/Documents/{}", rel.trim_start_matches('/'));
    let mut f = afc.open(path.clone(), AfcFopenMode::RdOnly).await.map_err(|e| format!("open {path}: {e:?}"))?;
    let bytes = f.read_entire().await.map_err(|e| format!("read {path}: {e:?}"))?;
    let _ = f.close().await;
    Ok(bytes)
}

/// Copies files into an installed app's Documents folder (house_arrest) over a CoreDevice tunnel, e.g. the
/// signing data sscore hands to the app. `files`: (path under Documents, bytes). Returns how many were written.
#[cfg(feature = "laptop")]
pub async fn push_documents(pairing_path: &str, addr: std::net::SocketAddr, bundle_id: &str, files: &[(String, Vec<u8>)]) -> Result<usize, String> {
    use idevice::afc::opcode::AfcFopenMode;
    let (mut adapter, mut hs, _) = crate::phone::open_tunnel(pairing_path, addr).await?;
    let ha = idevice::house_arrest::HouseArrestClient::connect_rsd(&mut adapter, &mut hs)
        .await
        .map_err(|e| format!("house_arrest: {e:?}"))?;
    let mut afc = ha.vend_documents(bundle_id).await.map_err(|e| format!("open the app's Documents: {e:?}"))?;
    let mut n = 0;
    for (rel, bytes) in files {
        let dest = format!("/Documents/{}", rel.trim_start_matches('/'));
        let mut dir = String::new();
        for part in dest.trim_start_matches('/').split('/').collect::<Vec<_>>().split_last().map(|(_, d)| d.to_vec()).unwrap_or_default() {
            dir = format!("{dir}/{part}");
            let _ = afc.mk_dir(dir.clone()).await;               // exists already: fine
        }
        let mut f = afc.open(dest.clone(), AfcFopenMode::WrOnly).await.map_err(|e| format!("open {dest}: {e:?}"))?;
        f.write_entire(bytes).await.map_err(|e| format!("write {dest}: {e:?}"))?;
        f.close().await.map_err(|e| format!("close {dest}: {e:?}"))?;
        n += 1;
    }
    Ok(n)
}

/// Starts a refresh on a background thread. Returns an error if one is already running.
pub fn start(cfg: Config) -> Result<(), String> {
    let st = state().state;
    if ["login", "need_code", "signing", "installing"].contains(&st.as_str()) {
        return Err("a refresh is already running".into());
    }
    *code_slot().lock().unwrap() = None;
    set(|s| *s = RefreshState { state: "login".into(), ..Default::default() });
    std::thread::Builder::new()
        .name("ssrefresh".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("runtime");
            match rt.block_on(run(cfg)) {
                Ok(()) => set(|s| { s.state = "done".into(); s.progress = 100; }),
                Err(e) => set(|s| { s.state = "failed".into(); s.error = e; }),
            }
        })
        .map_err(|e| format!("thread: {e}"))?;
    Ok(())
}

// ---------------- C API ----------------
#[no_mangle]
pub extern "C" fn ss_refresh_start(json: *const c_char) -> *mut c_char {
    let text = if json.is_null() { String::new() } else { unsafe { CStr::from_ptr(json) }.to_string_lossy().to_string() };
    let res = serde_json::from_str::<serde_json::Value>(&text)
        .map_err(|e| format!("bad config: {e}"))
        .and_then(|v| Config::from_json(&v))
        .and_then(start);
    crate::ffi::out(match res {
        Ok(()) => serde_json::json!({"ok": true}),
        Err(e) => serde_json::json!({"ok": false, "error": e}),
    })
}

#[no_mangle]
pub extern "C" fn ss_refresh_submit_code(code: *const c_char) {
    if code.is_null() { return; }
    let c = unsafe { CStr::from_ptr(code) }.to_string_lossy().trim().to_string();
    *code_slot().lock().unwrap() = Some(c);
}

#[no_mangle]
pub extern "C" fn ss_refresh_status() -> *mut c_char {
    let s = state();
    crate::ffi::out(serde_json::json!({"ok": true, "state": s.state, "progress": s.progress, "error": s.error, "detail": s.detail}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_id_is_reset_before_signing() {
        let root = std::env::temp_dir().join(format!("ss-refresh-test-{}", std::process::id()));
        let app = root.join("src").join("Saved Scroll.app");
        std::fs::create_dir_all(app.join("_CodeSignature")).unwrap();
        std::fs::write(app.join("embedded.mobileprovision"), b"old").unwrap();
        let mut d = plist::Dictionary::new();
        d.insert("CFBundleIdentifier".into(), plist::Value::String("com.savedscroll.engine.ABCDE12345".into()));
        plist::to_file_xml(app.join("Info.plist"), &d).unwrap();

        let out = prepare_bundle(&app, "com.savedscroll.engine", &root.join("work")).unwrap();
        let back: plist::Dictionary = plist::from_file(out.join("Info.plist")).unwrap();
        assert_eq!(back.get("CFBundleIdentifier").and_then(|v| v.as_string()), Some("com.savedscroll.engine"));
        assert!(!out.join("_CodeSignature").exists() && !out.join("embedded.mobileprovision").exists());
        // the original (running) app is untouched
        let orig: plist::Dictionary = plist::from_file(app.join("Info.plist")).unwrap();
        assert_eq!(orig.get("CFBundleIdentifier").and_then(|v| v.as_string()), Some("com.savedscroll.engine.ABCDE12345"));
        let _ = std::fs::remove_dir_all(root);
    }
}
