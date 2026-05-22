import { DefaultXComponent } from "./DefaultXComponent";
import { Loadable } from "../helper/loadable";
import { MenuItemData } from "../helper/menu_types";
import { image } from "@kit.ImageKit";
import { buffer } from "@kit.ArkTS";
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x1999;

export const RouteName = "NativeAbility";

let globalMenuClickHandler: ((item: MenuItemData) => void) | null = null;

export function setMenuClickHandler(handler: (item: MenuItemData) => void): void {
  globalMenuClickHandler = handler;
}

@Entry({ routeName: RouteName })
@Component
struct MainPage {
  @StorageProp("moduleName") moduleNames: string | string[] = "";
  @StorageProp("loadMode") loadMode: "async" | "sync" = "async";

  @State private nativeModule: ESObject | null = null;
  @State private resolvedModuleName: string = "";

  @StorageLink("__openharmony_ability_menu_shown__") menuShown: boolean = false;
  @StorageLink("__openharmony_ability_menu_x__") menuX: number = 0;
  @StorageLink("__openharmony_ability_menu_y__") menuY: number = 0;
  @Watch("onMenuJsonChange") @StorageLink("__openharmony_ability_menu_json__") menuJson: string = "[]";
  @State private menuItems: MenuItemData[] = [];
  private iconPixelMaps: Map<string, image.PixelMap> = new Map();

  onMenuJsonChange(): void {
    try {
      const items = JSON.parse(this.menuJson) as MenuItemData[];
      for (const pm of this.iconPixelMaps.values()) {
        pm.release();
      }
      this.iconPixelMaps.clear();
      this.prepareIcons(items);
      this.menuItems = items;
    } catch (e) {
      this.menuItems = [];
    }
  }

  private prepareIcons(items: MenuItemData[]): void {
    for (const item of items) {
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
        this.prepareIcons(item.submenuItems);
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
      Row() {
        Column() {
          if (this.resolvedModuleName !== "") {
        // 主窗口固定 windowId 为 0
            DefaultXComponent({ moduleName: this.resolvedModuleName, windowId: 0 })
          } else {
            Text("Loading Main Window...")
              .fontSize(20)
              .fontColor(Color.Gray)
          }
        }.width("100%")
      }.height("100%")

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
