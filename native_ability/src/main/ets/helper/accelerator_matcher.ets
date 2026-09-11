import { MenuItemData } from "./menu_types";

const SPECIAL_KEY_MAP: Map<string, string> = new Map([
  ["Escape", "Esc"],
  ["KEYCODE_ESCAPE", "Esc"],
  ["Delete", "Del"],
  ["KEYCODE_DELETE", "Del"],
  ["Insert", "Ins"],
  ["KEYCODE_INSERT", "Ins"],
  ["PageUp", "PgUp"],
  ["KEYCODE_PAGE_UP", "PgUp"],
  ["PageDown", "PgDn"],
  ["KEYCODE_PAGE_DOWN", "PgDn"],
  ["Enter", "Enter"],
  ["KEYCODE_ENTER", "Enter"],
  ["Space", "Space"],
  ["KEYCODE_SPACE", "Space"],
  ["Tab", "Tab"],
  ["KEYCODE_TAB", "Tab"],
  ["Backquote", "`"],
  ["KEYCODE_BACKQUOTE", "`"],
]);

// OHOS modifier keyCode constants — these arrive as separate key events
// and should NOT be treated as accelerator key candidates
const MODIFIER_KEYCODES: Set<number> = new Set([
  2072, // KEYCODE_CTRL_LEFT
  2073, // KEYCODE_CTRL_RIGHT
  2047, // KEYCODE_SHIFT_LEFT
  2048, // KEYCODE_SHIFT_RIGHT
  2045, // KEYCODE_ALT_LEFT
  2046, // KEYCODE_ALT_RIGHT
  2076, // KEYCODE_META_LEFT
  2077, // KEYCODE_META_RIGHT
]);

// Same keycodes mapped to the combo-string modifier names used by
// `isModifierPressed` (issue #111 modifier tracking).
const MODIFIER_KEYCODE_TO_NAME: Map<number, string> = new Map<number, string>();
MODIFIER_KEYCODE_TO_NAME.set(2072, "ctrl");
MODIFIER_KEYCODE_TO_NAME.set(2073, "ctrl");
MODIFIER_KEYCODE_TO_NAME.set(2047, "shift");
MODIFIER_KEYCODE_TO_NAME.set(2048, "shift");
MODIFIER_KEYCODE_TO_NAME.set(2045, "alt");
MODIFIER_KEYCODE_TO_NAME.set(2046, "alt");

/**
 * Modifier keys tracked from their own down/up events (issue #111 device
 * finding, 2026-09-10: `getModifierKeyState` reports Ctrl as NOT pressed for
 * real Ctrl+key presses on the 2in1 device — combos collapsed to e.g. "z"
 * and never matched. Modifier keydown/keyup events DO flow through
 * onKeyPreIme (keyCode 2072 etc.), so tracking them is API-independent and
 * deterministic).
 *
 * MODULE-level (not per-matcher): releases that happen while the window is
 * unfocused are never seen (minimize while Ctrl held, dropdown sub-window
 * taking focus, app switch) and would leave stale bits — any later bare key
 * would false-positive a "ctrl+…" combo (observed on device: a plain `m`
 * re-triggered Minimize after a Ctrl+M minimize). `clearAllTrackedModifiers`
 * is called on window INACTIVE/HIDDEN (NativeAbility) and on menu open
 * (MenuBarComponent) to flush exactly those stale bits.
 */
const trackedModifiers: Set<string> = new Set();

/** Flush every matcher's tracked modifiers (window focus loss / menu open). */
export function clearAllTrackedModifiers(): void {
  trackedModifiers.clear();
}

// Clipboard accelerators handled natively by webview — intercepting them breaks paste/copy/cut
const CLIPBOARD_ACCELERATORS: Set<string> = new Set([
  "ctrl+c", // copy
  "ctrl+x", // cut
  "ctrl+v", // paste
  "ctrl+a", // selectAll
  "ctrl+z", // undo
  "ctrl+y", // redo
]);

export class AcceleratorMatcher {
  private accelerators: Map<string, MenuItemData> = new Map();
  private matchedItem: MenuItemData | null = null;

