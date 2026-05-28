import { DefaultXComponent } from "./DefaultXComponent";
import {
  MenuBarComponent,
  getMenuClickHandler,
  getMenuBarRecoverFn,
  isMenubarVisible,
} from "./MenuBarComponent";
import { AcceleratorMatcher } from "../helper/accelerator_matcher";
import { KeyCode } from "@kit.InputKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window as arkWindow } from '@kit.ArkUI';

const DOMAIN: number = 0x1999;

export const RouteName = "FloatWindow";

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct FloatPage {
  // Receive windowId from WindowManager.createSubWindow
  @LocalStorageProp('windowId') windowId: number = 0;
  @StorageProp("__openharmony_ability_is_desktop__") isDesktop: boolean = false;

  // Window control
  private windowClass: arkWindow.Window | null = null;
  @State offsetX: number = 100;
  @State offsetY: number = 100;
  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'FloatPage', '=== FloatPage aboutToAppear START ===');
    hilog.info(DOMAIN, 'FloatPage', 'Received windowId: %{public}d', this.windowId);

    // Validate windowId
    if (this.windowId <= 0) {
      hilog.error(DOMAIN, 'FloatPage', 'Invalid windowId: %{public}d. FloatPage requires windowId > 0.', this.windowId);
      return;
    }

    // Get Window instance for dragging and closing
    try {
      const ui = this.getUIContext();
      const winName = ui.getWindowName();
      if (winName) {
        this.windowClass = arkWindow.findWindow(winName);
        if (this.windowClass) {
          const rect = this.windowClass.getWindowProperties().windowRect;
          this.offsetX = rect.left;
          this.offsetY = rect.top;
          hilog.info(DOMAIN, 'FloatPage', 'Got windowClass, initial rect: left=%{public}d, top=%{public}d', this.offsetX, this.offsetY);
        } else {
          hilog.error(DOMAIN, 'FloatPage', 'findWindow returned null for name: %{public}s', winName);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'FloatPage', 'Failed to get windowClass: %{public}s', JSON.stringify(e));
    }
  }

  build() {
    Column() {
      // Menubar (only on desktop when menu items are available)
      if (this.isDesktop) {
        MenuBarComponent({
          windowId: this.windowId,
          acceleratorMatcher: this.acceleratorMatcher,
        })
      }

      Stack({ alignContent: Alignment.TopEnd }) {
        // 1. WebView content area (full screen)
        DefaultXComponent({ windowId: this.windowId })
          .width('100%')
          .height('100%');

        // 2. Top drag control area + right close button
        //    Drag bar is 40px at top, receives touches; close button onClick intercepts that area's touches
        if (this.windowClass) {
          Row() {
            // Drag empty area (fills space except button)
            Row() {}
              .layoutWeight(1)
              .height(40);

            // Top right gray close button
            Button() {
              Text('×')
                .fontSize(20)
                .fontColor('#666666')
                .fontWeight(FontWeight.Bold);
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor('#f0f0f0')
            .margin({ top: 4, right: 8 })
            .onClick(() => {
              hilog.info(DOMAIN, 'FloatPage', 'Close button clicked for window %{public}d', this.windowId);
              this.windowClass?.destroyWindow();
            });
          }
          .width('100%')
          .height(40)
          .align(Alignment.TopEnd)
          .gesture(
            PanGesture({ direction: PanDirection.All })
              .onActionUpdate((event) => {
                this.offsetX += event.offsetX;
                this.offsetY += event.offsetY;
                this.windowClass?.moveWindowTo(this.offsetX, this.offsetY);
              })
          );
        }
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .onKeyPreIme((event: KeyEvent) => {
      // Accelerator matching (non-clipboard shortcuts)
      if (event.type === KeyType.Down && this.acceleratorMatcher.matches(event)) {
        const matchedItem = this.acceleratorMatcher.getMatchedItem();
        if (matchedItem) {
          const handler = getMenuClickHandler(this.windowId);
          if (handler) {
            handler(matchedItem);
          }
        }
        return true;
      }
      // ESC to restore menubar from fullscreen
      if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !isMenubarVisible(this.windowId)) {
        const recoverFn = getMenuBarRecoverFn(this.windowId);
        if (recoverFn) {
          recoverFn();
        }
        return true;
      }
      return false;
    })
  }
}
