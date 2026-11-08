//! cocoram: in-app replacement for GetMoreRam (github.com/hugeBlack/GetMoreRam, idea and flow).
//! The code is built on isideload (github.com/nab138/isideload, MIT), the library behind iloader.
//! It signs in to the Apple ID that signed CocoLauncher (SideStore, free account), finds the App ID
//! whose identifier is this app's bundle identifier and enables the INCREASED_MEMORY_LIMIT
//! capability on it. The player then reinstalls/refreshes CocoLauncher in SideStore so the new
//! provisioning profile carries the entitlement. The Apple ID password only lives in memory for
//! this call; only the anisette state is written (storage_dir).

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use isideload::anisette::remote_v3::{RemoteV3AnisetteProvider, DEFAULT_ANISETTE_V3_URL};
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::app_ids::AppIdsApi;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::teams::TeamsApi;
use isideload::util::fs_storage::FsStorage;

/// kind: 1 = 2FA code needed (message = JSON), 2 = progress step, 3 = finished OK, 4 = error
pub type CocoRamEventCallback = extern "C" fn(ctx: *mut c_void, kind: i32, message: *const c_char);

const EV_TWO_FACTOR: i32 = 1;
const EV_PROGRESS: i32 = 2;
const EV_DONE: i32 = 3;
const EV_ERROR: i32 = 4;

static TWO_FACTOR_REPLY: Mutex<Option<mpsc::Sender<String>>> = Mutex::new(None);

#[derive(Clone, Copy)]
struct Sink {
    ctx: usize,
    cb: CocoRamEventCallback,
}

impl Sink {
    fn send(&self, kind: i32, message: &str) {
        let text = CString::new(message.replace('\0', " ")).unwrap_or_default();
        (self.cb)(self.ctx as *mut c_void, kind, text.as_ptr());
    }
}

unsafe fn c_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

/// Answer to a 2FA request: the code, "d" (send to devices), "r" (resend), "p<id>" (SMS to that
/// trusted number) or "cancel".
#[no_mangle]
pub unsafe extern "C" fn cocoram_submit_two_factor(reply: *const c_char) {
    let reply = c_string(reply);
    if let Some(sender) = TWO_FACTOR_REPLY.lock().unwrap().as_ref() {
        let _ = sender.send(reply);
    }
}

/// Runs the whole flow on a background thread; events arrive through `cb` (on that thread).
#[no_mangle]
pub unsafe extern "C" fn cocoram_start(
    apple_id: *const c_char,
    password: *const c_char,
    bundle_id: *const c_char,
    storage_dir: *const c_char,
    ctx: *mut c_void,
    cb: CocoRamEventCallback,
) {
    let apple_id = c_string(apple_id);
    let password = c_string(password);
    let bundle_id = c_string(bundle_id);
    let storage_dir = PathBuf::from(c_string(storage_dir));
    let sink = Sink { ctx: ctx as usize, cb };

    std::thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .map_err(|e| format!("tokio: {e}"))?;
            runtime.block_on(run(apple_id, password, bundle_id, storage_dir, sink))
        }));
        *TWO_FACTOR_REPLY.lock().unwrap() = None;
        match result {
            Ok(Ok(message)) => sink.send(EV_DONE, &message),
            Ok(Err(message)) => sink.send(EV_ERROR, &message),
            Err(_) => sink.send(EV_ERROR, "internal error (panic)"),
        }
    });
}

async fn run(
    apple_id: String,
    password: String,
    bundle_id: String,
    storage_dir: PathBuf,
    sink: Sink,
) -> Result<String, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();

    let (reply_tx, reply_rx) = mpsc::channel::<String>();
    *TWO_FACTOR_REPLY.lock().unwrap() = Some(reply_tx);
    let reply_rx = Arc::new(Mutex::new(reply_rx));

    let two_factor = move |params: TwoFactorCallbackParams| {
        let reply_rx = reply_rx.clone();
        async move {
            let numbers: Vec<serde_json::Value> = params
                .numbers
                .iter()
                .map(|n| serde_json::json!({ "id": n.id, "number": n.number_with_dial_code }))
                .collect();
            let selected = params
                .selected_number_id
                .and_then(|id| params.numbers.iter().find(|n| n.id == id))
                .map(|n| n.number_with_dial_code.clone());
            let request = serde_json::json!({
                "sms": params.sms,
                "unknown": params.unknown,
                "selected": selected,
                "numbers": numbers,
                "error": params.last_error,
            });
            sink.send(EV_TWO_FACTOR, &request.to_string());
            // Wait (off the async workers) for the player's answer, up to 10 minutes
            let answer = tokio::task::spawn_blocking(move || {
                reply_rx.lock().unwrap().recv_timeout(Duration::from_secs(600))
            })
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_else(|| "cancel".to_string());
            let answer = answer.trim().to_string();
            let response = if answer == "cancel" {
                TwoFactorCallbackResponse::Abort
            } else if answer == "d" {
                TwoFactorCallbackResponse::SendToDevices
            } else if answer == "r" {
                TwoFactorCallbackResponse::ResendCode
            } else if let Some(id) = answer.strip_prefix('p').and_then(|s| s.parse::<u32>().ok()) {
                TwoFactorCallbackResponse::SendSms(id)
            } else {
                TwoFactorCallbackResponse::SubmitCode(answer)
            };
            Ok(response)
        }
    };

    sink.send(EV_PROGRESS, "login");
    let anisette = RemoteV3AnisetteProvider::new(
        DEFAULT_ANISETTE_V3_URL,
        Box::new(FsStorage::new(storage_dir)),
        "0".to_string(),
    )
    .map_err(|e| format!("anisette: {e}"))?;
    let mut account = AppleAccount::builder(&apple_id)
        .anisette_provider(anisette)
        .login(&password, two_factor)
        .await
        .map_err(|e| format!("login: {e}"))?;
    drop(password);

    sink.send(EV_PROGRESS, "teams");
    let mut session = DeveloperSession::from_account(&mut account)
        .await
        .map_err(|e| format!("developer session: {e}"))?;
    let teams = session.list_teams().await.map_err(|e| format!("teams: {e}"))?;
    if teams.is_empty() {
        return Err("no-team".to_string());
    }

    sink.send(EV_PROGRESS, "appids");
    let mut seen: Vec<String> = Vec::new();
    for team in &teams {
        let list = session
            .list_app_ids(team, None)
            .await
            .map_err(|e| format!("app ids: {e}"))?;
        for app_id in &list.app_ids {
            seen.push(app_id.identifier.clone());
            if app_id.identifier.eq_ignore_ascii_case(&bundle_id) {
                sink.send(EV_PROGRESS, "enable");
                session
                    .add_increased_memory_limit(team, app_id)
                    .await
                    .map_err(|e| format!("enable: {e}"))?;
                return Ok(format!("{}|{}", app_id.identifier, team.team_id));
            }
        }
    }
    Err(format!("no-appid|{}|{}", bundle_id, seen.join(",")))
}
