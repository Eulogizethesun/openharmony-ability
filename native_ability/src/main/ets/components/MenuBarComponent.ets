import { MenuItemData } from "../helper/menu_types";
import { AcceleratorMatcher } from "../helper/accelerator_matcher";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
import { SymbolGlyphModifier } from "@kit.ArkUI";
import { hilog } from "@kit.PerformanceAnalysisKit";

// ─── Open-menu accelerator triggering (issue Eulogizethesun/tauri#111) ───
//
// Closed-menu accelerators are dispatched by the AcceleratorMatcher +
// onKeyPreIme chain in MainPage/FloatPage. While a dropdown/popup menu is
// OPEN the menu sub-window owns focus, the main window's onKeyPreIme sees
// nothing, and ArkUI's `.keyboardShortcut` attribute does NOT fire inside
// menu sub-windows (device-verified: key events reach the Menu nodes with
// consumed:0). The KeyEvent DOES arrive on the Menu node through the focus
// chain though (AceFocus dispatch), so Menu.onKeyEvent runs the same
// combo-building logic and clicks the matching item.
//
// The accelerator string arrives from Rust `KeyAccelerator::Display`:
// "Ctrl+Shift+Alt+Super+<KEY>" (lowercased for comparison — same order the
// matcher builds combos in). Clipboard combos are NOT excluded here: the
// webview receives no keys while the menu sub-window has focus, so there is
// nothing to defer to.

// --- Per-window click handler registry (MW-1) ---
const windowMenuClickHandlers: Map<number, (item: MenuItemData) => void> = new Map();

export function setMenuClickHandler(windowId: number, handler: (item: MenuItemData) => void): void {
  hilog.info(0x1999, "MenuBar", "setMenuClickHandler registered for windowId=%{public}d", windowId);
  windowMenuClickHandlers.set(windowId, handler);
}

export function getMenuClickHandler(windowId: number): ((item: MenuItemData) => void) | null {
  const handler = windowMenuClickHandlers.get(windowId) ?? null;
  if (!handler) {
    hilog.warn(
      0x1999,
      "MenuBar",
      "getMenuClickHandler NULL for windowId=%{public}d (map size=%{public}d)",
      windowId,
      windowMenuClickHandlers.size,
    );
  }
  return handler;
}

export function unregisterMenuClickHandler(windowId: number): void {
  windowMenuClickHandlers.delete(windowId);
}

// --- Per-window recover function registry (MW-1) ---
const windowRecoverFns: Map<number, () => void> = new Map();

export function setMenuBarRecoverFn(windowId: number, fn: () => void): void {
  windowRecoverFns.set(windowId, fn);
}

export function getMenuBarRecoverFn(windowId: number): (() => void) | null {
  return windowRecoverFns.get(windowId) ?? null;
}

export function unregisterMenuBarRecoverFn(windowId: number): void {
  windowRecoverFns.delete(windowId);
}

// --- Per-window menu data callback registry (MW-5) ---
export interface MenuDataCallback {
  onMenubarJson?: (json: string) => void;
  onMenubarVisible?: (visible: boolean) => void;
  onMenuPopup?: (json: string, x: number, y: number) => void;
  onMenuShown?: (shown: boolean) => void;
}

const menuDataCallbacks: Map<string, MenuDataCallback> = new Map();

export function registerMenuDataCallback(windowKey: string, callback: MenuDataCallback): void {
  menuDataCallbacks.set(windowKey, callback);
}

export function getMenuDataCallback(windowKey: string): MenuDataCallback | undefined {
  return menuDataCallbacks.get(windowKey);
}

export function unregisterMenuDataCallback(windowKey: string): void {
  menuDataCallbacks.delete(windowKey);
}

/**
 * Converts a numeric windowId to the AppStorage key suffix.
 * windowId 0 → "main", others → string representation.
 */
export function windowKeyForId(windowId: number): string {
  return windowId === 0 ? "main" : String(windowId);
}

// --- Per-window menubar visibility tracker (for ESC handler in parent pages) ---
const menubarVisibilityTracker: Map<number, boolean> = new Map();

export function isMenubarVisible(windowId: number): boolean {
  return menubarVisibilityTracker.get(windowId) ?? true;
}
@Component
export struct MenuBarComponent {
  @Prop windowId: number = 0;
  /** Shared AcceleratorMatcher instance — parent passes its reference,
   *  this component rebuilds it in-place when menubar data changes.
   *  Parent reads matched item from it in onKeyPreIme.
   *  Regular property (not @Prop) to share the same reference with parent. */
  acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

