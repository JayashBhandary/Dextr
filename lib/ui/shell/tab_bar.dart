import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/active_source_provider.dart';
import '../../state/workspace_provider.dart';
import '../widgets/dextr_icons.dart';
import '../widgets/dextr_more_menu.dart';

/// The strip of open objects across the top of the workspace.
///
/// The tabs carry no close button of their own: `AstryxTab` is a value in a
/// strip, not a container for another control, and a button inside a tab is a
/// second interactive element inside one tab stop. Closing lives on ⌘/Ctrl+W
/// and in the menu at the end of the strip, where it is still visible and still
/// reachable from the keyboard.
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
                      AstryxTab<String>(value: tab.id, label: tab.label()),
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
              trailing: const AstryxKbd.chord(<String>[
                '⌘',
                'W',
              ], semanticsLabel: 'Command W'),
              enabled: workspace.activeTabId != null,
              onSelected: notifier.closeActiveTab,
            ),
            AstryxMenuItem(
              label: 'Close all tabs',
              trailing: const AstryxKbd.chord(<String>[
                '⌘',
                '⌥',
                'W',
              ], semanticsLabel: 'Command Option W'),
              enabled: tabs.isNotEmpty,
              onSelected: notifier.closeAllTabs,
            ),
          ],
        ),
      ],
    );
  }
}
