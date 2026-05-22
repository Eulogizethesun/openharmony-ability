//! OHOS Menu module
//!
//! This module provides:
//! - Rust API: menu_event_receiver() for muda to listen events
//! - Rust API: popup_context_menu() for muda to show menu
//! - Rust API: popup_request_receiver() for ArkTS to listen popup requests
//! - NAPI API: emit_menu_event() for ArkTS to send events
//! - Menu types: MenuItemData (data struct for serialization)
//! - NAPI types: Menu, MenuItem, Submenu (for ArkTS direct use)
//! - Predefined items: PredefinedMenuItem, PredefinedType
//! - Event dispatcher: MenuEvent, MenuEventDispatcher
//! - State controller: MenuStateController
//! - Popup: MenuPopup

mod event;
mod popup;
mod predefined;
mod state;
mod types;

// Public API for muda (Rust only)
pub use event::{add_menu_event_listener, dispatch_menu_event, MenuEvent, MenuEventDispatcher};
pub use types::MenuItemData;

// NAPI types for ArkTS
pub use popup::MenuPopup;
pub use predefined::PredefinedMenuItem;
pub use state::MenuStateController;
pub use types::{Menu, MenuItem, Submenu};

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode};
use std::sync::LazyLock;
use std::sync::Mutex;

/// Popup request data
#[derive(Debug, Clone)]
pub struct PopupRequest {
    pub json_data: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
}

// Event channel: ArkTS → muda
static MENU_EVENT_CHANNEL: LazyLock<(Sender<String>, Receiver<String>)> = LazyLock::new(unbounded);

// Popup channel: muda → ArkTS
static POPUP_CHANNEL: LazyLock<(Sender<PopupRequest>, Receiver<PopupRequest>)> =
    LazyLock::new(unbounded);

// Popup callback: Rust → ArkTS (callee_handled=false, so JS callback is `(data) => void`)
type PopupTsfn = ThreadsafeFunction<PopupRequestData, Unknown<'static>, FnArgs<(PopupRequestData,)>, Status, false>;
static POPUP_CALLBACK: Mutex<Option<PopupTsfn>> = Mutex::new(None);

/// Popup request data for NAPI
#[derive(Debug, Clone, serde::Serialize)]
#[napi(object)]
pub struct PopupRequestData {
    pub json_data: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
}

/// Rust API: Get menu event receiver (for muda)
pub fn menu_event_receiver() -> &'static Receiver<String> {
    &MENU_EVENT_CHANNEL.1
}

/// Rust API: Get popup request receiver (for ArkTS NAPI)
pub fn popup_request_receiver() -> &'static Receiver<PopupRequest> {
    &POPUP_CHANNEL.1
}

/// NAPI API: Emit menu event from ArkTS
#[napi]
pub fn emit_menu_event(menu_id: String) {
    MENU_EVENT_CHANNEL.0.send(menu_id.clone()).ok();
    dispatch_menu_event(&MenuEvent::new(menu_id));
}

/// NAPI API: Register popup callback from ArkTS
#[napi(ts_args_type = "callback: (data: PopupRequestData) => void")]
pub fn on_popup_request(callback: Function<'static>) -> Result<()> {
    log::debug!("[Menu] on_popup_request called from ArkTS");
    let tsfn: PopupTsfn = callback
        .build_threadsafe_function::<PopupRequestData>()
        .callee_handled::<false>()
        .build_callback(|ctx: ThreadsafeCallContext<PopupRequestData>| {
            Ok(FnArgs { data: (ctx.value,) })
        })?;
    let mut guard = POPUP_CALLBACK.lock().map_err(|_| Error::from_reason("lock poisoned"))?;
    *guard = Some(tsfn);
    log::debug!("[Menu] on_popup_request: callback registered successfully");
    Ok(())
}

/// Start background thread to forward popup requests to ArkTS
pub fn start_popup_forwarder() {
    log::debug!("[Menu] start_popup_forwarder called");
    std::thread::spawn(|| {
        log::debug!("[Menu] forwarder thread started");
        let receiver = popup_request_receiver();
        while let Ok(req) = receiver.recv() {
            log::debug!("[Menu] forwarder received request, json_len={}", req.json_data.len());
            let guard = POPUP_CALLBACK.lock().ok();
            if let Some(tsfn) = guard.as_ref().and_then(|opt| opt.as_ref()) {
                let data = PopupRequestData {
                    json_data: req.json_data,
                    x: req.x,
                    y: req.y,
                };
                log::debug!("[Menu] calling TSFN with x={:?}, y={:?}", data.x, data.y);
                tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
            } else {
                log::debug!("[Menu] forwarder: POPUP_CALLBACK is None");
            }
        }
    });
}

/// Rust API: Popup context menu (for muda)
pub fn popup_context_menu(json_data: String, x: Option<f64>, y: Option<f64>) -> Result<()> {
    log::debug!("[Menu] popup_context_menu called: x={x:?}, y={y:?}, json_len={}", json_data.len());
    POPUP_CHANNEL.0.send(PopupRequest { json_data, x, y }).ok();
    Ok(())
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_menu_event_channel() {
        MENU_EVENT_CHANNEL
            .0
            .send("test_menu_id".to_string())
            .unwrap();
        let received = MENU_EVENT_CHANNEL.1.recv().unwrap();
        assert_eq!(received, "test_menu_id");
    }

    #[test]
    fn test_popup_channel() {
        let request = PopupRequest {
            json_data: "{\"items\":[]}".to_string(),
            x: Some(100.0),
            y: Some(200.0),
        };
        POPUP_CHANNEL.0.send(request.clone()).unwrap();
        let received = POPUP_CHANNEL.1.recv().unwrap();
        assert_eq!(received.json_data, request.json_data);
        assert_eq!(received.x, Some(100.0));
        assert_eq!(received.y, Some(200.0));
    }
}