  // --- Callback-driven state (replaces @StorageProp, MW-5) ---
  @State @Watch("onMenuJsonChange") menuJson: string = "[]";
  @State menuShown: boolean = false;
  @State menuX: number = 0;
  @State menuY: number = 0;
  @State @Watch("onMenubarJsonChange") menubarJson: string = "[]";
  @State menubarVisible: boolean = true;

  // --- Local state ---
  @State private menuItems: MenuItemData[] = [];
  @State private menubarItems: MenuItemData[] = [];
  @State private activeDropdownId: string = "";
  @State private activeDropdownShown: boolean = false;
  @State private hoveredItemId: string = "";

  private iconPixelMaps: Map<string, image.PixelMap> = new Map();
  private popupIconIds: Set<string> = new Set();
  private menubarIconIds: Set<string> = new Set();

  // --- Watch handlers ---

  onMenuJsonChange(): void {
    try {
      const items = JSON.parse(this.menuJson) as MenuItemData[];
      this.popupIconIds.clear();
      this.collectIconIds(items, this.popupIconIds);
      this.prepareIcons(items);
      this.cleanupStaleIcons();
      this.menuItems = items;
    } catch (e) {
      this.popupIconIds.clear();
      this.cleanupStaleIcons();
      this.menuItems = [];
    }
  }

  onMenubarJsonChange(): void {
    try {
      const items = JSON.parse(this.menubarJson) as MenuItemData[];
      this.menubarIconIds.clear();
      this.collectIconIds(items, this.menubarIconIds);
      this.prepareIcons(items);
      this.cleanupStaleIcons();
      this.menubarItems = items.filter((i) => i.type === "submenu" && i.text);
      this.acceleratorMatcher.buildFromItems(items);
      const submenuDetails = this.menubarItems.map(
        (i) => `${i.text}: [${(i.submenuItems ?? []).map((s) => s.text ?? s.id).join(",")}]`,
      );
      console.info(
        `[Menubar] onMenubarJsonChange: items=${items.length}, ` +
          `submenuItems=${this.menubarItems.length}, details=${submenuDetails.join("; ")}`,
      );
      // If dropdown is open, close and reopen to force re-render with updated data
      // 诊断埋点#3：close-reopen 分支。判读：若点击后先看到此日志再看到 onWillDisappear → 根因B
      // (set-menubar 二次到达触发 close-reopen，reopen 因 activeDropdownId 已被清空而失败)。
      if (this.activeDropdownShown && this.activeDropdownId) {
        hilog.info(
          0x1999,
          "MenuBar",
          "onMenubarJsonChange close-reopen: activeId=%{public}s",
          this.activeDropdownId,
        );
        this.activeDropdownShown = false;
        setTimeout(() => {
          this.activeDropdownShown = true;
        }, 0);
      }
    } catch (e) {
      this.menubarIconIds.clear();
      this.cleanupStaleIcons();
      this.menubarItems = [];
      console.error(`[Menubar] onMenubarJsonChange failed: ${e}`);
    }
  }

  // --- Icon management ---

  private prepareIcons(items: MenuItemData[]): void {
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.icon) {
        try {
          const decoded = buffer.from(item.icon, "base64");
          const arrayBuf = decoded.buffer as ArrayBuffer;
          const imageSource = image.createImageSource(arrayBuf);
          const pixelMap = imageSource.createPixelMapSync();
          imageSource.release();
          this.iconPixelMaps.set(item.id, pixelMap);
        } catch (e) {
          console.error(`[Menu] prepareIcons failed for ${item.id}: ${e}`);
        }
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
  }

  private cleanupStaleIcons(): void {
    const liveIds = new Set<string>();
    for (const id of this.popupIconIds) {
      liveIds.add(id);
    }
    for (const id of this.menubarIconIds) {
      liveIds.add(id);
    }
    for (const [id, pm] of this.iconPixelMaps) {
      if (!liveIds.has(id)) {
        pm.release();
        this.iconPixelMaps.delete(id);
      }
    }
  }

  private collectIconIds(items: MenuItemData[], ids: Set<string>): void {
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.icon) {
        ids.add(item.id);
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
  }

