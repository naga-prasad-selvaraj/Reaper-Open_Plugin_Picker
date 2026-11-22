# REAPER Open Plugin Picker

A clean-room REAPER Lua ReaScript for browsing installed effects, organizing them into custom categories, and adding them to the selected track.

**GitHub description:** A REAPER Lua FX picker with a searchable plugin library, customizable categories and subcategories, and optional plugin-window artwork capture.

## Features

- Browse the installed effects reported by REAPER in a card view or full plugin library.
- Search categorized effects and the scanned library, and page through library results.
- Create, rename, and delete custom categories and subcategories.
- Assign effects to more than one category.
- Insert an effect on the selected track and optionally capture its floating window as card artwork.
- Choose artwork manually or use generated fallback artwork when a capture is unavailable.
- Save categories, assignments, and artwork paths between sessions.

## Requirements

- REAPER with ReaScript support and a selected track when inserting an effect.
- Effects must be installed and visible to REAPER's FX browser.
- The script is written in Lua and does not need a separate Lua installation or compiled binary.
- Optional automatic plugin-window screenshots use **js_ReaScriptAPI**. Install it through ReaPack or another trusted source. Without it, the picker remains usable; screenshot capture may be unavailable and fallback artwork is used.

This project was documented against REAPER 7.86 on Windows. Other REAPER versions and operating systems may work, but have not been validated here. Automatic window capture can vary by operating system, plugin window type, and bridge/protection settings.

## Installation

1. Download `Reaper - Open Plugin Picker.lua` from this repository.
2. In REAPER, open **Actions → Show action list**.
3. Choose **New action → Load ReaScript...** and select the downloaded Lua file.
4. Select the new **Script: Reaper - Open Plugin Picker.lua** action and run it. Optionally assign a shortcut from the Action List.
5. Select a track before using an insert action.

The accompanying [installation and user manual](Reaper%20-%20Open%20Plugin%20Picker%20-%20Installation%20and%20User%20Manual.pdf) includes annotated screenshots, feature instructions, compatibility notes, and troubleshooting.

## Using the picker

### Cards

The Cards view displays effects you have organized into categories. Use the category bars to browse. Click a card to insert its effect on the selected track. Right-click a card to choose artwork or change its category assignments.

### Plugin Library

The Plugin Library lists the installed effects reported by REAPER, including effects not yet categorized. Search the library, move through result pages, then use **Add to category** or **Insert + snap**.

> **Track behavior:** Both **Add to category** and **Insert + snap** add the effect to the selected track and open its floating window. **Add to category** also assigns it to a category after the capture attempt; **Insert + snap** does not assign a category. The script does not automatically remove the inserted effect.

### Categories

Use the **+** controls to create main categories and subcategories. Right-click a category tab for rename and delete options. Categories are user-defined; the picker does not pre-populate genre or effect categories.

### Artwork

When snapshot capture is available, the script saves the image under REAPER's resource folder at `PluginPicker/Artwork`. If capture is unavailable, the effect can still be organized and inserted, and a generated fallback image is used. Artwork can also be selected manually from a card's context menu.

## Data and privacy

The script stores category names, effect assignments, and artwork paths in REAPER's persistent ExtState. Captured artwork is saved locally in REAPER's resource folder. The script does not send this information to a network service.

## License

This project is released under the MIT License. See [LICENSE](LICENSE). Third-party software such as REAPER, ReaPack, and js_ReaScriptAPI is not included and remains under its own license.
