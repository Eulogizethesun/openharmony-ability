import { window, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RustWebviewNodeController, WebviewInitData } from '../webview/DefaultWebview';
import { ProxyJsHelper } from '../webview/Utils';
import * as FloatPage from '../components/FloatPage';

const DOMAIN: number = 0x1999;

export class WindowManager {
  private static instance: WindowManager | null = null;
  private context: common.UIAbilityContext;
  private windowStage: window.WindowStage | null = null;
  private windows: Map<number, window.Window> = new Map();
  private controllers: Map<number, RustWebviewNodeController> = new Map();
  private uiContexts: Map<number, UIContext> = new Map();
  
  // 代理对象队列 (用于在 Controller 就绪前缓存 Rust 操作)
  private pendingJsHelperProxies: Map<number, ProxyJsHelper> = new Map();
  
  // 待加载 URL 队列
  private pendingUrls: Map<number, string> = new Map();
  // 待初始化 WebView 队列 (解决竞态条件)
  private pendingInits: Map<number, WebviewInitData> = new Map();
  
  private constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static init(context: common.UIAbilityContext): void {
    if (!WindowManager.instance) {
      hilog.info(DOMAIN, 'WindowManager', 'WindowManager initialized');
      WindowManager.instance = new WindowManager(context);
    }
  }

