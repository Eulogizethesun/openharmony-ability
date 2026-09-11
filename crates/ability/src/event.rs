use std::fmt::{self, Debug, Formatter};
use std::sync::atomic::{AtomicBool, Ordering};

use crate::{
    AvoidAreaInfo, Configuration, ContentRect, InputEvent, IntervalInfo, SaveLoader, SaveSaver,
    Size,
};

/// Answer slot for the PC/2in1 prepare-to-terminate probe
/// ([`Event::PrepareToTerminate`]).
///
/// A dedicated type (instead of a bare `AtomicBool`) so it can implement
/// `PartialEq` — downstream event enums that embed `&TerminateAnswer` (tao's
/// `Event`) keep deriving `PartialEq`/`Clone`/`Debug` over their variants.
/// Comparison is by current value (two slots are equal iff they agree on
/// prevention state).
#[derive(Debug, Default)]
pub struct TerminateAnswer(AtomicBool);

impl TerminateAnswer {
    pub fn new() -> Self {
        Self(AtomicBool::new(false))
    }

    /// Marks the termination as prevented — the app wants to keep running.
    pub fn prevent(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Whether prevention was requested. Only meaningful after the synchronous
    /// handler call that received the reference has returned.
    pub fn is_prevented(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

impl PartialEq for TerminateAnswer {
    fn eq(&self, other: &Self) -> bool {
        self.is_prevented() == other.is_prevented()
    }
}

impl Clone for TerminateAnswer {
    fn clone(&self) -> Self {
        Self(AtomicBool::new(self.is_prevented()))
    }
}

#[derive(Clone)]
pub enum Event<'a> {
    /// window stage create event
    /// alias onWindowStageCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagecreate
    WindowCreate,
    /// window stage destroy event
    /// alias onWindowStageDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagedestroy
    WindowDestroy,

    WindowRedraw(IntervalInfo),
    /// window resize event
    /// alias window.on("windowSizeChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowsizechange7
    ///
    /// `window_id` is the OHOS window this resize originated from (0 = main,
    /// >0 = Float sub-window). Populated by the window_resize lifecycle closure
    /// from the `windowId` field ArkTS wraps into the options (design.md D2/D6).
    /// Phase 3: tao's run_loop routes the event by this id.
    WindowResize {
        window_id: i64,
        size: Size,
    },
    /// window rect change event
    /// alias window.on("windowRectChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowrectchange12
    ContentRectChange(ContentRect),
    /// window avoid area change event
    /// alias window.on("avoidAreaChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window#onavoidareachange9
    AvoidAreaChange(AvoidAreaInfo),

    /// window configuration changed
    /// alias onWindowConfigurationChanged
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-environmentcallback-V5#environmentcallbackonconfigurationupdated
    ConfigChanged(Configuration),
    /// low memory event
    /// alias onMemoryLevel
    /// it will execute when system memory is low(MEMORY_LEVEL_CRITICAL)
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-environmentcallback-V5#environmentcallbackonmemorylevel
    LowMemory,

    /// WindowStateEventChanged
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowstageevent9
    /// window show
    /// alias WindowStageEventType.SHOWN
    Start,
    /// window stage focus event
    /// alias WindowStageEventType.ACTIVE
    GainedFocus,
    /// window stage unfocus event
    /// alias WindowStageEventType.INAVTIVE
    LostFocus,
    /// window resume
    /// alias WindowStageEventType.RESUMED
    Resume(SaveLoader<'a>),
    /// window pause
    /// alias WindowStageEventType.PAUSED
    Pause,
    /// window stop
    /// alias WindowStageEventType.HIDDEN
    Stop,

    /// ability save state event
    /// alias onAbilitySaveState
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitysavestate12
    SaveState(SaveSaver<'a>),
    /// ability create event
    /// alias onAbilityCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitycreate
    Create,
    /// ability destroy event
    /// alias onAbilityDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitydestroy
    Destroy,

    /// surface create event
    /// alias onSurfaceCreated for XComponent
    /// We can render EGL/OpenGL in this event
    SurfaceCreate,
    /// surface destroy event
    /// alias onSurfaceDestroyed for XComponent
    SurfaceDestroy,
    /// surface input event
    /// IME
    Input(InputEvent),

    /// keyboard event
    /// alias onKeyboardHeightChange
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-window-window#onkeyboardheightchange7
    KeyboardEvent(i32),

    /// ability new want event (deep link / URL scheme)
    /// alias onNewWant
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-uiAbility-V5#uiabilityonnewwant
    NewWant {
        uri: String,
    },

    /// ability prepare-to-terminate event (PC/2in1 pre-close interception)
    /// alias UIAbility.onPrepareToTerminateAsync
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-app-ability-uiability#onpreparetoterminateasync15
    ///
    /// Fired BEFORE any teardown when the user closes the app via the window
    /// close button / taskbar shortcut / tray exit (requires
    /// ohos.permission.PREPARE_APP_TERMINATE). Unlike [`Event::Destroy`] the
    /// termination is still cancellable: the handler records its answer on
    /// `answer` ([`TerminateAnswer::prevent`] = keep running; tauri's
    /// `prevent_exit()` lands there) and the ArkTS caller returns `true` from
    /// `onPrepareToTerminateAsync` to cancel this close. The reference is only
    /// valid for the duration of the synchronous handler call — read it after
    /// `h(...)` returns.
    PrepareToTerminate {
        answer: &'a TerminateAnswer,
    },

    UserEvent,
}

impl<'a> Event<'a> {
    pub fn as_str(&self) -> &'static str {
        match self {
            Event::WindowCreate => "WindowCreate",
            Event::WindowDestroy => "WindowDestroy",
            Event::WindowRedraw(_) => "WindowRedraw",
            Event::WindowResize { .. } => "WindowResize",
            Event::ContentRectChange(_) => "ContentRectChange",
            Event::AvoidAreaChange(_) => "AvoidAreaChange",
            Event::ConfigChanged(_) => "ConfigChanged",
            Event::LowMemory => "LowMemory",
            Event::Start => "Start",
            Event::GainedFocus => "GainedFocus",
            Event::LostFocus => "LostFocus",
            Event::Resume(_) => "Resume",
            Event::Pause => "Pause",
            Event::Stop => "Stop",
            Event::SaveState(_) => "SaveState",
            Event::Create => "Create",
            Event::Destroy => "Destroy",
            Event::SurfaceCreate => "SurfaceCreate",
            Event::SurfaceDestroy => "SurfaceDestroy",
            Event::Input(_) => "Input",
            Event::UserEvent => "UserEvent",
            Event::KeyboardEvent(_) => "KeyboardEvent",
            Event::NewWant { .. } => "NewWant",
            Event::PrepareToTerminate { .. } => "PrepareToTerminate",
        }
    }
}

impl<'a> Debug for Event<'a> {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.as_str())
    }
}
