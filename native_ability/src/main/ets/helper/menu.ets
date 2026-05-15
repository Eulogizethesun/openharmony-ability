import { MenuItemData, PredefinedType } from './menu_types';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';
import { setMenuClickHandler } from '../components/MainPage';

export class PredefinedActionExecutor {
  private controller: web_webview.WebviewController | null = null;
  private win: window.Window | null = null;
  private exitFn: (code: number) => void;

  constructor(exitFn: (code: number) => void) {
    this.exitFn = exitFn;
  }

  setController(controller: web_webview.WebviewController): void {
    this.controller = controller;
  }

  setWindow(win: window.Window): void {
    this.win = win;
  }

  async execute(type: PredefinedType): Promise<void> {
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
      case 'hide':
        await this.win?.minimize();
        break;
      case 'maximize':
      case 'fullscreen':
        await this.win?.maximize();
        break;
      case 'recover':
        await this.win?.recover();
        break;
      case 'close':
      case 'destroyWindow':
        await this.win?.minimize();
        break;
      case 'quit':
        this.exitFn(0);
        break;
      case 'hideOthers':
      case 'showAll':
        break;
      case 'about':
        break;
      case 'restore':
        break;
    }
  }
}

export class MenuManager {
  private executor: PredefinedActionExecutor;
  private emitMenuEventFn: (menuId: string) => void;

  constructor(executor: PredefinedActionExecutor, emitMenuEventFn: (menuId: string) => void) {
    this.executor = executor;
    this.emitMenuEventFn = emitMenuEventFn;
    setMenuClickHandler((item: MenuItemData) => {
      this.handleItemClick(item);
    });
  }

  popupFromJson(jsonData: string, x?: number, y?: number): void {
    try {
      AppStorage.setOrCreate("__openharmony_ability_menu_shown__", false);
      AppStorage.setOrCreate("__openharmony_ability_menu_json__", jsonData);
      AppStorage.setOrCreate("__openharmony_ability_menu_x__", x ?? 0);
      AppStorage.setOrCreate("__openharmony_ability_menu_y__", y ?? 0);
      setTimeout(() => {
        AppStorage.setOrCreate("__openharmony_ability_menu_shown__", true);
      }, 0);
    } catch (e) {
      console.error('[Menu] Failed to popup menu:', e);
    }
  }

  handleItemClick(item: MenuItemData): void {
    if (item.type === 'predefined' && item.predefinedType) {
      this.executor.execute(item.predefinedType);
    } else {
      this.emitMenuEventFn(item.id);
    }
  }
}
