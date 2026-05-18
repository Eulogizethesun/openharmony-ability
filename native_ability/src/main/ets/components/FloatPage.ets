import { DefaultXComponent } from "./DefaultXComponent";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window as arkWindow } from '@kit.ArkUI';

const DOMAIN: number = 0x1999;

export const RouteName = "FloatWindow";

@Entry({ routeName: RouteName, storage: LocalStorage.getShared() })
@Component
struct FloatPage {
  // 接收 WindowManager.createSubWindow 传入的 windowId
  @LocalStorageProp('windowId') windowId: number = 0;
  
  // 窗口控制相关
  private windowClass: arkWindow.Window | null = null;
  @State offsetX: number = 100;
  @State offsetY: number = 100;

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'FloatPage', '=== FloatPage aboutToAppear START ===');
    hilog.info(DOMAIN, 'FloatPage', 'Received windowId: %{public}d', this.windowId);

    // 校验 windowId
    if (this.windowId <= 0) {
      hilog.error(DOMAIN, 'FloatPage', 'Invalid windowId: %{public}d. FloatPage requires windowId > 0.', this.windowId);
      return;
    }

    // 获取 Window 实例用于拖拽和关闭
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
    Stack({ alignContent: Alignment.TopEnd }) {
      // 1. WebView 内容区域（占满全屏）
      DefaultXComponent({ windowId: this.windowId })
        .width('100%')
        .height('100%');

      // 2. 顶部拖拽控制区域 + 右侧关闭按钮
      //    拖拽条在顶部 40px，可接收触摸；关闭按钮的 onClick 拦截该区域的触摸
      if (this.windowClass) {
        Row() {
          // 拖拽空白区域（占满除按钮外的空间）
          Row() {}
            .layoutWeight(1)
            .height(40);

          // 右上角灰色关闭按钮
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
    .width('100%')
    .height('100%');
  }
}