  // --- Native icon resolution ---

  /**
   * Maps a nativeIcon string (e.g. "sys.symbol.plus") to the raw symbol Resource.
   * $r() requires compile-time string literals, so we use a switch/case for known-valid variants
   * (names validated against the SDK's sysResource.js symbol table).
   * All 56 NativeIcon variants are mapped (issue Eulogizethesun/tauri#112) — keep this
   * switch in sync with `native_icon_to_ohos` in muda/src/platform_impl/ohos/mod.rs.
   * Returns null for unknown strings, which renders as no icon.
   */
  private nativeIconResource(nativeIcon: string): Resource | null {
    switch (nativeIcon) {
      case "sys.symbol.plus":
        return $r("sys.symbol.plus");
      case "sys.symbol.slider_horizontal_2_1":
        return $r("sys.symbol.slider_horizontal_2_1");
      case "sys.symbol.bluetooth":
        return $r("sys.symbol.bluetooth");
      case "sys.symbol.bookmark":
        return $r("sys.symbol.bookmark");
      case "sys.symbol.exclamationmark_triangle":
        return $r("sys.symbol.exclamationmark_triangle");
      case "sys.symbol.paintbrush_pointed":
        return $r("sys.symbol.paintbrush_pointed");
      case "sys.symbol.rectangle_split_3x1":
        return $r("sys.symbol.rectangle_split_3x1");
      case "sys.symbol.monitor_fill":
        return $r("sys.symbol.monitor_fill");
      case "sys.symbol.fullscreen":
        return $r("sys.symbol.fullscreen");
      case "sys.symbol.person_3":
        return $r("sys.symbol.person_3");
      case "sys.symbol.arrow_down_right_and_arrow_up_left":
        return $r("sys.symbol.arrow_down_right_and_arrow_up_left");
      case "sys.symbol.square_stack_3d":
        return $r("sys.symbol.square_stack_3d");
      case "sys.symbol.folder":
        return $r("sys.symbol.folder");
      case "sys.symbol.flame":
        return $r("sys.symbol.flame");
      case "sys.symbol.folder_badge_eye":
        return $r("sys.symbol.folder_badge_eye");
      case "sys.symbol.link":
        return $r("sys.symbol.link");
      case "sys.symbol.textformat":
        return $r("sys.symbol.textformat");
      case "sys.symbol.chevron_left":
        return $r("sys.symbol.chevron_left");
      case "sys.symbol.chevron_right":
        return $r("sys.symbol.chevron_right");
      case "sys.symbol.house":
        return $r("sys.symbol.house");
      case "sys.symbol.video_fill":
        return $r("sys.symbol.video_fill");
      case "sys.symbol.square_grid_2x2":
        return $r("sys.symbol.square_grid_2x2");
      case "sys.symbol.info_circle":
        return $r("sys.symbol.info_circle");
      case "sys.symbol.nosign":
        return $r("sys.symbol.nosign");
      case "sys.symbol.triangleshape_left":
        return $r("sys.symbol.triangleshape_left");
      case "sys.symbol.list_bullet":
        return $r("sys.symbol.list_bullet");
      case "sys.symbol.ohos_lock":
        return $r("sys.symbol.ohos_lock");
      case "sys.symbol.lock_open":
        return $r("sys.symbol.lock_open");
      case "sys.symbol.minus":
        return $r("sys.symbol.minus");
      case "sys.symbol.checkmark":
        return $r("sys.symbol.checkmark");
      case "sys.symbol.cloud":
        return $r("sys.symbol.cloud");
      case "sys.symbol.rectangle_stack":
        return $r("sys.symbol.rectangle_stack");
      case "sys.symbol.ohos_wifi":
        return $r("sys.symbol.ohos_wifi");
      case "sys.symbol.route":
        return $r("sys.symbol.route");
      case "sys.symbol.gearshape":
        return $r("sys.symbol.gearshape");
      case "sys.symbol.eye":
        return $r("sys.symbol.eye");
      case "sys.symbol.arrow_clockwise":
        return $r("sys.symbol.arrow_clockwise");
      case "sys.symbol.minus_circle":
        return $r("sys.symbol.minus_circle");
      case "sys.symbol.magnifyingglass":
        return $r("sys.symbol.magnifyingglass");
      case "sys.symbol.triangleshape_fill":
        return $r("sys.symbol.triangleshape_fill");
      case "sys.symbol.share":
        return $r("sys.symbol.share");
      case "sys.symbol.play_video":
        return $r("sys.symbol.play_video");
      case "sys.symbol.wand_and_stars":
        return $r("sys.symbol.wand_and_stars");
      case "sys.symbol.circle_fill":
        return $r("sys.symbol.circle_fill");
      case "sys.symbol.circle":
        return $r("sys.symbol.circle");
      case "sys.symbol.circle_lefthalf_inset_filled":
        return $r("sys.symbol.circle_lefthalf_inset_filled");
      case "sys.symbol.xmark_circle":
        return $r("sys.symbol.xmark_circle");
      case "sys.symbol.onehand":
        return $r("sys.symbol.onehand");
      case "sys.symbol.ohos_trash":
        return $r("sys.symbol.ohos_trash");
      case "sys.symbol.trash_fill":
        return $r("sys.symbol.trash_fill");
      case "sys.symbol.person":
        return $r("sys.symbol.person");
      case "sys.symbol.person_badge_checkmark":
        return $r("sys.symbol.person_badge_checkmark");
      case "sys.symbol.person_2":
        return $r("sys.symbol.person_2");
      case "sys.symbol.person_badge_nosign":
        return $r("sys.symbol.person_badge_nosign");
      default:
        return null;
    }
  }

