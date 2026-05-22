import { NodeContent } from "@kit.ArkUI";
import {
  ArkHelper,
  StatusBarIconRgba,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
} from "../ability/type";
import { exit, objectAssign } from "../helper";
import { Loadable } from "../helper/loadable";
import { requestPermission } from "../helper/permission";
import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import { image } from "@kit.ImageKit";
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import {
  EmbeddedWebviewManager,
  RustWebviewNodeController,
  WebviewStyle,
  WebviewInitData,
} from "../webview/DefaultWebview";

export const RouteName = "NativeAbility";

let abilityContext: common.UIAbilityContext | null = null;
let currentAbilityName: string = "";
let helperRef: ArkHelper | null = null;

export function setCurrentAbilityName(name: string): void {
  currentAbilityName = name;
}

function getAbilityContext(): common.UIAbilityContext {
  return abilityContext as common.UIAbilityContext;
}

function createPixelMapFromRgba(rgbaData: Uint8Array, size: number): image.PixelMap | null {
  try {
    console.info(`[StatusBar] createPixelMapFromRgba: size=${size}, dataLen=${rgbaData.length}, byteOffset=${rgbaData.byteOffset}, bufferLen=${rgbaData.buffer.byteLength}`);
    const expectedLen = size * size * 4;
    if (rgbaData.length !== expectedLen) {
      console.error(`[StatusBar] data length mismatch: got ${rgbaData.length}, expected ${expectedLen}`);
      return null;
    }
    let nonZero = 0;
    for (let i = 0; i < Math.min(rgbaData.length, 100); i++) {
      if (rgbaData[i] !== 0) nonZero++;
    }
    console.info(`[StatusBar] first 100 bytes non-zero count: ${nonZero}, first 8 bytes: [${rgbaData[0]},${rgbaData[1]},${rgbaData[2]},${rgbaData[3]},${rgbaData[4]},${rgbaData[5]},${rgbaData[6]},${rgbaData[7]}]`);
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: size, height: size }
    };
    const pm = image.createPixelMapSync(opts);
    const buf = rgbaData.buffer.slice(rgbaData.byteOffset, rgbaData.byteOffset + rgbaData.byteLength);
    pm.writeBufferToPixelsSync(buf);
    const info = pm.getImageInfoSync();
    console.info(`[StatusBar] PixelMap created: ${info.size.width}x${info.size.height}, pixelFormat=${info.pixelFormat}`);
    return pm;
  } catch (e) {
    const err = e as BusinessError;
    console.error(`[StatusBar] createPixelMapFromRgba failed: ${err.code} ${err.message}`);
    return null;
  }
}

function fillMenuItemAbilityName(groups: ESObject[][], abilityName: string): void {
  for (const group of groups) {
    for (const item of group) {
      if (item.menuAction && (!item.menuAction.abilityName || item.menuAction.abilityName === '')) {
        item.menuAction.abilityName = abilityName;
      }
      if (item.subMenu) {
        for (const sub of item.subMenu) {
          if (sub.menuAction && (!sub.menuAction.abilityName || sub.menuAction.abilityName === '')) {
            sub.menuAction.abilityName = abilityName;
          }
        }
      }
    }
  }
}

function createPixelMapFromRgbaWH(rgbaData: Uint8Array, width: number, height: number): image.PixelMap | null {
  try {
    const expectedLen = width * height * 4;
    if (rgbaData.length !== expectedLen) {
      console.error(`[StatusBar] createPixelMapFromRgbaWH: data length mismatch: got ${rgbaData.length}, expected ${expectedLen} (${width}x${height})`);
      return null;
    }
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width: width, height: height }
    };
    const pm = image.createPixelMapSync(opts);
    const buf = rgbaData.buffer.slice(rgbaData.byteOffset, rgbaData.byteOffset + rgbaData.byteLength);
    pm.writeBufferToPixelsSync(buf);
    return pm;
  } catch (e) {
    const err = e as BusinessError;
    console.error(`[StatusBar] createPixelMapFromRgbaWH failed: ${err.code} ${err.message}`);
    return null;
  }
}

