use napi_ohos::bindgen_prelude::*;
use crate::{get_helper, get_main_thread_env};
use log;
use std::sync::atomic::{AtomicI64, Ordering};

/// Global window ID generator to ensure unique IDs across Rust and ArkTS.
static NEXT_WINDOW_ID: AtomicI64 = AtomicI64::new(1);

/// Creates a new OS-level window on OpenHarmony.
pub fn create_os_window(name: String, window_type: i32) -> napi_ohos::Result<i64> {
    // 1. Synchronously allocate a unique ID
    let id = NEXT_WINDOW_ID.fetch_add(1, Ordering::SeqCst);
    log::info!("Pre-allocated window ID: {}", id);
    
    let ret = unsafe { get_helper() };
    if let Some(h) = ret.borrow().as_ref() {
        if let Some(env) = get_main_thread_env().borrow().as_ref() {
            let obj = h.get_value(env).map_err(|e| {
                log::error!("Failed to get helper object value: {:?}", e);
                e
            })?;

            let func = match obj.get_named_property::<Function<'_, Object, Unknown>>("createOSWindow") {
                Ok(f) => f,
                Err(e) => {
                    log::error!("Property 'createOSWindow' NOT FOUND on helper: {:?}", e);
                    return Err(e);
                }
            };
            
            log::info!("Successfully found createOSWindow, building config object...");

            // 2. Create config object and pass the pre-allocated ID
            let mut config = Object::new(env)?;
            config.set("name", name)?;
            config.set("type", window_type)?;
            config.set("windowId", id)?;
            
            config.set("width", 800)?;
            config.set("height", 600)?;
            config.set("x", 100)?;
            config.set("y", 100)?;
            
            log::info!("Calling ArkTS with config object...");
            
            // 3. Call ArkTS and return the ID on success
            match func.call(config) {
                Ok(_) => {
                    log::info!("ArkTS call succeeded, returning ID: {}", id);
                    return Ok(id);
                }
                Err(e) => {
                    log::error!("ArkTS call failed: {:?}", e);
                    return Err(e);
                }
            }
        } else {
            log::error!("Main thread env not available");
        }
    } else {
        log::error!("Helper object not initialized");
    }
    Err(Error::from_reason("Helper or Env not initialized"))
}
