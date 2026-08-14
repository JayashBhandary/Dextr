import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

/// A "…" button and the menu behind it, at the width of a menu rather than the
/// width of the window.
///
/// The same composition `AstryxMoreMenu` makes, with one addition: a width. A
/// menu surface stretches its rows to whatever width it is offered, and an
/// overlay with nothing else bounding it offers the whole viewport — so three
/// short actions end up spanning the screen. `AstryxMoreMenu` has no width to
/// pass down, which is the only reason this exists rather than that.
class DextrMoreMenu extends StatelessWidget {
  const DextrMoreMenu({
    super.key,
    required this.label,
    required this.entries,
    this.width = 260,
    this.align = AstryxOverlayAlign.end,
    this.icon = AstryxIconName.moreHorizontal,
    this.iconWidget,
    this.size = AstryxButtonSize.sm,
    this.variant = AstryxButtonVariant.ghost,
    this.enabled = true,
  });

  /// The trigger's accessible name, its tooltip, and the menu's name.
  final String label;

  /// The rows, in order.
  final List<AstryxMenuEntry> entries;

  /// How wide the surface is. Wide enough for the longest label these menus
  /// carry, and narrow enough to still read as a menu.
  final double width;

  /// Which of the trigger's edges the menu lines up with.
  ///
  /// The end, because a "…" is the last thing in whatever row it belongs to: a
  /// menu aligned to its *start* edge hangs off into the content beside it —
  /// wider than its trigger, and reading as though it belongs to something
  /// else. Aligned to the end it drops under the button it came from.
  final AstryxOverlayAlign align;

  /// The glyph on the trigger, from the design system's own registry.
  final AstryxIconName icon;

  /// A glyph the registry does not have — one of [DextrIcons]. Takes precedence
  /// over [icon] when given.
  final Widget? iconWidget;

  /// The trigger's size.
  final AstryxButtonSize size;

  /// The trigger's variant.
  final AstryxButtonVariant variant;

  /// Whether the menu opens.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AstryxDropdownMenu(
      label: label,
      entries: entries,
      width: width,
      align: align,
      matchTriggerWidth: false,
      triggerBuilder: (context, controller) => iconWidget == null
          ? AstryxIconButton(
              icon: icon,
              label: label,
              tooltip: label,
              size: size,
              variant: variant,
              enabled: enabled,
              onPressed: controller.toggle,
            )
          : AstryxIconButton.custom(
              label: label,
              tooltip: label,
              size: size,
              variant: variant,
              enabled: enabled,
              onPressed: controller.toggle,
              child: iconWidget!,
            ),
    );
  }
}
