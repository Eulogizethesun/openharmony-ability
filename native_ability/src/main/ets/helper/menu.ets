import { MenuItemData, PredefinedType, AboutMetadataData } from './menu_types';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';
import display from '@ohos.display';
import { setMenuClickHandler } from '../components/MainPage';

export class PredefinedActionExecutor {
  private controller: web_webview.WebviewController | null = null;
  private win: window.Window | null = null;
  private exitFn: (code: number) => void;
  private showAboutFn: ((metadata: AboutMetadataData) => void) | null = null;
  private notifyMenubarVisibilityFn: ((windowId: string, visible: boolean) => void) | null = null;

  constructor(exitFn: (code: number) => void) {
    this.exitFn = exitFn;
  }

  setController(controller: web_webview.WebviewController): void {
    this.controller = controller;
  }

  setWindow(win: window.Window): void {
    this.win = win;
  }

  setShowAboutFn(fn: (metadata: AboutMetadataData) => void): void {
    this.showAboutFn = fn;
  }

  setNotifyMenubarVisibilityFn(fn: (windowId: string, visible: boolean) => void): void {
    this.notifyMenubarVisibilityFn = fn;
  }

  async execute(type: PredefinedType, aboutMetadata?: AboutMetadataData): Promise<void> {
    switch (type) {
      case 'copy':
        await this.controller?.runJavaScript('document.execCommand("copy")');
        break;
      case 'cut':
        await this.controller?.runJavaScript('document.execCommand("cut")');
        break;
      case 'paste':
        await this.controller?.runJavaScript('document.execCommand("paste")');
        break;
      case 'selectAll':
        await this.controller?.runJavaScript('document.execCommand("selectAll")');
        break;
      case 'undo':
        await this.controller?.runJavaScript('document.execCommand("undo")');
        break;
      case 'redo':
        await this.controller?.runJavaScript('document.execCommand("redo")');
        break;
      case 'minimize':
        await this.win?.minimize();
        break;
      case 'hide':
        await this.win?.minimize();
        break;
      case 'maximize':
        await this.win?.maximize();
        break;
      case 'fullscreen':
        AppStorage.setOrCreate("__openharmony_ability_menubar_visible__::main", false);
        AppStorage.setOrCreate("__openharmony_ability_menu_shown__::main", false);
        this.notifyMenubarVisibilityFn?.("main", false);
        try {
          const displayInfo = display.getDefaultDisplaySync();
          if (displayInfo.width > 800) {
            await this.win?.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
          } else {
            await this.win?.setWindowLayoutFullScreen(true);
            await this.win?.setWindowSystemBarEnable([]);
          }
        } catch (e) {
          await this.win?.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
        }
        break;
      case 'recover':
        AppStorage.setOrCreate("__openharmony_ability_menubar_visible__::main", true);
        this.notifyMenubarVisibilityFn?.("main", true);
        await this.win?.recover();
        break;
      case 'close':
        await this.win?.minimize();
        break;
      case 'quit':
        this.exitFn(0);
        break;
      case 'hideOthers':
      case 'showAll':
        break;
      case 'about':
        this.showAboutFn?.(aboutMetadata ?? {} as AboutMetadataData);
        break;
      case 'restore':
        break;
    }
  }
}

export class MenuManager {
  private executor: PredefinedActionExecutor;
  private emitMenuEventFn: (menuId: string, windowId?: string) => void;

  constructor(executor: PredefinedActionExecutor, emitMenuEventFn: (menuId: string, windowId?: string) => void) {
    this.executor = executor;
    this.emitMenuEventFn = emitMenuEventFn;
    setMenuClickHandler((item: MenuItemData) => {
      this.handleItemClick(item);
    });
  }

  popupFromJson(jsonData: string, x?: number, y?: number, windowId?: string): void {
    try {
      const wid = windowId ?? "main";
      AppStorage.setOrCreate("__openharmony_ability_menu_shown__::" + wid, false);
      AppStorage.setOrCreate("__openharmony_ability_menu_json__::" + wid, jsonData);
      AppStorage.setOrCreate("__openharmony_ability_menu_x__::" + wid, x ?? 0);
      AppStorage.setOrCreate("__openharmony_ability_menu_y__::" + wid, y ?? 0);
      setTimeout(() => {
        AppStorage.setOrCreate("__openharmony_ability_menu_shown__::" + wid, true);
      }, 0);
    } catch (e) {
      console.error('[Menu] Failed to popup menu:', e);
    }
  }

  handleItemClick(item: MenuItemData): void {
    if (item.type === 'predefined' && item.predefinedType) {
      this.executor.execute(item.predefinedType, item.aboutMetadata);
    } else {
      this.emitMenuEventFn(item.id, "main");
    }
  }
}