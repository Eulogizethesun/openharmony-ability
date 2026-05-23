//! OHOS Menu module
//!
//! This module provides:
//! - Rust API: menu_event_receiver() for muda to listen events
//! - Rust API: popup_context_menu() for muda to show popup menu
//! - Rust API: set_menu_json() for muda to set menubar data
//! - Rust API: menu_request_receiver() for ArkTS to listen menu requests (popup + menubar)
//! - Rust API: set_menubar_visible/is_menubar_visible/notify_menubar_visibility for per-window visibility
//! - NAPI API: emit_menu_event() for ArkTS to send events
//! - NAPI API: on_menu_request() for ArkTS to register unified menu callback (popup + menubar)
//! - NAPI API: notify_menubar_visibility() for ArkTS to sync visibility to Rust
//! - NAPI API: is_desktop_device() for ArkTS to detect device type (in app.rs)
//! - Menu types: MenuItemData (data struct for serialization)
//! - Menu request: MenuRequest / MenuRequestData (unified popup + menubar + visibility)
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
pub use types::AboutMetadataData;

// NAPI types for ArkTS
pub use popup::MenuPopup;
pub use predefined::PredefinedMenuItem;
pub use state::MenuStateController;
pub use types::{Menu, MenuItem, Submenu};

use crossbeam_channel::{unbounded, Receiver, Sender};
use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::threadsafe_function::{ThreadsafeCallContext, ThreadsafeFunction, ThreadsafeFunctionCallMode};
use std::collections::HashMap;
use std::sync::LazyLock;
use std::sync::Mutex;
use std::sync::RwLock;

/// Menu request data (unified popup + menubar + visibility)
#[derive(Debug, Clone)]
pub struct MenuRequest {
    pub json_data: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub visible: Option<bool>,
    pub window_id: String,
}

// Per-window menubar visibility state (default true for each window)
static MENUBAR_VISIBLE: LazyLock<RwLock<HashMap<String, bool>>> = LazyLock::new(|| RwLock::new(HashMap::new()));

// Event channel: ArkTS → muda
static MENU_EVENT_CHANNEL: LazyLock<(Sender<String>, Receiver<String>)> = LazyLock::new(unbounded);

// Menu channel: muda → ArkTS (unified for popup + menubar + visibility)
static MENU_CHANNEL: LazyLock<(Sender<MenuRequest>, Receiver<MenuRequest>)> =
    LazyLock::new(unbounded);

// Menu callback: Rust → ArkTS (CalleeHandled=false → JS callback: (data) => void)
type MenuTsfn = ThreadsafeFunction<MenuRequestData, Unknown<'static>, FnArgs<(MenuRequestData,)>, Status, false>;
static MENU_CALLBACK: Mutex<Option<MenuTsfn>> = Mutex::new(None);

// Buffer last menubar JSON per window so we can replay on callback registration
static LAST_MENUBAR_JSON: LazyLock<Mutex<HashMap<String, String>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

/// Menu request data for NAPI (unified popup + menubar + visibility)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[napi(object)]
pub struct MenuRequestData {
    pub json_data: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visible: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
}

/// Backward compat: PopupRequestData is now MenuRequestData
pub type PopupRequestData = MenuRequestData;

/// Rust API: Get menu event receiver (for muda)
pub fn menu_event_receiver() -> &'static Receiver<String> {
    &MENU_EVENT_CHANNEL.1
}

/// Rust API: Get menu request receiver (unified popup + menubar + visibility)
pub fn menu_request_receiver() -> &'static Receiver<MenuRequest> {
    &MENU_CHANNEL.1
}

/// Backward compat: Get popup request receiver (same as menu_request_receiver)
pub fn popup_request_receiver() -> &'static Receiver<MenuRequest> {
    &MENU_CHANNEL.1
}

/// NAPI API: Emit menu event from ArkTS
#[napi]
pub fn emit_menu_event(menu_id: String, #[napi(ts_arg_type = "string | undefined")] window_id: Option<String>) {
    MENU_EVENT_CHANNEL.0.send(menu_id.clone()).ok();
    dispatch_menu_event(&MenuEvent::new(menu_id, window_id));
}

