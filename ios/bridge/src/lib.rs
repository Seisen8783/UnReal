//! Native Rust bridge wrapping `idevice` for A Console Mobile (iOS) and CLI testing (macOS).
#![allow(non_camel_case_types)]

use std::cell::RefCell;
use std::ffi::{CStr, CString, c_char};
use std::net::IpAddr;
use std::path::PathBuf;
use std::time::Duration;

use idevice::dvt::location_simulation::LocationSimulationClient;
use idevice::dvt::remote_server::RemoteServerClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, RsdProvider, TcpProvider, UsbmuxdProvider};
use idevice::services::amfi::AmfiClient;
use idevice::services::core_device_proxy::CoreDeviceProxy;
use idevice::services::cryptexd::{self, Cryptex1Assets};
use idevice::services::heartbeat::HeartbeatClient;
use idevice::services::lockdown::LockdownClient;
use idevice::services::mobile_image_mounter::ImageMounter;
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::handle::AdapterHandle;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection};
use idevice::{IdeviceError, IdeviceService, ReadWrite, RsdService};
use tokio::sync::{mpsc, oneshot};

const DTSERVICEHUB: &str = "com.apple.instruments.dtservicehub";
const CRYPTEXD_SERVICE: &str = "com.apple.security.cryptexd.remote";

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ac_status {
    AC_OK = 0,
    AC_ERR_UNREACHABLE = 1,
    AC_ERR_PAIRING = 2,
    AC_ERR_DEV_MODE = 3,
    AC_ERR_DDI = 4,
    AC_ERR_TUNNEL = 5,
    AC_ERR_DVT = 6,
    AC_ERR_TIMEOUT = 7,
    AC_ERR_INVALID_ARG = 8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct ac_device_info {
    pub product_version: [c_char; 16],
    pub device_name: [c_char; 64],
    pub developer_mode: bool,
    pub ddi_mounted: bool,
}

impl Default for ac_device_info {
    fn default() -> Self {
        Self {
            product_version: [0; 16],
            device_name: [0; 64],
            developer_mode: false,
            ddi_mounted: false,
        }
    }
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::new("").unwrap());
}

fn set_last_error(message: impl AsRef<str>) {
    let sanitized = message.as_ref().replace('\0', " ");
    if let Ok(cstr) = CString::new(sanitized) {
        LAST_ERROR.with(|cell| {
            *cell.borrow_mut() = cstr;
        });
    }
}

fn clear_last_error() {
    set_last_error("");
}

enum SessionCommand {
    GetInfo(oneshot::Sender<Result<DeviceInfoSnapshot, BridgeError>>),
    MountDdi {
        restore_dir: PathBuf,
        timeout: Duration,
        reply: oneshot::Sender<Result<(), BridgeError>>,
    },
    OpenLocation(oneshot::Sender<Result<(), BridgeError>>),
    SetLocation {
        lat: f64,
        lon: f64,
        reply: oneshot::Sender<Result<(), BridgeError>>,
    },
    ClearLocation(oneshot::Sender<Result<(), BridgeError>>),
    Ping(oneshot::Sender<Result<(), BridgeError>>),
    Shutdown(oneshot::Sender<()>),
}

#[derive(Debug, Clone)]
struct DeviceInfoSnapshot {
    product_version: String,
    device_name: String,
    developer_mode: bool,
    ddi_mounted: bool,
}

#[derive(Debug)]
struct BridgeError {
    status: ac_status,
    message: String,
}

