use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use serde::{Deserialize, Serialize};

#[napi(object)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MenuItemData {
    pub id: String,
    #[napi(js_name = "type")]
    #[serde(rename = "type")]
    pub item_type: String,
    pub text: Option<String>,
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accelerator: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "predefinedType")]
    pub predefined_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[napi(js_name = "submenuItems")]
    #[serde(rename = "submenuItems")]
    pub submenu_items: Option<Vec<MenuItemData>>,
}

#[napi]
pub struct Menu {
    id: String,
    items: Vec<MenuItemData>,
}

#[napi]
impl Menu {
    #[napi(constructor)]
    pub fn new(id: Option<String>) -> Self {
        Self {
            id: id.unwrap_or_else(|| format!("menu_{}", uuid::Uuid::new_v4())),
            items: vec![],
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn append(&mut self, item: MenuItemData) -> Result<()> {
        self.items.push(item);
        Ok(())
    }

    #[napi]
    pub fn items(&self) -> Vec<MenuItemData> {
        self.items.clone()
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "menu".to_string(),
            text: None,
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            submenu_items: Some(self.items.clone()),
        }
    }
}

#[napi]
pub struct MenuItem {
    id: String,
    text: String,
    enabled: bool,
    accelerator: Option<String>,
}

#[napi]
impl MenuItem {
    #[napi(constructor)]
    pub fn new(
        id: Option<String>,
        text: String,
        enabled: Option<bool>,
        accelerator: Option<String>,
    ) -> Self {
        Self {
            id: id.unwrap_or_else(|| format!("item_{}", uuid::Uuid::new_v4())),
            text,
            enabled: enabled.unwrap_or(true),
            accelerator,
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn text(&self) -> String {
        self.text.clone()
    }

    #[napi]
    pub fn set_text(&mut self, text: String) {
        self.text = text;
    }

    #[napi]
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    #[napi]
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "item".to_string(),
            text: Some(self.text.clone()),
            enabled: Some(self.enabled),
            accelerator: self.accelerator.clone(),
            predefined_type: None,
            checked: None,
            icon: None,
            submenu_items: None,
        }
    }
}

#[napi]
pub struct Submenu {
    id: String,
    text: String,
    items: Vec<MenuItemData>,
}

#[napi]
impl Submenu {
    #[napi(constructor)]
    pub fn new(id: Option<String>, text: String) -> Self {
        Self {
            id: id.unwrap_or_else(|| format!("submenu_{}", uuid::Uuid::new_v4())),
            text,
            items: vec![],
        }
    }

    #[napi]
    pub fn id(&self) -> String {
        self.id.clone()
    }

    #[napi]
    pub fn text(&self) -> String {
        self.text.clone()
    }

    #[napi]
    pub fn set_text(&mut self, text: String) {
        self.text = text;
    }

    #[napi]
    pub fn append(&mut self, item: MenuItemData) -> Result<()> {
        self.items.push(item);
        Ok(())
    }

    #[napi]
    pub fn items(&self) -> Vec<MenuItemData> {
        self.items.clone()
    }

    pub fn to_data(&self) -> MenuItemData {
        MenuItemData {
            id: self.id.clone(),
            item_type: "submenu".to_string(),
            text: Some(self.text.clone()),
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            submenu_items: Some(self.items.clone()),
        }
    }
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;

    #[test]
    fn test_menu_item_data_creation() {
        let data = MenuItemData {
            id: "item1".to_string(),
            item_type: "item".to_string(),
            text: Some("File".to_string()),
            enabled: Some(true),
            accelerator: Some("Ctrl+F".to_string()),
            predefined_type: None,
            checked: None,
            icon: None,
            submenu_items: None,
        };
        assert_eq!(data.id, "item1");
        assert_eq!(data.item_type, "item");
    }

    #[test]
    fn test_submenu_nested_items() {
        let submenu_data = MenuItemData {
            id: "submenu_1".to_string(),
            item_type: "submenu".to_string(),
            text: Some("File".to_string()),
            enabled: Some(true),
            accelerator: None,
            predefined_type: None,
            checked: None,
            icon: None,
            submenu_items: Some(vec![MenuItemData {
                id: "item_1".to_string(),
                item_type: "item".to_string(),
                text: Some("Open".to_string()),
                enabled: Some(true),
                accelerator: None,
                predefined_type: None,
                checked: None,
                icon: None,
                submenu_items: None,
            }]),
        };
        assert!(submenu_data.submenu_items.is_some());
        assert_eq!(submenu_data.submenu_items.unwrap().len(), 1);
    }

    #[test]
    fn test_menu_creation() {
        let menu = Menu::new(None);
        assert!(menu.id.starts_with("menu_"));
    }

    #[test]
    fn test_menu_item_creation() {
        let item = MenuItem::new(None, "Test".to_string(), None, Some("Ctrl+T".to_string()));
        assert!(item.id.starts_with("item_"));
        assert_eq!(item.text, "Test");
        assert_eq!(item.accelerator, Some("Ctrl+T".to_string()));
    }
}