  /**
   * Maps a nativeIcon string to a SymbolGlyphModifier (for MenuItem symbolStartIcon).
   */
  private nativeIconSymbol(nativeIcon: string): SymbolGlyphModifier | null {
    const resource = this.nativeIconResource(nativeIcon);
    return resource ? new SymbolGlyphModifier(resource) : null;
  }

  // --- Menu builders ---

  @Builder
  RenderMenuItems(items: MenuItemData[]) {
    ForEach(
      this.splitByDivider(items),
      (group: MenuItemData[], index: number) => {
        MenuItemGroup() {
          ForEach(
            group,
            (item: MenuItemData) => {
              if (item.type === "submenu") {
                MenuItem({
                  content: item.text ?? "",
                  builder: (): void => this.SubmenuContent(item.submenuItems ?? []),
                  symbolStartIcon: item.nativeIcon
                    ? this.nativeIconSymbol(item.nativeIcon)
                    : undefined,
                });
              } else if (item.type === "check") {
                MenuItem({
                  content: item.text ?? "",
                  labelInfo: item.accelerator,
                  symbolStartIcon: item.nativeIcon
                    ? this.nativeIconSymbol(item.nativeIcon)
                    : undefined,
                })
                  .enabled(item.enabled ?? true)
                  .selected(item.checked ?? false)
                  .selectIcon(true)
                  .onChange((checked: boolean) => {
                    item.checked = checked;
                    const handler = getMenuClickHandler(this.windowId);
                    if (handler) {
                      handler(item);
                    }
                  });
              } else if (item.type === "icon" && this.iconPixelMaps.has(item.id)) {
                MenuItem({
                  labelInfo: item.accelerator,
                }) {
                  Row() {
                    Image(this.iconPixelMaps.get(item.id))
                      .width(24)
                      .height(24)
                      .margin({ right: 8 })
                    Text(item.text ?? "").fontSize(14)
                  }
                }
                .enabled(item.enabled ?? true)
                .onClick(() => {
                  const handler = getMenuClickHandler(this.windowId);
                  if (handler) {
                    handler(item);
                  }
                });
              } else {
                MenuItem({
                  content: item.text ?? item.predefinedType ?? "",
                  labelInfo: item.accelerator,
                  symbolStartIcon: item.nativeIcon
                    ? this.nativeIconSymbol(item.nativeIcon)
                    : undefined,
                })
                  .enabled(item.enabled ?? true)
                  .onClick(() => {
                    const handler = getMenuClickHandler(this.windowId);
                    hilog.info(
                      0x1999,
                      "MenuBar",
                      "menuItem onClick id=%{public}s windowId=%{public}d handler=%{public}s",
                      item.id,
                      this.windowId,
                      handler ? "found" : "NULL",
                    );
                    if (handler) {
                      handler(item);
                    }
                  });
              }
            },
            (item: MenuItemData) => item.id,
          )
        };
      },
      (_group: MenuItemData[], index: number) => `group_${index}`,
    );
  }