impl BridgeError {
    fn new(status: ac_status, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}

fn map_idevice_error(err: IdeviceError, default_status: ac_status) -> BridgeError {
    let status = match &err {
        IdeviceError::Socket(io_err)
            if matches!(
                io_err.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            ) =>
        {
            ac_status::AC_ERR_TIMEOUT
        }
        IdeviceError::Socket(_) => ac_status::AC_ERR_UNREACHABLE,
        IdeviceError::InvalidHostID => ac_status::AC_ERR_PAIRING,
        IdeviceError::ServiceNotFound => default_status,
        _ => default_status,
    };
    BridgeError::new(status, err.to_string())
}

pub struct ac_session {
    tx: mpsc::Sender<SessionCommand>,
    thread: Option<std::thread::JoinHandle<()>>,
}

#[derive(Clone)]
enum ProviderConfig {
    Tcp {
        addr: IpAddr,
        _port: u16,
        pairing: PairingFile,
    },
    Usbmuxd {
        provider: UsbmuxdProvider,
    },
}

impl ProviderConfig {
    fn make_provider(&self) -> Box<dyn IdeviceProvider> {
        match self {
            Self::Tcp { addr, pairing, .. } => Box::new(TcpProvider {
                addr: *addr,
                scope_id: None,
                pairing_file: pairing.clone(),
                label: "a-console-mobile".into(),
            }),
            Self::Usbmuxd { provider } => Box::new(provider.clone()),
        }
    }
}

async fn establish_tunnel(
    provider: &dyn IdeviceProvider,
) -> Result<(AdapterHandle, RsdHandshake, u16), BridgeError> {
    let proxy = CoreDeviceProxy::connect(provider)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_TUNNEL))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let adapter = proxy
        .create_software_tunnel()
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_TUNNEL))?;
    let mut handle = adapter.to_async_handle();
    let stream = handle
        .connect_to_service_port(rsd_port)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_TUNNEL))?;
    let handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_TUNNEL))?;
    Ok((handle, handshake, rsd_port))
}

async fn query_device_snapshot(
    provider: &dyn IdeviceProvider,
    handshake: &RsdHandshake,
) -> Result<DeviceInfoSnapshot, BridgeError> {
    let pairing = provider
        .get_pairing_file()
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_PAIRING))?;

    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_UNREACHABLE))?;
    lockdown
        .start_session(&pairing)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_PAIRING))?;

    let product_version = lockdown
        .get_value(Some("ProductVersion"), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(ToString::to_string))
        .unwrap_or_default();

    let device_name = lockdown
        .get_value(Some("DeviceName"), None)
        .await
        .ok()
        .and_then(|v| v.as_string().map(ToString::to_string))
        .unwrap_or_else(|| "iPhone".to_string());

    let developer_mode = match AmfiClient::connect(provider).await {
        Ok(mut amfi) => amfi.get_developer_mode_status().await.unwrap_or(false),
        Err(_) => false,
    };

    let ddi_mounted = handshake.services.contains_key(DTSERVICEHUB);

    Ok(DeviceInfoSnapshot {
        product_version,
        device_name,
        developer_mode,
        ddi_mounted,
    })
}

async fn query_ecid(config: ProviderConfig) -> Result<u64, BridgeError> {
    let provider = config.make_provider();
    let pairing = provider
        .get_pairing_file()
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_PAIRING))?;
    let mut lockdown = LockdownClient::connect(provider.as_ref())
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_UNREACHABLE))?;
    lockdown
        .start_session(&pairing)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_PAIRING))?;
    let value = lockdown
        .get_value(Some("UniqueChipID"), None)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?;
    value
        .as_unsigned_integer()
        .ok_or_else(|| BridgeError::new(ac_status::AC_ERR_DDI, "missing UniqueChipID"))
}

