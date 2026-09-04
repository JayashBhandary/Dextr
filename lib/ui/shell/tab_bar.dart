import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/active_source_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/dextr_more_menu.dart';
import 'workspace_hotkeys.dart';

/// The strip of open objects across the top of the workspace.
///
/// Every tab carries its own close button: `AstryxTab.onClose` draws one after
/// the label, always visible rather than revealed on hover, and keeps it as a
/// semantics node of its own beside the tab. Closing is also on ⌘/Ctrl+W, on
/// Delete or Backspace while the strip holds focus, and in the menu at the end
/// of the strip — the same close reachable four ways, none of them the only one.
class WorkspaceTabBar extends ConsumerWidget {
  const WorkspaceTabBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(workspaceProvider);
    final notifier = ref.read(workspaceProvider.notifier);
    final activeConnectionId = ref.watch(activeConnectionIdProvider);
    final tabs = workspace.tabs;

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        Expanded(
          child: tabs.isEmpty
              ? const AstryxText(
                  'No objects open',
                  type: AstryxTextType.supporting,
                  color: AstryxTextColor.secondary,
                )
              : AstryxTabList<String>(
                  label: 'Open objects',
                  size: AstryxTabSize.sm,
                  showDivider: false,
                  value: workspace.activeTabId,
                  onChanged: notifier.activate,
                  tabs: <AstryxTab<String>>[
                    for (final tab in tabs)
                      AstryxTab<String>(
                        value: tab.id,
                        label: tab.label(),
                        // Named after what is being closed, because "Close" on
                        // eight tabs is eight identical announcements.
                        closeLabel: 'Close ${tab.label()}',
                        onClose: () => notifier.closeTab(tab.id),
                      ),
                  ],
                ),
        ),
        if (activeConnectionId != null)
          AstryxIconButton.custom(
            label: 'New query tab',
            tooltip: 'New query tab',
            variant: AstryxButtonVariant.ghost,
            size: AstryxButtonSize.sm,
            onPressed: () => notifier.openQueryTab(activeConnectionId),
            child: const Icon(DextrIcons.terminal),
          ),
        DextrMoreMenu(
          label: 'Tab actions',
          entries: <AstryxMenuEntry>[
            AstryxMenuItem(
              label: 'Close tab',
              trailing: const AstryxKbd.hotkey(closeTabHotkey),
              enabled: workspace.activeTabId != null,
              onSelected: notifier.closeActiveTab,
            ),
            AstryxMenuItem(
              label: 'Close all tabs',
              trailing: const AstryxKbd.hotkey(closeAllTabsHotkey),
              enabled: tabs.isNotEmpty,
              onSelected: notifier.closeAllTabs,
            ),
          ],
        ),
      ],
    );
  }
}
