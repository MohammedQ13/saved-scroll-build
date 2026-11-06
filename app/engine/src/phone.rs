//! The real iPhone, from inside an app running on that same iPhone.
//!
//! Path (mirrors idevice's `tools/src/pair_rsd_ios.rs` tunnel mode, `coredevice_stream.rs` and `hid.rs`,
//! MIT, by Jackson Coxson; and StikDebug's on-device approach):
//!   TCP 10.7.0.1:49152 (the phone's own RemoteXPC, reachable through a loopback VPN such as LocalDevVPN)
//!   → RSD handshake → `untrusted.tunnelservice` → RemotePairing verify with the user's pairing record
//!   → TCP listener → TLS-PSK CDTunnel → userspace TCP stack (jktcp) → RSD through the tunnel
//!   → displayservice media stream (the HID auth gate; its RTP is read and thrown away)
//!   → universalhidservice touches.
//! Needs iOS 27+ (iOS 26 refuses touch with CoreDevice error 9021), Developer Mode, a mounted developer
//! disk image, and a RemotePairing record for this phone.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use idevice::{
    core_device::{
        build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters, build_start_video_parameters,
        CallInfoBlob, DisplayServiceClient, UniversalHidServiceClient,
    },
    lockdown::LockdownClient,
    mobile_image_mounter::ImageMounter,
    remote_pairing::{connect_tls_psk_tunnel_native, RemotePairingClient, RpPairingFile, RpPairingSocket},
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
    ReadWrite, RsdService,
};
use tokio::net::TcpStream;

use crate::Device;

/// What we (the controller) support; Device Hub sends 140 for screen sharing.
const CLIENT_SUPPORTED_FEATURES: u64 = 140;
pub(crate) const HOST_NAME: &str = "saved-scroll";

/// The phone's default address through the loopback VPN.
pub(crate) fn default_addr() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::new(10, 7, 0, 1)), 49152)
}

/// Opens a CoreDevice tunnel to this phone with its RemotePairing record and returns the userspace
/// TCP stack, the service list inside the tunnel, and the RSD port. Used for touches and for refresh.
pub(crate) async fn open_tunnel(pairing_path: &str, addr: SocketAddr) -> Result<(AdapterHandle, RsdHandshake, u16), String> {
    let e = |what: &str| { let w = what.to_string(); move |err: idevice::IdeviceError| format!("{w}: {err:?}") };
    let io = |what: &str| { let w = what.to_string(); move |err: std::io::Error| format!("{w}: {err}") };

    // 1–2. The phone's `_remotepairing._tcp` port (49152 by default; through LocalDevVPN it's 10.7.0.1)
    // speaks raw RPPairing: verify with the stored record. (Not RSD: that's only on the USB interface;
    // device 2026-11-03 "RSD handshake" error. Same as StikDebug's tunnel_create_rppairing.)
    let s = TcpStream::connect(addr).await.map_err(io("connect to the phone's pairing port (is LocalDevVPN on?)"))?;
    let mut rpf = RpPairingFile::read_from_file(pairing_path).await.map_err(e("pairing record"))?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(s), HOST_NAME);
    rpc.connect(&mut rpf, || async { String::new() }).await.map_err(e("pair-verify (is the pairing record for this phone?)"))?;

    // 3. TLS-PSK CDTunnel, then the userspace TCP stack and RSD inside the tunnel.
    let port = rpc.create_tcp_listener().await.map_err(e("create tunnel listener"))?;
    let t = TcpStream::connect(SocketAddr::new(addr.ip(), port)).await.map_err(io("connect tunnel"))?;
    let tunnel = connect_tls_psk_tunnel_native(t, rpc.encryption_key()).await.map_err(e("TLS-PSK tunnel"))?;
    let client_ip: IpAddr = tunnel.info.client_address.parse().map_err(|_| "bad tunnel client address".to_string())?;
    let server_ip: IpAddr = tunnel.info.server_address.parse().map_err(|_| "bad tunnel server address".to_string())?;
    let rsd_port = tunnel.info.server_rsd_port;
    let adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    let mut handle = adapter.to_async_handle();
    let rsd_stream = handle.connect(rsd_port).await.map_err(io("RSD through tunnel"))?;
    let hs = RsdHandshake::new(rsd_stream).await.map_err(e("RSD handshake through tunnel"))?;
    Ok((handle, hs, rsd_port))
}

