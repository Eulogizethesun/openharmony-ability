mod app;
mod area;
mod configuration;
mod draw;
mod error;
mod event;
mod helper;
mod input;
mod lifecycle;
mod memory;
mod render;
mod resource;
mod stage;
pub mod statusbar;
mod waker;

#[cfg(feature = "webview")]
mod webview;

#[cfg(feature = "menu")]
pub mod menu;

#[cfg(feature = "menu")]
pub use menu::{on_popup_request, start_popup_forwarder, PopupRequestData};

pub use app::*;
pub use area::*;
pub use configuration::*;
pub use draw::*;
pub use error::*;
pub use event::*;
pub use helper::*;
pub use input::*;
pub use lifecycle::*;
pub use memory::*;
pub use render::*;
pub use resource::*;
pub use stage::*;
pub use statusbar::*;
pub use waker::*;

#[cfg(feature = "webview")]
pub use webview::*;

// re-export arkui and avoid the need to import it in the lib.rs
pub use ohos_arkui_binding as arkui;
pub use ohos_ime_binding as ime;
pub use ohos_resource_manager_binding as resource_manager;
pub use ohos_xcomponent_binding as xcomponent;

#[cfg(feature = "webview")]
pub use ohos_web_binding as native_web;
