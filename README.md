# REAPER Open Plugin Picker

A Lua ReaScript for browsing, searching, categorizing, and inserting installed effects in REAPER. It provides a categorized Cards view and a searchable Plugin Library of scanned effects.

## Platform status

Tested on **Windows with REAPER 7.86**. macOS and Linux have not been tested, so compatibility on those systems is unconfirmed. Automatic screenshot capture uses Windows-style screen capture APIs and may not work on other platforms.

## Features

- Browse categorized effects as cards or view all scanned effects in Plugin Library.
- Search each view and page through results.
- Create, rename, and delete categories, including nested subcategories.
- Assign effects to categories from either view. Assignment menus show full category paths, such as `FX › EQ Filters`.
- Use checkmarks to identify assigned categories. Selecting a checked path removes that exact assignment; parent and child assignments are independent.
- Insert an effect and attempt to capture its floating window as card artwork.
- Choose artwork manually or use metadata artwork.

## Requirements

- REAPER with Lua ReaScript support.
- Effects must already be installed and available in REAPER’s FX browser.
- A selected track is required to insert an effect.
- `js_ReaScriptAPI` is recommended for automatic plugin-window screenshots and dialog interaction. Browsing and insertion can still work without it, but automatic capture may be unavailable.

## Installation

1. Download or clone this repository and extract the ZIP if needed.
2. In REAPER, open **Actions → Show action list**.
3. Choose **New action → Load ReaScript...**.
4. Select `Reaper - Open Plugin Picker.lua`.
5. Select the script in the Action List and click **Run**. You can optionally assign it a keyboard shortcut.

## Using the picker

### Cards

Click **Cards** to browse categorized effects. Click a category to filter the cards, then click a card to insert that effect on the selected track.

Right-click a card to choose artwork or assign categories. Category destinations are displayed as full paths. Selecting a checked category removes that exact assignment.

### Plugin Library

Click **Plugin Library** to search all scanned effects. Use **Add to category** to choose a category path, insert the effect, and attempt to capture its artwork. Choosing a checked path removes that assignment. **Insert + snap** inserts and captures without assigning a category.

Automatic capture waits at least 3 seconds and retries for up to 15 seconds. Keep the plugin’s floating window visible during capture. Some plugin interfaces may not produce a usable image; use the card’s image menu to choose artwork manually.

## Data storage

Category names and effect assignments are stored in REAPER’s persistent ExtState. Captured images are stored in the REAPER resource folder under `PluginPicker/Artwork`.

## Troubleshooting

- **An effect is missing:** confirm REAPER detects it in the FX browser, rescan if needed, and reopen the picker.
- **No effect is inserted:** select a track before choosing the effect.
- **No snapshot is captured:** keep the plugin window visible and unobstructed. Install or update `js_ReaScriptAPI`; if capture still fails, choose an image manually.
- **macOS or Linux:** compatibility has not been confirmed.

## License

See [LICENSE](LICENSE).