pub struct PhoneDevice {
    pairing_path: String,
    addr: SocketAddr,
    adapter: Option<AdapterHandle>,
    handshake: Option<RsdHandshake>,
    display: Option<DisplayServiceClient<Box<dyn ReadWrite>>>,
    hid: Option<UniversalHidServiceClient<Box<dyn ReadWrite>>>,
    drains: Vec<tokio::task::JoinHandle<()>>,
    rsd_port: u16,
    /// Last non-fatal problem mounting the developer disk image (shown in status if touches then fail).
    pub ddi_note: String,
}

impl PhoneDevice {
    /// `pairing_path`: the RemotePairing record (plist) for this phone. `addr`: defaults to 10.7.0.1:49152.
    pub fn new(pairing_path: &str, addr: Option<SocketAddr>) -> Self {
        Self {
            pairing_path: pairing_path.to_string(),
            addr: addr.unwrap_or_else(default_addr),
            adapter: None,
            handshake: None,
            display: None,
            hid: None,
            drains: Vec::new(),
            rsd_port: 0,
            ddi_note: String::new(),
        }
    }

    /// The developer disk image (DDI) folder the app downloads next to the pairing record:
    /// `ddi/{Image.dmg, Image.dmg.trustcache, BuildManifest.plist}` (Personalized variant).
    fn ddi_dir(&self) -> std::path::PathBuf {
        std::path::Path::new(&self.pairing_path).parent().unwrap_or(std::path::Path::new(".")).join("ddi")
    }

    /// Mounts the DDI if it isn't mounted (it unmounts on every reboot). Developer services, possibly
    /// including display/HID, only appear once it's mounted. Personalization asks Apple's signing server
    /// the first time; iOS caches the result. Non-fatal: if it fails, we still try to touch.
    async fn ensure_ddi(&mut self) -> Result<bool, String> {
        let dir = self.ddi_dir();
        let adapter = self.adapter.as_mut().ok_or("not connected")?;
        let hs = self.handshake.as_mut().ok_or("not connected")?;
        let mut mounter = ImageMounter::connect_rsd(adapter, hs).await.map_err(|x| format!("image mounter: {x:?}"))?;
        if mounter.lookup_image("Personalized").await.is_ok() {
            return Ok(false);                                           // already mounted
        }
        let read = |f: &str| std::fs::read(dir.join(f)).map_err(|x| format!("developer disk image not downloaded yet ({f}: {x})"));
        let (image, trust_cache, manifest) = (read("Image.dmg")?, read("Image.dmg.trustcache")?, read("BuildManifest.plist")?);
        let mut ld = LockdownClient::connect_rsd(adapter, hs).await.map_err(|x| format!("lockdown: {x:?}"))?;
        let ecid = ld
            .get_value(Some("UniqueChipID"), None)
            .await
            .map_err(|x| format!("chip id: {x:?}"))?
            .as_unsigned_integer()
            .ok_or("chip id: not a number")?;
        mounter
            .mount_personalized_rsd(adapter, hs, image, trust_cache, &manifest, None, ecid)
            .await
            .map_err(|x| format!("mount developer disk image: {x:?}"))?;
        Ok(true)
    }

    async fn tunnel(&mut self) -> Result<(), String> {
        let e = |what: &str| { let w = what.to_string(); move |err: idevice::IdeviceError| format!("{w}: {err:?}") };
        let io = |what: &str| { let w = what.to_string(); move |err: std::io::Error| format!("{w}: {err}") };
        let (handle, hs, rsd_port) = open_tunnel(&self.pairing_path, self.addr).await?;
        self.adapter = Some(handle);
        self.handshake = Some(hs);
        self.rsd_port = rsd_port;

        // 4. Developer disk image: mount it if needed, then re-read the service list (new services appear).
        match self.ensure_ddi().await {
            Ok(true) => {
                self.ddi_note.clear();
                let adapter = self.adapter.as_mut().ok_or("not connected")?;
                let s = adapter.connect(self.rsd_port).await.map_err(io("RSD after mount"))?;
                self.handshake = Some(RsdHandshake::new(s).await.map_err(e("RSD handshake after mount"))?);
            }
            Ok(false) => self.ddi_note.clear(),
            Err(note) => self.ddi_note = note,
        }
        Ok(())
    }

