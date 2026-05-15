use std::sync::{Arc, LazyLock, Mutex};

pub struct MenuEvent {
    pub id: String,
}

impl MenuEvent {
    pub fn new(id: String) -> Self {
        Self { id }
    }

    pub fn id(&self) -> &str {
        &self.id
    }
}

pub type MenuEventListener = Arc<dyn Fn(&MenuEvent) + Send + Sync>;

pub struct MenuEventDispatcher {
    listeners: Vec<MenuEventListener>,
}

impl MenuEventDispatcher {
    pub fn new() -> Self {
        Self { listeners: vec![] }
    }

    pub fn add_listener<F: Fn(&MenuEvent) + Send + Sync + 'static>(&mut self, listener: F) {
        self.listeners.push(Arc::new(listener));
    }

    pub fn dispatch(&self, event: &MenuEvent) {
        for listener in &self.listeners {
            listener(event);
        }
    }
}

impl Default for MenuEventDispatcher {
    fn default() -> Self {
        Self::new()
    }
}

static GLOBAL_DISPATCHER: LazyLock<Mutex<MenuEventDispatcher>> =
    LazyLock::new(|| Mutex::new(MenuEventDispatcher::new()));

pub fn add_menu_event_listener<F: Fn(&MenuEvent) + Send + Sync + 'static>(listener: F) {
    let mut dispatcher = GLOBAL_DISPATCHER.lock().unwrap();
    dispatcher.add_listener(listener);
}

pub fn dispatch_menu_event(event: &MenuEvent) {
    let dispatcher = GLOBAL_DISPATCHER.lock().unwrap();
    dispatcher.dispatch(event);
}

#[cfg(all(test, target_env = "ohos"))]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn test_menu_event_creation() {
        let event = MenuEvent::new("item123".to_string());
        assert_eq!(event.id(), "item123");
    }

    #[test]
    fn test_menu_event_dispatcher() {
        let mut dispatcher = MenuEventDispatcher::new();
        let count = Arc::new(AtomicUsize::new(0));

        dispatcher.add_listener({
            let count = count.clone();
            move |_| {
                count.fetch_add(1, Ordering::SeqCst);
            }
        });

        let event = MenuEvent::new("test_item".to_string());
        dispatcher.dispatch(&event);

        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn test_multiple_listeners() {
        let mut dispatcher = MenuEventDispatcher::new();
        let count1 = Arc::new(AtomicUsize::new(0));
        let count2 = Arc::new(AtomicUsize::new(0));

        dispatcher.add_listener({
            let count = count1.clone();
            move |_| {
                count.fetch_add(1, Ordering::SeqCst);
            }
        });

        dispatcher.add_listener({
            let count = count2.clone();
            move |_| {
                count.fetch_add(1, Ordering::SeqCst);
            }
        });

        let event = MenuEvent::new("item".to_string());
        dispatcher.dispatch(&event);

        assert_eq!(count1.load(Ordering::SeqCst), 1);
        assert_eq!(count2.load(Ordering::SeqCst), 1);
    }
}