  buildFromItems(items: MenuItemData[]): void {
    this.accelerators.clear();
    const queue: MenuItemData[] = [...items];
    while (queue.length > 0) {
      const item = queue.shift()!;
      if (item.accelerator) {
        const keyCombo = this.normalizeAccelerator(item.accelerator);
        this.accelerators.set(keyCombo, item);
      }
      if (item.submenuItems) {
        queue.push(...item.submenuItems);
      }
    }
  }

  private normalizeAccelerator(accel: string): string {
    return accel.toLowerCase();
  }

  /**
   * Update the shared tracked-modifier set from a key event. Must run for
   * EVERY event (including modifier-only ones, which the match methods
   * otherwise skip) — all three public match methods call this first.
   */
  trackModifiers(event: KeyEvent): void {
    const modifier = MODIFIER_KEYCODE_TO_NAME.get(event.keyCode);
    if (modifier !== undefined) {
      if (event.type === KeyType.Down) {
        trackedModifiers.add(modifier);
      } else if (event.type === KeyType.Up) {
        trackedModifiers.delete(modifier);
      }
    }
  }

  /** Drop this matcher's tracked modifiers (see module doc for when). */
  clearTrackedModifiers(): void {
    trackedModifiers.clear();
  }

  /**
   * Build the combo string ("ctrl+shift+…+key") for a key event, or null
   * when the event cannot start a combo (not a Down, modifier-only, or no
   * readable key text). Also updates the tracked modifiers. Shared by the
   * closed-menu match (onKeyPreIme) and the open-menu handler
   * (MenuBarComponent's Menu.onKeyEvent — keyboardShortcut does not fire
   * inside menu sub-windows on device, but Menu nodes DO receive the
   * KeyEvent through the focus chain).
   */
  buildComboForEvent(event: KeyEvent): string | null {
    this.trackModifiers(event);
    if (event.type !== KeyType.Down) {
      return null;
    }
    // Skip modifier-only key events (Ctrl/Shift/Alt arrive separately)
    if (MODIFIER_KEYCODES.has(event.keyCode)) {
      return null;
    }
    const keyText = this.getKeyText(event);
    if (!keyText) {
      return null;
    }
    let combo = "";
    if (this.isModifierPressed(event, "Ctrl")) combo += "ctrl+";
    if (this.isModifierPressed(event, "Shift")) combo += "shift+";
    if (this.isModifierPressed(event, "Alt")) combo += "alt+";
    return combo + keyText.toLowerCase();
  }

  matches(event: KeyEvent): boolean {
    const combo = this.buildComboForEvent(event);
    if (combo === null) {
      return false;
    }
    // Clipboard shortcuts handled natively by webview — don't intercept
    // (only applies to the closed-menu path; while a menu sub-window holds
    // focus the webview sees no keys at all, and the open-menu handler in
    // MenuBarComponent does its own lookup without this exclusion).
    if (CLIPBOARD_ACCELERATORS.has(combo)) {
      return false;
    }
    console.info(
      `[Accelerator] combo="${combo}", available=[${Array.from(this.accelerators.keys()).join(",")}]`,
    );
    if (this.accelerators.has(combo)) {
      this.matchedItem = this.accelerators.get(combo)!;
      return true;
    }
    return false;
  }

  private isModifierPressed(event: KeyEvent, modifier: string): boolean {
    // Primary: tracking from modifier keydown/keyup events —
    // getModifierKeyState is unreliable on device (see module doc).
    if (trackedModifiers.has(modifier)) {
      return true;
    }
    // Fallback: the API, for events that bypassed tracking (e.g. a key
    // arriving mid-combo from a window that never saw the modifier down).
    if (event.getModifierKeyState) {
      const result = event.getModifierKeyState([modifier]);
      if (typeof result === "boolean") {
        return result;
      }
      if (result && typeof result === "object") {
        return !!result[modifier];
      }
    }
    return false;
  }

  getMatchedItem(): MenuItemData | null {
    return this.matchedItem;
  }

