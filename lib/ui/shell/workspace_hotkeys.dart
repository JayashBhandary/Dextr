/// The workspace's own keyboard shortcuts, defined once.
library;

import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/services.dart';

/// Closes the active tab.
///
/// `.mod` is ⌘ on macOS and Ctrl elsewhere, which is what "close this" means on
/// each platform — and lets `AstryxKbd.hotkey` draw the right cap in the menu
/// instead of a hard-coded ⌘ that lies on Linux and Windows.
const closeTabHotkey = AstryxHotkey.mod(LogicalKeyboardKey.keyW);

/// Closes every open tab.
const closeAllTabsHotkey = AstryxHotkey.mod(LogicalKeyboardKey.keyW, alt: true);

/// Collapses and expands the connections rail.
const toggleRailHotkey = AstryxHotkey.mod(LogicalKeyboardKey.keyB);