function processMenuItemIcons(groups: ESObject[][]): void {
  for (const group of groups) {
    for (const item of group) {
      if (item.options && item.options.iconRgba) {
        const rgba = item.options.iconRgba as Uint8Array;
        const w = (item.options.iconWidth as number) || 24;
        const h = (item.options.iconHeight as number) || 24;
        const pm = createPixelMapFromRgbaWH(rgba, w, h);
        if (pm) {
          item.options.icon = { white: pm, black: pm };
        }
        delete item.options.iconRgba;
        delete item.options.iconWidth;
        delete item.options.iconHeight;
      }
      if (item.subMenu) {
        for (const sub of item.subMenu) {
          if (sub.options && sub.options.iconRgba) {
            const rgba = sub.options.iconRgba as Uint8Array;
            const w = (sub.options.iconWidth as number) || 24;
            const h = (sub.options.iconHeight as number) || 24;
            const pm = createPixelMapFromRgbaWH(rgba, w, h);
            if (pm) {
              sub.options.icon = { white: pm, black: pm };
            }
            delete sub.options.iconRgba;
            delete sub.options.iconWidth;
            delete sub.options.iconHeight;
          }
        }
      }
    }
  }
}

@Component
export struct DefaultXComponent {
  moduleName: string = "";
  private rootSlot = new NodeContent();
  private webviewController = new RustWebviewNodeController(this.getUIContext());
  private embeddedWebviewManager = new EmbeddedWebviewManager(this.getUIContext());
  private nativeModule: ESObject;
  private helper: ArkHelper = {
    exit,
    requestPermission: async (permission: string | string[]): Promise<number | number[]> => {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return await requestPermission(context, permission);
    },
    getWindowAvoidArea: (type: number): WindowAvoidAreaInfo | undefined => {
      try {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const win = context.windowStage.getMainWindowSync();
        const avoidType = type as window.AvoidAreaType;
        return {
          type: avoidType,
          area: win.getWindowAvoidArea(avoidType),
        } as WindowAvoidAreaInfo;
      } catch (_) {
        return undefined;
      }
    },
    addToStatusBarWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number, quickOperation: ESObject, statusBarGroupMenu?: ESObject[][], hoverTips?: string) => {
      console.info(`[StatusBar] addToStatusBarWithRgba called: iconSize=${iconSize}, hasWhite=${!!(iconsRgba.white)}, whiteLen=${iconsRgba.white?.length ?? 0}, hasBlack=${!!(iconsRgba.black)}, blackLen=${iconsRgba.black?.length ?? 0}`);
      const context = getAbilityContext();
      if (!context) { console.error('[StatusBar] no context'); return; }
      if (!quickOperation.abilityName || quickOperation.abilityName === '') {
        quickOperation.abilityName = context.abilityInfo.name;
      }
      const icons: ESObject = {};
      if (iconsRgba.white && iconsRgba.white.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.white, iconSize);
        if (pm) icons.white = pm;
        console.info(`[StatusBar] white PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
        console.info(`[StatusBar] black PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (Object.keys(icons).length === 0) { console.error('[StatusBar] no valid icons, aborting'); return; }
      const opts: ESObject = {
        icons: icons,
        quickOperation: quickOperation,
        statusBarGroupMenu: statusBarGroupMenu ?? []
      };
      if (statusBarGroupMenu) {
        fillMenuItemAbilityName(statusBarGroupMenu, context.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
      }
      if (hoverTips && hoverTips.length > 0 && hoverTips.length <= 128) {
        opts.hoverTips = hoverTips;
      }
      try {
        statusBarManager.addToStatusBar(context, opts);
        console.info('[StatusBar] addToStatusBar succeeded');
        const h = helperRef as ESObject;
        const hasIconCb = !!(h && h._onIconClick);
        const hasMenuCb = !!(h && h._onMenuClick);
        console.info(`[StatusBar] _onIconClick=${hasIconCb}, _onMenuClick=${hasMenuCb}`);
        setTimeout(() => {
          try {
            if (h && h._onIconClick) {
              statusBarManager.on('statusBarIconClick' as 'statusBarIconClick', h._onIconClick as Callback<emitter.EventData>);
              console.info('[StatusBar] registered iconClick handler after addToStatusBar');
            }
            if (h && h._onMenuClick) {
              statusBarManager.on('rightMenuClick' as 'rightMenuClick', h._onMenuClick as Callback<emitter.EventData>);
              console.info('[StatusBar] registered menuClick handler after addToStatusBar');
            }
          } catch (e2) {
            const err2 = e2 as BusinessError;
            console.error(`[StatusBar] on() registration failed: ${err2.code} ${err2.message}`);
          }
        }, 200);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] addToStatusBar failed: ${err.code} ${err.message}`);
      }
    },
    updateStatusBarIconWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number) => {
      const context = getAbilityContext();
      if (!context) return;
      const icons: ESObject = {};
      if (iconsRgba.white && iconsRgba.white.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.white, iconSize);
        if (pm) icons.white = pm;
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
      }
      if (Object.keys(icons).length === 0) return;
      try {
        statusBarManager.updateStatusBarIcon(context, icons);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] updateStatusBarIcon failed: ${err.code} ${err.message}`);
      }
    },
    registerIconClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      console.info(`[StatusBar] registerIconClickHandler: legacy call (using _onIconClick instead)`);
    },
    registerMenuClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      console.info(`[StatusBar] registerMenuClickHandler: legacy call (using _onMenuClick instead)`);
    },
    unregisterIconClickHandler: (eventName: string) => {
      statusBarManager.off(eventName as 'statusBarIconClick');
    },
    unregisterMenuClickHandler: (eventName: string) => {
      statusBarManager.off(eventName as 'rightMenuClick');
    },
    updateStatusBarMenu: (statusBarGroupMenu: ESObject[][]) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        fillMenuItemAbilityName(statusBarGroupMenu, context.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
        statusBarManager.updateStatusBarMenu(context, statusBarGroupMenu);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] updateStatusBarMenu failed: ${err.code} ${err.message}`);
      }
    },
    updateStatusBarHoverTips: (hoverTips: string) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.updateStatusBarHoverTips(context, hoverTips);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] updateStatusBarHoverTips failed: ${err.code} ${err.message}`);
      }
    },
    removeFromStatusBar: () => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.removeFromStatusBar(context);
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] removeFromStatusBar failed: ${err.code} ${err.message}`);
      }
    },
    executePredefinedAction: (actionType: string) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        switch (actionType) {
          case 'quit':
            exit(0);
            break;
          case 'minimize':
          case 'hide':
          case 'close': {
            const win = context.windowStage.getMainWindowSync();
            let timerId: number | null = null;

            const doMinimize = () => {
              if (timerId !== null) { clearTimeout(timerId); timerId = null; }
              try { context.windowStage.off("windowStageEvent", handler); } catch (_) {}
              try { win.minimize(); } catch (e) {
                const err = e as BusinessError;
                console.error(`[StatusBar] minimize failed: ${err.code} ${err.message}`);
              }
            };

            const handler = (event: window.WindowStageEventType) => {
              if (event === window.WindowStageEventType.SHOWN) {
                doMinimize();
              }
            };
            context.windowStage.on("windowStageEvent", handler);

            timerId = setTimeout(() => {
              timerId = null;
              try { context.windowStage.off("windowStageEvent", handler); } catch (_) {}
              try { win.minimize(); } catch (e) {
                const err = e as BusinessError;
                console.error(`[StatusBar] minimize(fallback) failed: ${err.code} ${err.message}`);
              }
            }, 500);
            break;
          }
          case 'maximize':
          case 'fullscreen':
            context.windowStage.getMainWindowSync().maximize();
            break;
        }
      } catch (e) {
        const err = e as BusinessError;
        console.error(`[StatusBar] executePredefinedAction(${actionType}) failed: ${err.code} ${err.message}`);
      }
    },
    createWebview: (data: NativeWebViewInitData) => {
      const initScripts: ScriptItem[] = (data?.initializationScripts || []).map((i) => {
        return {
          script: i,
          scriptRules: ["*"],
        } as ScriptItem;
      });
      const init: WebviewInitData = {
        webTag: data?.id,
        url: data?.url,
        html: data?.html,
        headers: data?.headers,
        style: (data.style || {}) as WebviewStyle,
        javascriptEnable: data?.javascriptEnable ?? true,
        userAgent: data?.userAgent,
        devtools: data?.devtools,
        autoplay: data?.autoplay,
        initializationScripts: initScripts,
        onDragAndDrop: data?.onDragAndDrop,
        onDownloadStart: data?.onDownloadStart,
        onDownloadEnd: data?.onDownloadEnd,
        onNavigationRequest: data?.onNavigationRequest,
        onTitleChange: data?.onTitleChange,
      } as WebviewInitData;

      init.style = init.style || {};

      if (data?.transparent && !init.style.backgroundColor) {
        init.style.backgroundColor = Color.Transparent;
      }
      const ret = this.webviewController.addWebview(init);
      const applyStyle = (style: WebviewStyle) => {
        objectAssign(init.style as Record<string, ESObject>, style);
        this.webviewController.updateWebviewStyle(ret.webTag, init.style as WebviewStyle);
      };

      ret.controller.setBackgroundColor = (color: string) => {
        applyStyle({ backgroundColor: color });
      };

      ret.controller.setVisible = (visible: boolean) => {
        applyStyle({ visible });
      };

      ret.controller.dispose = () => {
        this.webviewController.removeWebview(ret.webTag);
      };

      return ret.controller;
    },
    createEmbeddedWebview: (data: NativeWebViewInitData) => {
      const initScripts: ScriptItem[] = (data?.initializationScripts || []).map((i) => {
        return {
          script: i,
          scriptRules: ["*"],
        } as ScriptItem;
      });
      const init: WebviewInitData = {
        webTag: data?.id,
        url: data?.url,
        html: data?.html,
        headers: data?.headers,
        style: (data.style || {}) as WebviewStyle,
        javascriptEnable: data?.javascriptEnable ?? true,
        userAgent: data?.userAgent,
        devtools: data?.devtools,
        autoplay: data?.autoplay,
        initializationScripts: initScripts,
        onDragAndDrop: data?.onDragAndDrop,
        onDownloadStart: data?.onDownloadStart,
        onDownloadEnd: data?.onDownloadEnd,
        onNavigationRequest: data?.onNavigationRequest,
        onTitleChange: data?.onTitleChange,
      } as WebviewInitData;

      init.style = init.style || {};

      if (data?.transparent && !init.style.backgroundColor) {
        init.style.backgroundColor = Color.Transparent;
      }

      const ret = this.embeddedWebviewManager.createWebview(init);
      const applyStyle = (style: WebviewStyle) => {
        objectAssign(init.style as Record<string, ESObject>, style);
        this.embeddedWebviewManager.updateWebviewStyle(ret.webTag, init.style as WebviewStyle);
      };

      ret.controller.setBackgroundColor = (color: string) => {
        applyStyle({ backgroundColor: color });
      };

      ret.controller.setVisible = (visible: boolean) => {
        applyStyle({ visible });
      };

      ret.controller.dispose = () => {
        this.embeddedWebviewManager.removeWebview(ret.webTag);
      };

      return ret;
    },
  };
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  async aboutToAppear(): Promise<void> {
    abilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    helperRef = this.helper;
    const moduleName = this.moduleName.trim();
    if (!moduleName) {
      throw new Error("DefaultXComponent.moduleName is required");
    }
    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    this.nativeModule.render(this.helper, this.rootSlot);
    console.info(`[StatusBar] afterRender: _onIconClick=${!!(this.helper as ESObject)._onIconClick}, _onMenuClick=${!!(this.helper as ESObject)._onMenuClick}`);
  }

  build() {
    Stack() {
      ContentSlot(this.rootSlot)
      Row() {
        Column() {
          NodeContainer(this.webviewController)
            .height("100%")
            .width("100%")
        }.width("100%")
      }
      .height("100%")
      .hitTestBehavior(HitTestMode.Transparent)
    };
  }
}