/// NAPI API: Notify menubar visibility from ArkTS (sync per-window state to Rust)
#[napi]
pub fn notify_menubar_visibility(window_id: String, visible: bool) {
    let mut map = MENUBAR_VISIBLE.write().unwrap();
    map.insert(window_id, visible);
}

/// Rust API: Check if menubar is visible for a specific window (default true)
pub fn is_menubar_visible(window_id: &str) -> bool {
    let map = MENUBAR_VISIBLE.read().unwrap();
    map.get(window_id).copied().unwrap_or(true)
}

/// Rust API: Set menubar visibility and push to ArkTS via TSFN
pub fn set_menubar_visible(visible: bool, window_id: String) -> Result<()> {
    {
        let mut map = MENUBAR_VISIBLE.write().unwrap();
        map.insert(window_id.clone(), visible);
    }
    MENU_CHANNEL.0.send(MenuRequest {
        json_data: "".to_string(),
        x: None,
        y: None,
        visible: Some(visible),
        window_id,
    }).ok();
    Ok(())
}

/// NAPI API: Register unified menu callback from ArkTS
#[napi(ts_args_type = "callback: (data: MenuRequestData) => void")]
pub fn on_menu_request(callback: Function<'static>) -> Result<()> {
    log::debug!("[Menu] on_menu_request called from ArkTS");
    let tsfn: MenuTsfn = callback
        .build_threadsafe_function::<MenuRequestData>()
        .callee_handled::<false>()
        .build_callback(|ctx: ThreadsafeCallContext<MenuRequestData>| {
            Ok(FnArgs { data: (ctx.value,) })
        })?;

    // Replay buffered menubar JSON for all windows
    if let Ok(buffer) = LAST_MENUBAR_JSON.lock() {
        for (window_id, json_data) in buffer.iter() {
            if !json_data.is_empty() {
                log::debug!("[Menu] replaying buffered menubar for window_id={}", window_id);
                let data = MenuRequestData {
                    json_data: json_data.clone(),
                    x: None,
                    y: None,
                    visible: None,
                    window_id: Some(window_id.clone()),
                };
                tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
            }
        }
    }

    let mut guard = MENU_CALLBACK.lock().map_err(|_| Error::from_reason("lock poisoned"))?;
    *guard = Some(tsfn);
    log::debug!("[Menu] on_menu_request: callback registered successfully");
    Ok(())
}

/// Backward compat: Keep old on_popup_request as wrapper
#[napi(ts_args_type = "callback: (data: MenuRequestData) => void")]
pub fn on_popup_request(callback: Function<'static>) -> Result<()> {
    on_menu_request(callback)
}

/// Start background thread to forward menu requests to ArkTS (unified)
pub fn start_menu_forwarder() {
    log::debug!("[Menu] start_menu_forwarder called");
    std::thread::spawn(|| {
        log::debug!("[Menu] forwarder thread started");
        let receiver = menu_request_receiver();
        while let Ok(req) = receiver.recv() {
            log::debug!("[Menu] forwarder received request, json_len={}, window_id={}", req.json_data.len(), req.window_id);
            let guard = MENU_CALLBACK.lock().ok();
            if let Some(tsfn) = guard.as_ref().and_then(|opt| opt.as_ref()) {
                let data = MenuRequestData {
                    json_data: req.json_data,
                    x: req.x,
                    y: req.y,
                    visible: req.visible,
                    window_id: Some(req.window_id),
                };
                log::debug!("[Menu] calling TSFN with x={:?}, y={:?}, visible={:?}, window_id={:?}", data.x, data.y, data.visible, data.window_id);
                tsfn.call(data, ThreadsafeFunctionCallMode::NonBlocking);
            } else {
                log::debug!("[Menu] forwarder: MENU_CALLBACK is None");
            }
        }
    });
}

/// Backward compat: Keep old start_popup_forwarder as wrapper
pub fn start_popup_forwarder() {
    start_menu_forwarder()
}

/// Rust API: Popup context menu (for muda) — x/y coordinates present
pub fn popup_context_menu(json_data: String, x: Option<f64>, y: Option<f64>, window_id: String) -> Result<()> {
    log::debug!("[Menu] popup_context_menu called: x={x:?}, y={y:?}, window_id={window_id}, json_len={}", json_data.len());
    MENU_CHANNEL.0.send(MenuRequest { json_data, x, y, visible: None, window_id }).ok();
    Ok(())
}