async fn load_cryptex1_assets(restore_dir: PathBuf) -> Result<Cryptex1Assets, BridgeError> {
    let manifest_bytes = tokio::fs::read(restore_dir.join("BuildManifest.plist"))
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read BuildManifest.plist: {e}")))?;
    let manifest: plist::Dictionary = plist::from_bytes(&manifest_bytes)
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("invalid BuildManifest: {e}")))?;
    let build_identity = idevice::tss::select_cryptex_build_identity(&manifest)
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?
        .clone();

    let image_path = restore_dir.join(manifest_asset_path(&build_identity, "Cryptex1,GenericDmg")?);
    let tc_path = restore_dir.join(manifest_asset_path(&build_identity, "Cryptex1,GenericTrustCache")?);
    let info_path = restore_dir.join(manifest_asset_path(&build_identity, "Cryptex1,CryptexInfoPlist")?);
    let vol_path = restore_dir.join(manifest_asset_path(&build_identity, "Cryptex1,GenericVolume")?);

    let image = tokio::fs::read(image_path)
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read Cryptex1,GenericDmg: {e}")))?;
    let trustcache = tokio::fs::read(tc_path)
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read Cryptex1,GenericTrustCache: {e}")))?;
    let info = tokio::fs::read(info_path)
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read Cryptex1,CryptexInfoPlist: {e}")))?;
    let volumehash = tokio::fs::read(vol_path)
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read Cryptex1,GenericVolume: {e}")))?;

    Ok(Cryptex1Assets::from_parts(image, trustcache, info, volumehash, build_identity))
}

async fn mount_ddi_from_dir(
    config: ProviderConfig,
    handle: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    rsd_port: u16,
    restore_dir: PathBuf,
) -> Result<(), BridgeError> {
    if handshake.services.contains_key(DTSERVICEHUB) {
        return Ok(());
    }

    if handshake.services.contains_key(CRYPTEXD_SERVICE) {
        if let Ok(Some(_)) = cryptexd::installed_ddi(handle, handshake).await {
            refresh_handshake(handle, handshake, rsd_port).await?;
            return Ok(());
        }
        let assets = load_cryptex1_assets(restore_dir).await?;
        cryptexd::install_ddi(handle, handshake, &assets)
            .await
            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?;
        refresh_handshake(handle, handshake, rsd_port).await?;
        return Ok(());
    }

    let manifest_path = restore_dir.join("BuildManifest.plist");
    let manifest_bytes = tokio::fs::read(&manifest_path)
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read manifest: {e}")))?;
    let manifest: plist::Dictionary = plist::from_bytes(&manifest_bytes)
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("invalid BuildManifest: {e}")))?;

    let mut mounter = ImageMounter::connect_rsd(handle, handshake)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?;
    let identifiers = mounter
        .query_personalization_identifiers(None)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?;

    let board_id = identifiers
        .get("BoardId")
        .and_then(|v| v.as_unsigned_integer())
        .ok_or_else(|| BridgeError::new(ac_status::AC_ERR_DDI, "missing BoardId"))?;
    let chip_id = identifiers
        .get("ChipID")
        .and_then(|v| v.as_unsigned_integer())
        .ok_or_else(|| BridgeError::new(ac_status::AC_ERR_DDI, "missing ChipID"))?;

    let identity = idevice::tss::select_build_identity(&manifest, board_id, chip_id, None)
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?;

    let dmg_rel = manifest_asset_path(identity, "PersonalizedDMG")?;
    let tc_rel = manifest_asset_path(identity, "LoadableTrustCache")?;
    let image = tokio::fs::read(restore_dir.join(dmg_rel))
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read PersonalizedDMG: {e}")))?;
    let trustcache = tokio::fs::read(restore_dir.join(tc_rel))
        .await
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_DDI, format!("cannot read LoadableTrustCache: {e}")))?;
    let ecid = query_ecid(config).await?;

    mounter
        .mount_personalized_rsd(
            handle,
            handshake,
            image,
            trustcache,
            &manifest_bytes,
            None,
            ecid,
        )
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DDI))?;

    refresh_handshake(handle, handshake, rsd_port).await
}

fn manifest_asset_path(identity: &plist::Dictionary, key: &str) -> Result<PathBuf, BridgeError> {
    identity
        .get("Manifest")
        .and_then(|v| v.as_dictionary())
        .and_then(|m| m.get(key))
        .and_then(|e| e.as_dictionary())
        .and_then(|e| e.get("Info"))
        .and_then(|i| i.as_dictionary())
        .and_then(|i| i.get("Path"))
        .and_then(|p| p.as_string())
        .map(PathBuf::from)
        .ok_or_else(|| BridgeError::new(ac_status::AC_ERR_DDI, format!("missing manifest path for {key}")))
}