  /**
   * Open-menu accelerator handler (issue #111) — attached to the Menu
   * container of both the popup (MenuContent) and the dropdown
   * (SubmenuContent). Builds the combo via the shared matcher logic and
   * clicks the first item whose accelerator matches, across the popup and
   * menubar item trees. Returns true when consumed.
   */
  menuAcceleratorKeyHandler(event: KeyEvent): boolean {
    const combo = this.acceleratorMatcher.buildComboForEvent(event);
    if (combo === null) {
      return false;
    }
    const matched = this.findItemByCombo(combo);
    if (matched === null) {
      return false;
    }
    const handler = getMenuClickHandler(this.windowId);
    hilog.info(
      0x1999,
      "MenuBar",
      "menuAcceleratorKeyHandler combo=%{public}s id=%{public}s windowId=%{public}d",
      combo,
      matched.id,
      this.windowId,
    );
    if (handler) {
      handler(matched);
    }
    return true;
  }

  /** First item (popup tree first, then menubar tree incl. submenus) whose
   *  accelerator string equals the combo ("ctrl+m" vs "Ctrl+M"). */
  private findItemByCombo(combo: string): MenuItemData | null {
    const queue: MenuItemData[] = [...this.menuItems, ...this.menubarItems];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.accelerator && item.accelerator.toLowerCase() === combo) {
        return item;
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
    return null;
  }

  private splitByDivider(items: MenuItemData[]): MenuItemData[][] {
    const groups: MenuItemData[][] = [];
    let current: MenuItemData[] = [];
    for (const item of items) {
      if (item.type === "predefined" && item.predefinedType === "separator") {
        if (current.length > 0) {
          groups.push(current);
          current = [];
        }
      } else {
        current.push(item);
      }
    }
    if (current.length > 0) {
      groups.push(current);
    }
    return groups;
  }

  @Builder
  SubmenuContent(items: MenuItemData[]) {
    Menu() {
      this.RenderMenuItems(items)
    }
    .onKeyEvent((event: KeyEvent) => this.menuAcceleratorKeyHandler(event));
  }

  @Builder
  MenuContent() {
    Menu() {
      this.RenderMenuItems(this.menuItems)
    }
    .onKeyEvent((event: KeyEvent) => this.menuAcceleratorKeyHandler(event));
  }

