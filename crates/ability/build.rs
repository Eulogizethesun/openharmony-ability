fn main() {
  let target_env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
  if target_env == "ohos" {
    let device_type = std::env::var("TAURI_OHOS_DEVICE_TYPE").unwrap_or_else(|_| "mobile".to_string());
    let is_desktop = device_type == "desktop";
    println!("cargo:rustc-check-cfg=cfg(desktop)");
    println!("cargo:rustc-check-cfg=cfg(mobile)");
    if is_desktop {
      println!("cargo:rustc-cfg=desktop");
    } else {
      println!("cargo:rustc-cfg=mobile");
    }
  }
}