  /**
   * Returns true if the key event is a clipboard accelerator (Ctrl+C/X/V/A/Z/Y).
   * Used by onKeyPreIme to block native clipboard shortcuts when with_clipboard(false).
   * Orthogonal to matches(): matches() always skips clipboard keys (lets ArkWeb handle);
   * this method identifies them so the caller can consume them when clipboard is disabled.
   */
  matchesClipboardShortcut(event: KeyEvent): boolean {
    this.trackModifiers(event);
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (MODIFIER_KEYCODES.has(event.keyCode)) {
      return false;
    }
    const keyText = this.getKeyText(event);
    if (!keyText) {
      return false;
    }
    let combo = "";
    if (this.isModifierPressed(event, "Ctrl")) combo += "ctrl+";
    combo += keyText.toLowerCase();
    return CLIPBOARD_ACCELERATORS.has(combo);
  }

  /**
   * Returns true if the key event is a zoom hotkey (Ctrl+=/-/0, incl. KEYCODE_* forms).
   * Used by onKeyPreIme to block native zoom when with_zoom_hotkeys(false).
   * See ohos-webview-flag-zoom-hotkeys spec.
   */
  matchesZoomShortcut(event: KeyEvent): boolean {
    this.trackModifiers(event);
    if (event.type !== KeyType.Down) {
      return false;
    }
    if (MODIFIER_KEYCODES.has(event.keyCode)) {
      return false;
    }
    if (!this.isModifierPressed(event, "Ctrl")) {
      return false;
    }
    const keyText = this.getKeyText(event);
    if (!keyText) {
      return false;
    }
    const k = keyText.toLowerCase();
    return k === "=" || k === "0" || k === "-" || k === "equals" || k === "minus";
  }

  private getKeyText(event: KeyEvent): string | null {
    const text = event.keyText;
    if (!text) {
      return null;
    }
    if (SPECIAL_KEY_MAP.has(text)) {
      return SPECIAL_KEY_MAP.get(text)!;
    }
    // OHOS returns keyText as KEYCODE_* format (e.g. "KEYCODE_O")
    // Strip prefix and normalize to simple key letter
    if (text.startsWith("KEYCODE_")) {
      const raw = text.substring("KEYCODE_".length);
      // Single letter keys (A-Z, 0-9) → just the letter
      if (raw.length === 1) {
        return raw;
      }
      // Multi-part names like DPAD_UP, SPACE, ESCAPE → check SPECIAL_KEY_MAP first
      // then lowercase for general keys
      if (SPECIAL_KEY_MAP.has(text)) {
        return SPECIAL_KEY_MAP.get(text)!;
      }
      return raw;
    }
    return text;
  }
}

// Per-window clipboard flag: windowId -> clipboard enabled (default true = ArkWeb native).
// Set by WindowManager.setWebviewFlags (from WebviewPlugin.create's payload.clipboard); read by
// onKeyPreIme to decide whether to block clipboard shortcuts. See ohos-webview-flag-clipboard spec.
const clipboardEnabledMap: Map<number, boolean> = new Map();

export function setClipboardEnabled(windowId: number, enabled: boolean): void {
  clipboardEnabledMap.set(windowId, enabled);
}

export function isClipboardEnabled(windowId: number): boolean {
  // Default true (ArkWeb native clipboard) when not explicitly set.
  return clipboardEnabledMap.get(windowId) ?? true;
}

export function clearClipboardEnabled(windowId: number): void {
  clipboardEnabledMap.delete(windowId);
}

// Per-window zoom-hotkeys flag: windowId -> enabled (default true = ArkWeb native zoom).
// Set by WindowManager.setWebviewFlags (from WebviewPlugin.create's payload.zoomHotkeys); read
// by onKeyPreIme to decide whether to block zoom hotkeys. See ohos-webview-flag-zoom-hotkeys spec.
const zoomHotkeysEnabledMap: Map<number, boolean> = new Map();

export function setZoomHotkeysEnabled(windowId: number, enabled: boolean): void {
  zoomHotkeysEnabledMap.set(windowId, enabled);
}

export function isZoomHotkeysEnabled(windowId: number): boolean {
  // Default true (ArkWeb native zoom) when not explicitly set.
  return zoomHotkeysEnabledMap.get(windowId) ?? true;
}

export function clearZoomHotkeysEnabled(windowId: number): void {
  zoomHotkeysEnabledMap.delete(windowId);
}