  @Builder
  MenuBarRow() {
    Row() {
      ForEach(
        this.menubarItems,
        (item: MenuItemData) => {
          Row() {
            if (item.icon && this.iconPixelMaps.has(item.id)) {
              Image(this.iconPixelMaps.get(item.id)).width(16).height(16).margin({ right: 4 });
            } else if (item.nativeIcon && this.nativeIconResource(item.nativeIcon)) {
              // Top-level nativeIcon: render as a system symbol, mirroring the
              // Image branch above (submenu icon and nativeIcon are mutually exclusive)
              SymbolGlyph(this.nativeIconResource(item.nativeIcon) as Resource)
                .fontSize(16)
                .margin({ right: 4 });
            }
            Text(item.text ?? "")
              .fontSize(14)
              .fontColor((item.enabled ?? true) ? "#333333" : "#999999")
          }
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .enabled(item.enabled ?? true)
          .opacity((item.enabled ?? true) ? 1.0 : 0.5)
          .backgroundColor(
            this.activeDropdownId === item.id
              ? "#E0E0E0"
              : this.hoveredItemId === item.id
                ? "#EBEBEB"
                : "#F5F5F5",
          )
          .onClick(() => {
            // 诊断埋点#1：menubar Row 点击。判读：
            //  - 若点击后立即看到 onWillDisappear 且无第二次 onClick → 根因A（bindMenu 竞争/子窗口失焦）
            //  - 若 onWillDisappear 在无 onClick 的情况下触发 → 根因C（子窗口 attach/focus 时序）
            hilog.info(
              0x1999,
              "MenuBar",
              "dropdown onClick id=%{public}s prevShown=%{public}s prevActive=%{public}s",
              item.id,
              this.activeDropdownShown,
              this.activeDropdownId,
            );
            // 菜单子窗口接管键盘后主窗收不到修饰键释放——展开时清空跟踪位，
            // 防止关菜单后第一个裸键被拼成假组合（issue #111 修饰键跟踪）。
            this.acceleratorMatcher.clearTrackedModifiers();
            this.activeDropdownId = item.id;
            this.activeDropdownShown = true;
          })
          .onHover((isHover: boolean) => {
            this.hoveredItemId = isHover ? item.id : "";
          })
          .bindMenu(
            this.activeDropdownShown && this.activeDropdownId === item.id,
            this.MenubarDropdownContent(item),
            {
              showInSubWindow: true,
              onWillDisappear: () => {
                // 诊断埋点#2：dropdown 消失。判读：配合埋点#1 的时序判断根因 A/B/C
                hilog.info(
                  0x1999,
                  "MenuBar",
                  "onWillDisappear activeId=%{public}s",
                  this.activeDropdownId,
                );
                this.activeDropdownShown = false;
                this.activeDropdownId = "";
              },
            },
          );
        },
        (item: MenuItemData) => item.id,
      )
    }
    .width("100%")
    .height(40)
    .backgroundColor("#F5F5F5")
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  MenubarDropdownContent(item: MenuItemData) {
    Menu() {
      this.RenderMenuItems(this.getActiveDropdownItem()?.submenuItems ?? [])
    }
    .onKeyEvent((event: KeyEvent) => this.menuAcceleratorKeyHandler(event));
  }

  private getActiveDropdownItem(): MenuItemData | null {
    for (const item of this.menubarItems) {
      if (item.id === this.activeDropdownId) {
        return item;
      }
    }
    return null;
  }

  // --- Lifecycle ---

  aboutToAppear(): void {
    // Register callback for this window's menu data (MW-5)
    const windowKey = windowKeyForId(this.windowId);
    menubarVisibilityTracker.set(this.windowId, this.menubarVisible);
    registerMenuDataCallback(windowKey, {
      onMenubarJson: (json: string) => {
        this.menubarJson = json;
      },
      onMenubarVisible: (visible: boolean) => {
        this.menubarVisible = visible;
        menubarVisibilityTracker.set(this.windowId, visible);
      },
      onMenuPopup: (json: string, x: number, y: number) => {
        hilog.info(
          0x1999,
          "MenuBar",
          "onMenuPopup windowId=%{public}d x=%{public}d y=%{public}d jsonLen=%{public}d",
          this.windowId,
          x,
          y,
          json.length,
        );
        // 弹出菜单子窗口接管键盘——同 dropdown，展开时清空修饰键跟踪位。
        this.acceleratorMatcher.clearTrackedModifiers();
        this.menuJson = json;
        this.menuX = x;
        this.menuY = y;
        // Close first, then reopen to re-trigger bindMenu
        this.menuShown = false;
        setTimeout(() => {
          this.menuShown = true;
        }, 0);
      },
      onMenuShown: (shown: boolean) => {
        this.menuShown = shown;
      },
    });
  }

  aboutToDisappear(): void {
    // Unregister callback and handlers for this window
    const windowKey = windowKeyForId(this.windowId);
    unregisterMenuDataCallback(windowKey);
    unregisterMenuClickHandler(this.windowId);
    unregisterMenuBarRecoverFn(this.windowId);
    menubarVisibilityTracker.delete(this.windowId);

    // Release all icon PixelMaps
    for (const [, pm] of this.iconPixelMaps) {
      pm.release();
    }
    this.iconPixelMaps.clear();
    this.popupIconIds.clear();
    this.menubarIconIds.clear();
  }

  // --- Build ---

  build() {
    Column() {
      // Menubar row
      if (this.menubarItems.length > 0 && this.menubarVisible) {
        this.MenuBarRow();
      }

      // Popup menu anchor (1x1 invisible). Use bindContextMenu (not bindMenu):
      // bindMenu + showInSubWindow on an invisible anchor renders visually but
      // does not deliver pointer events to MenuItem.onClick in the sub-window.
      // bindContextMenu is the documented sub-window menu API (HarmonyOS 5.0.0/API12+),
      // and its MenuItem.onClick fires reliably. Position via `offset` (API12);
      // `anchorPosition` is API20+ and unavailable here.
      Column()
        .width(1)
        .height(1)
        .position({ x: 0, y: 0 })
        .bindContextMenu(this.menuShown, this.MenuContent, {
          offset: { x: this.menuX, y: this.menuY },
          aboutToDisappear: () => {
            this.menuShown = false;
          },
        })
    };
  }
}