async fn refresh_handshake(
    handle: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    rsd_port: u16,
) -> Result<(), BridgeError> {
    let stream = handle
        .connect_to_service_port(rsd_port)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_TUNNEL))?;
    *handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_TUNNEL))?;
    Ok(())
}

async fn open_dvt_client(
    handle: &mut AdapterHandle,
    handshake: &RsdHandshake,
) -> Result<RemoteServerClient<Box<dyn ReadWrite>>, BridgeError> {
    let service = handshake
        .services
        .get(DTSERVICEHUB)
        .ok_or_else(|| BridgeError::new(ac_status::AC_ERR_DDI, "Developer disk image is not mounted"))?;
    let stream = handle
        .connect_to_service_port(service.port)
        .await
        .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DVT))?;
    let mut remote = RemoteServerClient::new(stream);
    // Drain initial capability publication from dtservicehub before opening channels.
    let _ = remote.read_message(0).await;
    Ok(remote)
}

async fn run_session_worker(
    config: ProviderConfig,
    initial_snapshot: DeviceInfoSnapshot,
    mut handle: AdapterHandle,
    mut handshake: RsdHandshake,
    rsd_port: u16,
    mut rx: mpsc::Receiver<SessionCommand>,
) {
    let mut remote: Option<RemoteServerClient<Box<dyn ReadWrite>>> = None;

    while let Some(cmd) = rx.recv().await {
        match cmd {
            SessionCommand::GetInfo(reply) => {
                let mut snap = initial_snapshot.clone();
                snap.ddi_mounted = handshake.services.contains_key(DTSERVICEHUB);
                let _ = reply.send(Ok(snap));
            }
            SessionCommand::MountDdi {
                restore_dir,
                timeout,
                reply,
            } => {
                let res = tokio::time::timeout(
                    timeout,
                    mount_ddi_from_dir(config.clone(), &mut handle, &mut handshake, rsd_port, restore_dir),
                )
                .await
                .unwrap_or_else(|_| Err(BridgeError::new(ac_status::AC_ERR_TIMEOUT, "DDI mount timed out")));
                let _ = reply.send(res);
            }
            SessionCommand::OpenLocation(reply) => {
                if remote.is_some() {
                    let _ = reply.send(Ok(()));
                    continue;
                }
                if !initial_snapshot.developer_mode {
                    let _ = reply.send(Err(BridgeError::new(
                        ac_status::AC_ERR_DEV_MODE,
                        "Developer mode is disabled on device",
                    )));
                    continue;
                }
                match open_dvt_client(&mut handle, &handshake).await {
                    Ok(client) => {
                        remote = Some(client);
                        let _ = reply.send(Ok(()));
                    }
                    Err(err) => {
                        let _ = reply.send(Err(err));
                    }
                }
            }
            SessionCommand::SetLocation { lat, lon, reply } => {
                let res = match remote.as_mut() {
                    None => Err(BridgeError::new(ac_status::AC_ERR_DVT, "location channel not opened")),
                    Some(client) => async {
                        let mut loc = LocationSimulationClient::new(client)
                            .await
                            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DVT))?;
                        loc.set(lat, lon)
                            .await
                            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DVT))
                    }
                    .await,
                };
                if res.is_err() {
                    remote = None;
                }
                let _ = reply.send(res);
            }
            SessionCommand::ClearLocation(reply) => {
                let res = match remote.as_mut() {
                    None => Err(BridgeError::new(ac_status::AC_ERR_DVT, "location channel not opened")),
                    Some(client) => async {
                        let mut loc = LocationSimulationClient::new(client)
                            .await
                            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DVT))?;
                        loc.clear()
                            .await
                            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_DVT))
                    }
                    .await,
                };
                let _ = reply.send(res);
            }
            SessionCommand::Ping(reply) => {
                let _ = reply.send(refresh_handshake(&mut handle, &mut handshake, rsd_port).await);
            }
            SessionCommand::Shutdown(reply) => {
                drop(remote);
                let _ = reply.send(());
                break;
            }
        }
    }
}