/// Rust API: Set menu bar JSON (for menubar) — x/y/visible absent
pub fn set_menu_json(json_data: String, window_id: String) -> Result<()> {
    log::debug!("[Menu] set_menu_json called: window_id={window_id}, json_len={}", json_data.len());
    if let Ok(mut buffer) = LAST_MENUBAR_JSON.lock() {
        buffer.insert(window_id.clone(), json_data.clone());
    }
    MENU_CHANNEL.0.send(MenuRequest { json_data, x: None, y: None, visible: None, window_id }).ok();
    Ok(())
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    fn drain_menu_channel() {
        while MENU_CHANNEL.1.try_recv().is_ok() {}
    }

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
    fn test_menu_channel_popup() {
        let request = MenuRequest {
            json_data: "{\"items\":[]}".to_string(),
            x: Some(100.0),
            y: Some(200.0),
            visible: None,
            window_id: "main".to_string(),
        };
        MENU_CHANNEL.0.send(request.clone()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.json_data, request.json_data);
        assert_eq!(received.x, Some(100.0));
        assert_eq!(received.y, Some(200.0));
        assert_eq!(received.visible, None);
        assert_eq!(received.window_id, "main");
    }

    #[test]
    fn test_menu_channel_menubar() {
        let request = MenuRequest {
            json_data: "[{\"type\":\"submenu\",\"text\":\"File\"}]".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: "main".to_string(),
        };
        MENU_CHANNEL.0.send(request.clone()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.json_data, request.json_data);
        assert_eq!(received.x, None);
        assert_eq!(received.y, None);
        assert_eq!(received.visible, None);
        assert_eq!(received.window_id, "main");
    }

    #[test]
    fn test_menu_channel_visibility_hide() {
        let request = MenuRequest {
            json_data: "".to_string(),
            x: None,
            y: None,
            visible: Some(false),
            window_id: "main".to_string(),
        };
        MENU_CHANNEL.0.send(request.clone()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.visible, Some(false));
        assert_eq!(received.window_id, "main");
    }

    #[test]
    fn test_menu_channel_visibility_show() {
        let request = MenuRequest {
            json_data: "".to_string(),
            x: None,
            y: None,
            visible: Some(true),
            window_id: "main".to_string(),
        };
        MENU_CHANNEL.0.send(request.clone()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.visible, Some(true));
    }

    #[test]
    fn test_menu_request_data_serde() {
        let data = MenuRequestData {
            json_data: "test".to_string(),
            x: Some(50.0),
            y: Some(100.0),
            visible: None,
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&data).unwrap();
        assert!(json.contains("\"x\":50.0"));
        assert!(json.contains("\"y\":100.0"));
        assert!(json.contains("\"window_id\":\"main\""));
        assert!(!json.contains("\"visible\":"));

        let data_no_coords = MenuRequestData {
            json_data: "test".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: None,
        };
        let json_no_coords = serde_json::to_string(&data_no_coords).unwrap();
        assert!(!json_no_coords.contains("\"x\":"));
        assert!(!json_no_coords.contains("\"y\":"));
        assert!(!json_no_coords.contains("\"visible\":"));
        assert!(!json_no_coords.contains("\"window_id\":"));
    }

    #[test]
    fn test_menu_request_data_visible_serde() {
        let data_visible = MenuRequestData {
            json_data: "".to_string(),
            x: None,
            y: None,
            visible: Some(true),
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&data_visible).unwrap();
        assert!(json.contains("\"visible\":true"));
        assert!(json.contains("\"window_id\":\"main\""));

        let data_no_visible = MenuRequestData {
            json_data: "".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: Some("main".to_string()),
        };
        let json_no_visible = serde_json::to_string(&data_no_visible).unwrap();
        assert!(!json_no_visible.contains("\"visible\":"));
    }

    #[test]
    fn test_menu_request_data_window_id_serde() {
        let data_with = MenuRequestData {
            json_data: "test".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&data_with).unwrap();
        assert!(json.contains("\"window_id\":\"main\""));

        let data_without = MenuRequestData {
            json_data: "test".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: None,
        };
        let json = serde_json::to_string(&data_without).unwrap();
        assert!(!json.contains("\"window_id\":"));
    }

    #[test]
    fn test_menubar_visible_default_true() {
        assert!(is_menubar_visible("unknown_window"));
    }

    #[test]
    fn test_menubar_visible_per_window() {
        set_menubar_visible(false, "A".to_string()).ok();
        assert!(!is_menubar_visible("A"));
        assert!(is_menubar_visible("B"));
        set_menubar_visible(true, "A".to_string()).ok();
        assert!(is_menubar_visible("A"));
    }

    #[test]
    fn test_menubar_visible_sends_channel_request() {
        drain_menu_channel();
        MENUBAR_VISIBLE.write().unwrap().remove("test_vis_ch");
        set_menubar_visible(false, "test_vis_ch".to_string()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.visible, Some(false));
        assert_eq!(received.window_id, "test_vis_ch");
        assert!(received.json_data.is_empty());
        assert!(received.x.is_none());
        assert!(received.y.is_none());
    }

    #[test]
    fn test_set_menu_json_with_window_id() {
        drain_menu_channel();
        let json = "[{\"type\":\"submenu\",\"text\":\"Edit\",\"id\":\"edit\"}]";
        set_menu_json(json.to_string(), "win1".to_string()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.json_data, json);
        assert_eq!(received.window_id, "win1");
        assert!(received.visible.is_none());
        assert!(received.x.is_none());
    }

    #[test]
    fn test_popup_context_menu_with_window_id() {
        drain_menu_channel();
        popup_context_menu("{\"items\":[]}".to_string(), Some(50.0), Some(100.0), "win2".to_string()).unwrap();
        let received = MENU_CHANNEL.1.recv().unwrap();
        assert_eq!(received.x, Some(50.0));
        assert_eq!(received.y, Some(100.0));
        assert_eq!(received.window_id, "win2");
        assert!(received.visible.is_none());
    }

    #[test]
    fn test_menu_request_data_full_roundtrip() {
        let original = MenuRequestData {
            json_data: "[{\"type\":\"submenu\"}]".to_string(),
            x: Some(200.0),
            y: Some(300.0),
            visible: Some(true),
            window_id: Some("main".to_string()),
        };
        let json = serde_json::to_string(&original).unwrap();
        let deserialized: MenuRequestData = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.json_data, original.json_data);
        assert_eq!(deserialized.x, Some(200.0));
        assert_eq!(deserialized.y, Some(300.0));
        assert_eq!(deserialized.visible, Some(true));
        assert_eq!(deserialized.window_id, Some("main".to_string()));
    }

    #[test]
    fn test_menu_request_data_skip_none_fields() {
        let data = MenuRequestData {
            json_data: "[]".to_string(),
            x: None,
            y: None,
            visible: None,
            window_id: None,
        };
        let json = serde_json::to_string(&data).unwrap();
        assert!(!json.contains("\"x\""));
        assert!(!json.contains("\"y\""));
        assert!(!json.contains("\"visible\""));
        assert!(!json.contains("\"window_id\""));
        let deserialized: MenuRequestData = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.json_data, "[]");
        assert!(deserialized.x.is_none());
        assert!(deserialized.y.is_none());
        assert!(deserialized.visible.is_none());
        assert!(deserialized.window_id.is_none());
    }

    #[test]
    fn test_menubar_visible_independent_windows() {
        MENUBAR_VISIBLE.write().unwrap().clear();
        assert!(is_menubar_visible("winA"));
        assert!(is_menubar_visible("winB"));
        set_menubar_visible(false, "winA".to_string()).unwrap();
        assert!(!is_menubar_visible("winA"));
        assert!(is_menubar_visible("winB"));
        set_menubar_visible(false, "winB".to_string()).unwrap();
        assert!(!is_menubar_visible("winA"));
        assert!(!is_menubar_visible("winB"));
    }

    #[test]
    fn test_notify_menubar_visibility_updates_state() {
        MENUBAR_VISIBLE.write().unwrap().remove("notify_test");
        notify_menubar_visibility("notify_test".to_string(), false);
        assert!(!is_menubar_visible("notify_test"));
        notify_menubar_visibility("notify_test".to_string(), true);
        assert!(is_menubar_visible("notify_test"));
    }
}
