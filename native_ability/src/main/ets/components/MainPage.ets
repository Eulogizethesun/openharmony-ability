import { DefaultXComponent } from "./DefaultXComponent";
import { Loadable } from "../helper/loadable";
import { MenuItemData } from "../helper/menu_types";
import { AcceleratorMatcher } from "../helper/accelerator_matcher";
import { KeyCode } from "@kit.InputKit";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x1999;

export const RouteName = "NativeAbility";

let globalMenuClickHandler: ((item: MenuItemData) => void) | null = null;
let globalRecoverFn: (() => void) | null = null;

export function setMenuClickHandler(handler: (item: MenuItemData) => void): void {
  globalMenuClickHandler = handler;
}

export function setRecoverFn(fn: () => void): void {
  globalRecoverFn = fn;
}

@Entry({ routeName: RouteName })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  @State private nativeModule: ESObject | null = null;
  @State private resolvedModuleName: string = "";

  @StorageProp("__openharmony_ability_menu_shown__::main") menuShown: boolean = false;
  @StorageProp("__openharmony_ability_menu_x__::main") menuX: number = 0;
  @StorageProp("__openharmony_ability_menu_y__::main") menuY: number = 0;
  @Watch("onMenuJsonChange") @StorageProp("__openharmony_ability_menu_json__::main") menuJson: string = "[]";
  @State private menuItems: MenuItemData[] = [];
  private iconPixelMaps: Map<string, image.PixelMap> = new Map();
  private popupIconIds: Set<string> = new Set();
  private menubarIconIds: Set<string> = new Set();

  @StorageProp("__openharmony_ability_is_desktop__") isDesktop: boolean = false;
  @Watch("onMenubarJsonChange") @StorageProp("__openharmony_ability_menubar_json__::main") menubarJson: string = "[]";
  @StorageProp("__openharmony_ability_menubar_visible__::main") menubarVisible: boolean = true;
  @State private menubarItems: MenuItemData[] = [];
  @State private activeDropdownId: string = "";
  @State private activeDropdownShown: boolean = false;
  @State private hoveredItemId: string = "";
  private acceleratorMatcher: AcceleratorMatcher = new AcceleratorMatcher();

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
      this.menubarItems = items.filter(i => i.type === 'submenu' && i.text);
      this.acceleratorMatcher.buildFromItems(items);
      const submenuDetails = this.menubarItems.map(i => `${i.text}: [${(i.submenuItems ?? []).map(s => s.text ?? s.id).join(',')}]`);
      console.info(`[Menubar] onMenubarJsonChange: items=${items.length}, submenuItems=${this.menubarItems.length}, details=${submenuDetails.join('; ')}`);
      // If dropdown is open, close and reopen to force re-render with updated data
      if (this.activeDropdownShown && this.activeDropdownId) {
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

  private prepareIcons(items: MenuItemData[]): void {
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.icon) {
        try {
          const decoded = buffer.from(item.icon, 'base64');
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
    for (const id of this.popupIconIds) { liveIds.add(id); }
    for (const id of this.menubarIconIds) { liveIds.add(id); }
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

  
  @Builder
  RenderMenuItems(items: MenuItemData[]) {
    ForEach(this.splitByDivider(items), (group: MenuItemData[], index: number) => {
      MenuItemGroup() {
        ForEach(group, (item: MenuItemData) => {
          if (item.type === 'submenu') {
            MenuItem({
              content: item.text ?? '',
              builder: (): void => this.SubmenuContent(item.submenuItems ?? [])
            })
          } else if (item.type === 'check') {
            MenuItem({ content: item.text ?? '' })
              .enabled(item.enabled ?? true)
              .selected(item.checked ?? false)
              .selectIcon(true)
              .onChange((checked: boolean) => {
                item.checked = checked;
                if (globalMenuClickHandler) {
                  globalMenuClickHandler(item);
                }
              })
          } else if (item.type === 'icon' && this.iconPixelMaps.has(item.id)) {
            MenuItem() {
              Row() {
                Image(this.iconPixelMaps.get(item.id))
                  .width(24)
                  .height(24)
                  .margin({ right: 8 })
                Text(item.text ?? '')
                  .fontSize(14)
              }
            }
              .enabled(item.enabled ?? true)
              .onClick(() => {
                if (globalMenuClickHandler) {
                  globalMenuClickHandler(item);
                }
              })
          } else {
            MenuItem({ content: item.text ?? item.predefinedType ?? '' })
              .enabled(item.enabled ?? true)
              .onClick(() => {
                if (globalMenuClickHandler) {
                  globalMenuClickHandler(item);
                }
              })
          }
        }, (item: MenuItemData) => item.id)
      }
    }, (_group: MenuItemData[], index: number) => `group_${index}`)
  }

  private splitByDivider(items: MenuItemData[]): MenuItemData[][] {
    const groups: MenuItemData[][] = [];
    let current: MenuItemData[] = [];
    for (const item of items) {
      if (item.type === 'predefined' && item.predefinedType === 'separator') {
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
  }

  @Builder
  MenuContent() {
    Menu() {
      this.RenderMenuItems(this.menuItems)
    }
  }

  @Builder
  MenuBarRow() {
    Row() {
      ForEach(this.menubarItems, (item: MenuItemData) => {
        Row() {
          if (item.icon && this.iconPixelMaps.has(item.id)) {
            Image(this.iconPixelMaps.get(item.id))
              .width(16)
              .height(16)
              .margin({ right: 4 })
          }
          Text(item.text ?? '')
            .fontSize(14)
            .fontColor((item.enabled ?? true) ? '#333333' : '#999999')
        }
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .enabled(item.enabled ?? true)
        .opacity((item.enabled ?? true) ? 1.0 : 0.5)
        .backgroundColor(
          this.activeDropdownId === item.id ? '#E0E0E0' :
          this.hoveredItemId === item.id ? '#EBEBEB' :
          '#F5F5F5'
        )
        .onClick(() => {
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
              this.activeDropdownShown = false;
              this.activeDropdownId = "";
            }
          }
        )
      }, (item: MenuItemData) => item.id)
    }
    .width("100%")
    .height(40)
    .backgroundColor('#F5F5F5')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  MenubarDropdownContent(item: MenuItemData) {
    Menu() {
      this.RenderMenuItems(this.getActiveDropdownItem()?.submenuItems ?? [])
    }
  }

  private getActiveDropdownItem(): MenuItemData | null {
    for (const item of this.menubarItems) {
      if (item.id === this.activeDropdownId) {
        return item;
      }
    }
    return null;
  }

  async aboutToAppear(): Promise<void> {
    hilog.info(DOMAIN, 'MainPage', '=== MainPage aboutToAppear START ===');
    hilog.info(DOMAIN, 'MainPage', 'Initializing MAIN WINDOW');

    // 主窗口专属逻辑：加载 Native Module
    const moduleName = Loadable.resolvePrimaryModuleName(this.moduleNames);
    if (!moduleName) {
      hilog.error(DOMAIN, 'MainPage', 'moduleName is empty, cannot initialize main window');
      throw new Error("MainPage.moduleName is required for main window");
    }

    hilog.info(DOMAIN, 'MainPage', 'Resolved moduleName: %{public}s', moduleName);
    this.resolvedModuleName = moduleName;

    hilog.info(DOMAIN, 'MainPage', 'Loading native module: %{public}s', moduleName);
    this.nativeModule = await Loadable.load(moduleName, this.loadMode);
    hilog.info(DOMAIN, 'MainPage', 'Native module loaded successfully');
  }

  onBackPress(): boolean {
    // 主窗口专属：处理返回键拦截
    try {
      if (typeof this.nativeModule?.onBackPressIntercept === "function") {
        return this.nativeModule.onBackPressIntercept();
      }
      if (typeof this.nativeModule?.on_back_press_intercept === "function") {
        return this.nativeModule.on_back_press_intercept();
      }
    } catch (err) {
      hilog.error(DOMAIN, 'MainPage', 'onBackPress failed: %{public}s', JSON.stringify(err));
    }
    return false;
  }

  build() {
    Stack() {
      Column() {
        if (this.isDesktop && this.menubarItems.length > 0 && this.menubarVisible) {
          this.MenuBarRow()
        }

        Row() {
          Column() {
            if (this.resolvedModuleName !== "") {
              DefaultXComponent({ moduleName: this.resolvedModuleName, windowId: 0 })
            } else {
              Text("Loading Main Window...")
                .fontSize(20)
                .fontColor(Color.Gray)
            }
          }.width("100%")
        }.layoutWeight(1).height("100%")

      }.width("100%").height("100%")
      .onKeyPreIme((event: KeyEvent) => {
        if (event.type === KeyType.Down && this.acceleratorMatcher.matches(event)) {
          const matchedItem = this.acceleratorMatcher.getMatchedItem();
          if (matchedItem && globalMenuClickHandler) {
            globalMenuClickHandler(matchedItem);
          }
          return true;
        }
        if (event.type === KeyType.Down && event.keyCode === KeyCode.KEYCODE_ESCAPE && !this.menubarVisible) {
          AppStorage.setOrCreate("__openharmony_ability_menubar_visible__::main", true);
          globalRecoverFn?.();
          return true;
        }
        return false;
      })

      Column()
        .width(1)
        .height(1)
        .position({ x: 0, y: 0 })
        .bindMenu(this.menuShown, this.MenuContent, {
          anchorPosition: { x: this.menuX, y: this.menuY },
          showInSubWindow: true,
          onWillDisappear: () => {
            this.menuShown = false;
          }
        })
    }
  }
}