    /// The displayservice media stream that authenticates HID (audio first, then video, one session).
    async fn start_stream(&mut self) -> Result<(), String> {
        let adapter = self.adapter.as_mut().ok_or("not connected")?;
        let hs = self.handshake.as_mut().ok_or("not connected")?;
        let mut client = DisplayServiceClient::connect_rsd(adapter, hs).await.map_err(|x| format!("display service: {x:?}"))?;
        let audio_udp = adapter.bind_udp(0).await.map_err(|x| format!("bind audio: {x}"))?;
        let video_udp = adapter.bind_udp(0).await.map_err(|x| format!("bind video: {x}"))?;
        let receiver_ip = adapter.host_ip().to_string();
        let sender_ip = adapter.peer_ip().to_string();
        let call_info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session = uuid::Uuid::new_v4();
        let audio_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let audio_offer = build_screen_audio_offer(&audio_id, &call_info).map_err(|x| format!("audio offer: {x:?}"))?;
        let ap = build_start_audio_parameters(&receiver_ip, audio_udp.local_port(), &sender_ip, 50000, audio_offer, CLIENT_SUPPORTED_FEATURES, session);
        client.start_media_stream(ap).await.map_err(|x| format!("audio stream: {x:?}"))?;
        let video_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let ssrc = uuid::Uuid::new_v4().as_u128() as u32;
        let offer = build_screen_video_offer(&video_id, &call_info, ssrc).map_err(|x| format!("video offer: {x:?}"))?;
        let vp = build_start_video_parameters(&receiver_ip, video_udp.local_port(), &sender_ip, 50001, offer, CLIENT_SUPPORTED_FEATURES, 1, session);
        client.start_media_stream(vp).await.map_err(|x| format!("video stream: {x:?} (iOS 27 needed)"))?;

        // Read and discard the stream so unread video can't pile up during a long dive.
        for sock in [audio_udp, video_udp] {
            self.drains.push(tokio::task::spawn_local(async move { while sock.recv().await.is_ok() {} }));
        }
        self.display = Some(client);
        Ok(())
    }

    fn drop_connection(&mut self) {
        self.hid = None;
        self.display = None;
        for d in self.drains.drain(..) { d.abort(); }
        self.handshake = None;
        self.adapter = None;
    }
}

impl Device for PhoneDevice {
    async fn connect(&mut self) -> Result<(), String> {
        if self.adapter.is_some() { return Ok(()); }
        let r = self.tunnel().await;
        if r.is_err() { self.drop_connection(); }
        r
    }

    async fn begin(&mut self) -> Result<(), String> {
        self.connect().await?;
        if let Err(err) = self.start_stream().await {
            let note = std::mem::take(&mut self.ddi_note);
            self.drop_connection();                          // reconnect next time (tunnel may have died)
            return Err(if note.is_empty() { err } else { format!("{err} [disk image: {note}]") });
        }
        // backboardd needs a moment to match the HID surfaces to the newly authenticated stream.
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let adapter = self.adapter.as_mut().ok_or("not connected")?;
        let hs = self.handshake.as_mut().ok_or("not connected")?;
        let hid = UniversalHidServiceClient::connect_rsd(adapter, hs).await.map_err(|x| format!("universal HID: {x:?}"))?;
        self.hid = Some(hid);
        Ok(())
    }

    async fn end(&mut self) {
        self.hid = None;
        if let Some(mut d) = self.display.take() { let _ = d.stop_media_stream().await; }
        for d in self.drains.drain(..) { d.abort(); }
    }

    async fn drag(&mut self, x1: u16, y1: u16, x2: u16, y2: u16, steps: u32, delay_ms: u64) -> Result<(), String> {
        let hid = self.hid.as_mut().ok_or("no touch session")?;
        hid.drag(x1, y1, x2, y2, steps, delay_ms).await.map_err(|x| format!("drag: {x:?}"))
    }

    async fn tap(&mut self, x: u16, y: u16) -> Result<(), String> {
        let hid = self.hid.as_mut().ok_or("no touch session")?;
        hid.tap(x, y).await.map_err(|x| format!("tap: {x:?}"))
    }

    fn connected(&self) -> bool { self.adapter.is_some() }
}