  static getInstance(): WindowManager {
    hilog.info(DOMAIN, 'WindowManager', 'WindowManager getInstance');
    if (!WindowManager.instance) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowManager not initialized');
      throw new Error("WindowManager not initialized");
    }
    return WindowManager.instance;
  }

  setWindowStage(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    hilog.info(DOMAIN, 'WindowManager', 'WindowStage set');
  }

  async createSubWindow(name: string, type: number, windowId: number, width: number = 800, height: number = 600, x: number = 100, y: number = 100): Promise<number> {
    // 校验 windowId：子窗口 ID 必须大于 0
    if (windowId <= 0) {
      hilog.error(DOMAIN, 'WindowManager', `Invalid windowId: %{public}d. Sub-window creation requires windowId > 0.`, windowId);
      throw new Error(`Invalid windowId: ${windowId}. Must be greater than 0.`);
    }

    // 检查 windowStage 是否已设置
    if (!this.windowStage) {
      hilog.error(DOMAIN, 'WindowManager', 'WindowStage not set. Call setWindowStage() first.');
      throw new Error('WindowStage not set');
    }

    hilog.info(DOMAIN, 'WindowManager', `Creating sub-window via windowStage: %{public}s, id: %{public}d`, name, windowId);

    let win: window.Window;
    try {
      // 使用 windowStage.createSubWindow(name) 替代 window.createWindow(config)
      win = await this.windowStage.createSubWindow(name);
      this.windows.set(windowId, win);
      hilog.info(DOMAIN, 'WindowManager', `Sub-window created successfully: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to create sub-window: %{public}s`, JSON.stringify(err));
      throw err;
    }
    
    // 使用 LocalStorage 传递 windowId，确保窗口间隔离
    let storage = new LocalStorage();
    storage.setOrCreate('windowId', windowId);

    try {
      hilog.info(DOMAIN, 'WindowManager', `Loading content: FloatPage for window %{public}d`, windowId);
      await win.loadContentByName(FloatPage.RouteName, storage);
      hilog.info(DOMAIN, 'WindowManager', `UI content loaded successfully for window: %{public}d`, windowId);
      
      // 注册子窗口的 UIContext
      try {
        const uiCtx = win.getUIContext();
        if (uiCtx) {
          this.registerUIContext(windowId, uiCtx);
          hilog.info(DOMAIN, 'WindowManager', `Sub-window UIContext registered for window: %{public}d`, windowId);
        }
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', `Failed to get UIContext for window %{public}d: %{public}s`, windowId, JSON.stringify(e));
      }
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to load content for window %{public}d: %{public}s`, windowId, JSON.stringify(err));
      throw err;
    }
    
    try {
      hilog.info(DOMAIN, 'WindowManager', `Resizing window %{public}d to %{public}dx%{public}d`, windowId, width, height);
      await win.resize(width, height);
      hilog.info(DOMAIN, 'WindowManager', `Moving window %{public}d to %{public}d,%{public}d`, windowId, x, y);
      await win.moveWindowTo(x, y);
      await win.showWindow();
      hilog.info(DOMAIN, 'WindowManager', `Window shown: %{public}d`, windowId);
    } catch (err) {
      hilog.error(DOMAIN, 'WindowManager', `Failed to resize/move/show window: %{public}s`, JSON.stringify(err));
      throw err;
    }
    
    return windowId;
  }
  
  // 加载指定 URL 到指定窗口 - 统一使用 addWebview，与主窗口路径一致
  loadUrl(id: number, url: string): void {
    const controller = this.controllers.get(id);
    if (controller) {
      hilog.info(DOMAIN, 'WindowManager', `Loading URL for window ${id}: ${url}`);
      // 统一调用 addWebview，与主窗口 ArkHelper.createWebview 路径一致
      controller.addWebview({ url: url });
      // 如果加载成功，清除 pending URL
      this.pendingUrls.delete(id);
    } else {
      hilog.warn(DOMAIN, 'WindowManager', `Controller not ready for window ${id}. Queuing URL.`);
      // 如果控制器还没准备好，将 URL 存入队列，等待 registerController 触发
      this.pendingUrls.set(id, url);
    }
  }
  
  // 当页面初始化完成，注册 Controller 时触发加载
  registerController(id: number, controller: RustWebviewNodeController): void {
    hilog.info(DOMAIN, 'WindowManager', `Controller registered for window: %{public}d`, id);
    this.controllers.set(id, controller);

    // 1. 处理暂存的 WebView 初始化请求 (解决竞态条件)
    const pendingInit = this.pendingInits.get(id);
    if (pendingInit) {
      hilog.info(DOMAIN, 'WindowManager', `Processing pending init for window ${id}`);
      const result = controller.addWebview(pendingInit);
      this.pendingInits.delete(id);

      // 2. 激活代理 (将真实 Controller 绑定给代理)
      const proxy = this.takePendingJsHelperProxy(id);
      if (proxy) {
        hilog.info(DOMAIN, 'WindowManager', `Binding real controller to proxy for window ${id}`);
        proxy.bindToRealController(result.controller);
      }
    }

    // 3. 处理暂存的 URL 加载请求
    const pendingUrl = this.pendingUrls.get(id);
    if (pendingUrl) {
      hilog.info(DOMAIN, 'WindowManager', `Pending URL found! Triggering load for window ${id}: ${pendingUrl}`);
      controller.addWebview({ url: pendingUrl });
      this.pendingUrls.delete(id);
    } else {
      hilog.info(DOMAIN, 'WindowManager', `No pending URL for window ${id}. Waiting for command.`);
    }
  }
  
  // 将 WebView 初始化请求加入队列
  queueWebviewInit(id: number, init: WebviewInitData): void {
    hilog.warn(DOMAIN, 'WindowManager', `Controller not ready for window ${id}. Queuing init.`);
    this.pendingInits.set(id, init);
  }
  
  // 注册代理对象
  registerPendingJsHelperProxy(id: number, proxy: ProxyJsHelper): void {
    hilog.info(DOMAIN, 'WindowManager', `Registering pending proxy for window: %{public}d`, id);
    this.pendingJsHelperProxies.set(id, proxy);
  }

  // 获取并移除代理（绑定后不再需要管理）
  takePendingJsHelperProxy(id: number): ProxyJsHelper | undefined {
    const proxy = this.pendingJsHelperProxies.get(id);
    this.pendingJsHelperProxies.delete(id);
    return proxy;
  }
  
  getWindow(id: number): window.Window | undefined {
    return this.windows.get(id);
  }

  getController(id: number): RustWebviewNodeController | undefined {
    return this.controllers.get(id);
  }

  // 注册 UIContext（主窗口在 aboutToAppear 中调用，子窗口在 loadContent 后调用）
  registerUIContext(windowId: number, ctx: UIContext): void {
    hilog.info(DOMAIN, 'WindowManager', `UIContext registered for window: %{public}d`, windowId);
    this.uiContexts.set(windowId, ctx);
  }

  // 获取指定窗口的 UIContext
  getUIContext(windowId: number): UIContext | undefined {
    return this.uiContexts.get(windowId);
  }
}
