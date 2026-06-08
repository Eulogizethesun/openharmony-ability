import { hilog } from '@kit.PerformanceAnalysisKit';
import webview from "@ohos.web.webview";

const DOMAIN: number = 0x1999;

export const getCookies = (url: string): string => {
  return webview.WebCookieManager.fetchCookieSync(url);
};

export interface JsWebviewStyle {
  x?: number | string;
  y?: number | string;
  backgroundColor?: string | Color;
  visible?: boolean;
}

export interface JsHelper {
  getCookies: (url: string) => string;
  getUrl: () => string;
  loadUrl: (url: string, header?: Record<string, string>) => void;
  loadHtml: (html: string) => void;
  zoom: (scale: number) => void;
  refresh: () => void;
  requestFocus: () => void;
  runJavaScript: (code: string, callback: (result?: string) => void) => void;
  setBackgroundColor: (color: string) => void;
  setVisible: (visible: boolean) => void;
  dispose: () => void;
  clearAllBrowsingData: () => void;
}

/**
 * 轻量级代理类：解决 Rust 侧在窗口未就绪时拿到空引用的问题。
 * 初始时缓存所有操作，待真实 Controller 绑定后自动重放。
 */
export class ProxyJsHelper implements JsHelper {
  private realController: JsHelper | null = null;
  private pendingOperations: Array<() => void> = [];

  /**
   * 绑定真实 Controller 并重放所有缓存操作
   */
  bindToRealController(real: JsHelper): void {
    hilog.info(DOMAIN, 'ProxyJsHelper', 'Binding real controller and replaying pending operations.');
    this.realController = real;
    const ops = this.pendingOperations;
    this.pendingOperations = [];
    ops.forEach(op => op());
    hilog.info(DOMAIN, 'ProxyJsHelper', `Replayed ${ops.length} operations.`);
  }

  // --- JsHelper 接口实现 ---

  getCookies(url: string): string {
    return this.realController ? this.realController.getCookies(url) : '';
  }

  getUrl(): string {
    return this.realController ? this.realController.getUrl() : '';
  }

  loadUrl(url: string, header?: Record<string, string>): void {
    if (this.realController) {
      this.realController.loadUrl(url, header);
    } else {
      hilog.info(DOMAIN, 'ProxyJsHelper', 'Caching loadUrl: %{public}s', url);
      this.pendingOperations.push(() => this.realController!.loadUrl(url, header));
    }
  }

  loadHtml(html: string): void {
    if (this.realController) {
      this.realController.loadHtml(html);
    } else {
      hilog.info(DOMAIN, 'ProxyJsHelper', 'Caching loadHtml');
      this.pendingOperations.push(() => this.realController!.loadHtml(html));
    }
  }

  zoom(scale: number): void {
    if (this.realController) {
      this.realController.zoom(scale);
    } else {
      this.pendingOperations.push(() => this.realController!.zoom(scale));
    }
  }

  refresh(): void {
    if (this.realController) {
      this.realController.refresh();
    } else {
      this.pendingOperations.push(() => this.realController!.refresh());
    }
  }

  requestFocus(): void {
    if (this.realController) {
      this.realController.requestFocus();
    } else {
      this.pendingOperations.push(() => this.realController!.requestFocus());
    }
  }

  runJavaScript(code: string, callback: (result?: string) => void): void {
    if (this.realController) {
      this.realController.runJavaScript(code, callback);
    } else {
      hilog.info(DOMAIN, 'ProxyJsHelper', 'Caching runJavaScript');
      this.pendingOperations.push(() => this.realController!.runJavaScript(code, callback));
    }
  }

  setBackgroundColor(color: string): void {
    if (this.realController) {
      this.realController.setBackgroundColor(color);
    } else {
      this.pendingOperations.push(() => this.realController!.setBackgroundColor(color));
    }
  }

  setVisible(visible: boolean): void {
    if (this.realController) {
      this.realController.setVisible(visible);
    } else {
      this.pendingOperations.push(() => this.realController!.setVisible(visible));
    }
  }

  dispose(): void {
    if (this.realController) {
      this.realController.dispose();
    } else {
      this.pendingOperations.push(() => this.realController!.dispose());
    }
  }

  clearAllBrowsingData(): void {
    if (this.realController) {
      this.realController.clearAllBrowsingData();
    } else {
      this.pendingOperations.push(() => this.realController!.clearAllBrowsingData());
    }
  }
}