async fn run_heartbeat_loop(config: ProviderConfig) {
    let provider = config.make_provider();
    let Ok(mut hb) = HeartbeatClient::connect(provider.as_ref()).await else {
        return;
    };
    let mut interval = 15u64;
    loop {
        match hb.get_marco(interval + 5).await {
            Ok(next) => {
                interval = next.max(5);
                if hb.send_polo().await.is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
}

fn open_session_with_config(
    config: ProviderConfig,
    timeout: Duration,
) -> Result<Box<ac_session>, BridgeError> {
    let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel::<Result<mpsc::Sender<SessionCommand>, BridgeError>>(1);
    let thread = std::thread::Builder::new()
        .name("ac-bridge-session".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = ready_tx.send(Err(BridgeError::new(
                        ac_status::AC_ERR_TUNNEL,
                        format!("failed to create session runtime: {e}"),
                    )));
                    return;
                }
            };

            let local = tokio::task::LocalSet::new();
            rt.block_on(local.run_until(async move {
                let provider = config.make_provider();
                let init = tokio::time::timeout(timeout, async {
                    let (handle, handshake, rsd_port) = establish_tunnel(provider.as_ref()).await?;
                    let snapshot = query_device_snapshot(provider.as_ref(), &handshake).await?;
                    Ok::<_, BridgeError>((handle, handshake, rsd_port, snapshot))
                })
                .await
                .unwrap_or_else(|_| Err(BridgeError::new(ac_status::AC_ERR_TIMEOUT, "session open timed out")));

                let (handle, handshake, rsd_port, snapshot) = match init {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };

                let (tx, rx) = mpsc::channel(16);
                let hb_task = tokio::task::spawn_local(run_heartbeat_loop(config.clone()));
                if ready_tx.send(Ok(tx)).is_err() {
                    hb_task.abort();
                    return;
                }

                run_session_worker(config, snapshot, handle, handshake, rsd_port, rx).await;
                hb_task.abort();
            }));
        })
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_TUNNEL, format!("failed to spawn session thread: {e}")))?;

    match ready_rx.recv() {
        Ok(Ok(tx)) => Ok(Box::new(ac_session {
            tx,
            thread: Some(thread),
        })),
        Ok(Err(err)) => {
            let _ = thread.join();
            Err(err)
        }
        Err(_) => {
            let _ = thread.join();
            Err(BridgeError::new(ac_status::AC_ERR_TUNNEL, "session thread exited unexpectedly"))
        }
    }
}

fn open_usb_provider(udid: Option<String>, timeout: Duration) -> Result<UsbmuxdProvider, BridgeError> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| BridgeError::new(ac_status::AC_ERR_UNREACHABLE, format!("runtime error: {e}")))?;
    rt.block_on(tokio::time::timeout(timeout, async {
        let mut usbmuxd = UsbmuxdConnection::default()
            .await
            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_UNREACHABLE))?;
        let devices = usbmuxd
            .get_devices()
            .await
            .map_err(|e| map_idevice_error(e, ac_status::AC_ERR_UNREACHABLE))?;
        let device = devices
            .into_iter()
            .filter(|d| matches!(d.connection_type, Connection::Usb))
            .find(|d| match &udid {
                Some(target) => d.udid == *target,
                None => true,
            })
            .ok_or_else(|| BridgeError::new(ac_status::AC_ERR_UNREACHABLE, "no matching USB iPhone found"))?;
        Ok::<_, BridgeError>(device.to_provider(UsbmuxdAddr::default(), "a-console-cli"))
    }))
    .unwrap_or_else(|_| Err(BridgeError::new(ac_status::AC_ERR_TIMEOUT, "usbmuxd lookup timed out")))
}

fn copy_cstr(dst: &mut [c_char], src: &str) {
    dst.fill(0);
    let bytes = src.as_bytes();
    let count = bytes.len().min(dst.len().saturating_sub(1));
    for (slot, &b) in dst.iter_mut().take(count).zip(bytes.iter()) {
        *slot = b as c_char;
    }
}

fn dispatch<T>(
    session: *mut ac_session,
    build: impl FnOnce(oneshot::Sender<Result<T, BridgeError>>) -> SessionCommand,
) -> Result<T, BridgeError> {
    if session.is_null() {
        return Err(BridgeError::new(ac_status::AC_ERR_INVALID_ARG, "null session"));
    }
    let session = unsafe { &*session };
    let (reply_tx, reply_rx) = oneshot::channel();
    let cmd = build(reply_tx);
    session
        .tx
        .blocking_send(cmd)
        .map_err(|_| BridgeError::new(ac_status::AC_ERR_TUNNEL, "session closed"))?;
    reply_rx
        .blocking_recv()
        .map_err(|_| BridgeError::new(ac_status::AC_ERR_TUNNEL, "session worker stopped"))?
}

fn finish_result(res: Result<(), BridgeError>) -> ac_status {
    match res {
        Ok(()) => {
            clear_last_error();
            ac_status::AC_OK
        }
        Err(err) => {
            set_last_error(err.message);
            err.status
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_session_open(
    host_ip: *const c_char,
    port: u16,
    pairing_plist: *const u8,
    pairing_len: usize,
    timeout_ms: u32,
    out: *mut *mut ac_session,
) -> ac_status {
    if host_ip.is_null() || pairing_plist.is_null() || pairing_len == 0 || out.is_null() {
        set_last_error("invalid argument to ac_session_open");
        return ac_status::AC_ERR_INVALID_ARG;
    }
    let host_str = match unsafe { CStr::from_ptr(host_ip) }.to_str() {
        Ok(s) => s,
        Err(_) => {
            set_last_error("host_ip is not valid UTF-8");
            return ac_status::AC_ERR_INVALID_ARG;
        }
    };
    let addr: IpAddr = match host_str.parse() {
        Ok(ip) => ip,
        Err(e) => {
            set_last_error(format!("invalid host IP '{host_str}': {e}"));
            return ac_status::AC_ERR_INVALID_ARG;
        }
    };
    let plist_bytes = unsafe { std::slice::from_raw_parts(pairing_plist, pairing_len) };
    let pairing = match PairingFile::from_bytes(plist_bytes) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(format!("invalid pairing file: {e}"));
            return ac_status::AC_ERR_PAIRING;
        }
    };
    let timeout = Duration::from_millis(u64::from(timeout_ms.max(1000)));
    let config = ProviderConfig::Tcp {
        addr,
        _port: port,
        pairing,
    };
    match open_session_with_config(config, timeout) {
        Ok(session) => {
            unsafe { *out = Box::into_raw(session) };
            clear_last_error();
            ac_status::AC_OK
        }
        Err(err) => {
            set_last_error(err.message);
            err.status
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_session_open_usb(
    udid: *const c_char,
    timeout_ms: u32,
    out: *mut *mut ac_session,
) -> ac_status {
    if out.is_null() {
        set_last_error("out pointer is null");
        return ac_status::AC_ERR_INVALID_ARG;
    }
    let requested_udid = if udid.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(udid) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s.to_string()),
            Ok(_) => None,
            Err(_) => {
                set_last_error("udid is not valid UTF-8");
                return ac_status::AC_ERR_INVALID_ARG;
            }
        }
    };
    let timeout = Duration::from_millis(u64::from(timeout_ms.max(1000)));
    let provider = match open_usb_provider(requested_udid, timeout) {
        Ok(p) => p,
        Err(err) => {
            set_last_error(err.message);
            return err.status;
        }
    };

    match open_session_with_config(ProviderConfig::Usbmuxd { provider }, timeout) {
        Ok(session) => {
            unsafe { *out = Box::into_raw(session) };
            clear_last_error();
            ac_status::AC_OK
        }
        Err(err) => {
            set_last_error(err.message);
            err.status
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_device_info_get(s: *mut ac_session, out: *mut ac_device_info) -> ac_status {
    if out.is_null() {
        set_last_error("out pointer is null");
        return ac_status::AC_ERR_INVALID_ARG;
    }
    match dispatch(s, SessionCommand::GetInfo) {
        Ok(info) => {
            let mut result = ac_device_info::default();
            copy_cstr(&mut result.product_version, &info.product_version);
            copy_cstr(&mut result.device_name, &info.device_name);
            result.developer_mode = info.developer_mode;
            result.ddi_mounted = info.ddi_mounted;
            unsafe { *out = result };
            clear_last_error();
            ac_status::AC_OK
        }
        Err(err) => {
            set_last_error(err.message);
            err.status
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_ddi_mount(
    s: *mut ac_session,
    restore_dir: *const c_char,
    timeout_ms: u32,
) -> ac_status {
    if restore_dir.is_null() {
        set_last_error("restore_dir is null");
        return ac_status::AC_ERR_INVALID_ARG;
    }
    let dir_str = match unsafe { CStr::from_ptr(restore_dir) }.to_str() {
        Ok(p) => p,
        Err(_) => {
            set_last_error("restore_dir is not valid UTF-8");
            return ac_status::AC_ERR_INVALID_ARG;
        }
    };
    let timeout = Duration::from_millis(u64::from(timeout_ms.max(5000)));
    finish_result(dispatch(s, |reply| SessionCommand::MountDdi {
        restore_dir: PathBuf::from(dir_str),
        timeout,
        reply,
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_location_open(s: *mut ac_session) -> ac_status {
    finish_result(dispatch(s, SessionCommand::OpenLocation))
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_location_set(s: *mut ac_session, lat: f64, lon: f64) -> ac_status {
    if !lat.is_finite() || !lon.is_finite() || !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
        set_last_error("latitude or longitude out of range");
        return ac_status::AC_ERR_INVALID_ARG;
    }
    finish_result(dispatch(s, |reply| SessionCommand::SetLocation { lat, lon, reply }))
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_location_clear(s: *mut ac_session) -> ac_status {
    finish_result(dispatch(s, SessionCommand::ClearLocation))
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_session_ping(s: *mut ac_session) -> ac_status {
    finish_result(dispatch(s, SessionCommand::Ping))
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_session_close(s: *mut ac_session) {
    if s.is_null() {
        return;
    }
    let mut session = unsafe { Box::from_raw(s) };
    let (tx, rx) = oneshot::channel();
    if session.tx.blocking_send(SessionCommand::Shutdown(tx)).is_ok() {
        let _ = rx.blocking_recv();
    }
    if let Some(thread) = session.thread.take() {
        let _ = thread.join();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ac_last_error() -> *const c_char {
    LAST_ERROR.with(|cell| cell.borrow().as_ptr())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_arguments_safely() {
        let mut out: *mut ac_session = std::ptr::null_mut();
        assert_eq!(
            ac_session_open(std::ptr::null(), 62078, std::ptr::null(), 0, 1000, &mut out),
            ac_status::AC_ERR_INVALID_ARG
        );
        let ip = CString::new("not-an-ip").unwrap();
        let bytes = b"invalid";
        assert_eq!(
            ac_session_open(ip.as_ptr(), 62078, bytes.as_ptr(), bytes.len(), 1000, &mut out),
            ac_status::AC_ERR_INVALID_ARG
        );
        let valid_ip = CString::new("10.7.0.1").unwrap();
        assert_eq!(
            ac_session_open(valid_ip.as_ptr(), 62078, bytes.as_ptr(), bytes.len(), 1000, &mut out),
            ac_status::AC_ERR_PAIRING
        );
        assert_eq!(ac_location_set(std::ptr::null_mut(), 91.0, 0.0), ac_status::AC_ERR_INVALID_ARG);
    }
}
