import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export/export_format.dart';
import '../../domain/app_settings.dart';
import '../../state/settings_provider.dart';
import '../../theme/app_theme.dart';

const _pageSizes = <int>[25, 50, 100, 200, 500];

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return AstryxLayout(
      maxContentWidth: 720,
      header: AstryxHStack(
        gap: AstryxSpacingToken.spacing3,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          // Expanded, not Flexible beside a Spacer: two flex children with the
          // same factor split the free space between them, so the spacer only
          // ever gets half of it and the close button stops short of the edge.
          const Expanded(child: AstryxHeading('Settings', level: 1)),
          AstryxIconButton(
            icon: AstryxIconName.close,
            label: 'Close settings',
            tooltip: 'Close',
            variant: AstryxButtonVariant.ghost,
            onPressed: () => context.go('/'),
          ),
        ],
      ),
      child: AstryxVStack(
        gap: AstryxSpacingToken.spacing6,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          AstryxSection(
            title: 'Appearance',
            description:
                'Every colour, size and radius in the app resolves '
                'through the theme you pick here.',
            showDivider: true,
            child: AstryxVStack(
              gap: AstryxSpacingToken.spacing5,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                AstryxSelector<DextrTheme>(
                  label: 'Theme',
                  value: settings.theme,
                  onChanged: (theme) =>
                      notifier.setTheme(theme ?? DextrTheme.neutral),
                  options: <AstryxSelectorEntry<DextrTheme>>[
                    for (final theme in DextrTheme.values)
                      AstryxSelectorOption<DextrTheme>(
                        value: theme,
                        label: theme.label,
                        description: theme.description,
                      ),
                  ],
                ),
                _AccentPicker(
                  selected: settings.seedColor,
                  onChanged: notifier.setSeedColor,
                ),
                // Nothing on this page has a Save button behind it: every
                // control here applies the moment it changes, which is why the
                // one boolean below is a switch rather than a checkbox.
                //
                // A segmented control's own `label` is its accessible name and
                // is never painted, so the two below would sit unlabelled among
                // fields that all carry one. The field paints the words and
                // leaves the announcing to the control.
                AstryxField(
                  label: 'Colour mode',
                  child: AstryxSegmentedControl<AstryxColorMode>(
                    label: 'Colour mode',
                    value: settings.colorMode,
                    onChanged: notifier.setColorMode,
                    segments: const <AstryxSegment<AstryxColorMode>>[
                      AstryxSegment(
                        value: AstryxColorMode.system,
                        label: 'System',
                      ),
                      AstryxSegment(
                        value: AstryxColorMode.light,
                        label: 'Light',
                      ),
                      AstryxSegment(value: AstryxColorMode.dark, label: 'Dark'),
                    ],
                  ),
                ),
                AstryxField(
                  label: 'Density',
                  child: AstryxSegmentedControl<AstryxTableDensity>(
                    label: 'Density',
                    value: settings.density,
                    onChanged: notifier.setDensity,
                    segments: const <AstryxSegment<AstryxTableDensity>>[
                      AstryxSegment(
                        value: AstryxTableDensity.compact,
                        label: 'Compact',
                      ),
                      AstryxSegment(
                        value: AstryxTableDensity.balanced,
                        label: 'Balanced',
                      ),
                      AstryxSegment(
                        value: AstryxTableDensity.spacious,
                        label: 'Spacious',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          AstryxSection(
            title: 'Data',
            showDivider: true,
            child: AstryxVStack(
              gap: AstryxSpacingToken.spacing5,
              align: AstryxStackAlign.stretch,
              children: <Widget>[
                AstryxSelector<int>(
                  label: 'Rows per page',
                  description:
                      'How many rows the browser fetches at a time. '
                      'The table draws every row it is given, so this is also '
                      'how much work one page is.',
                  value: _pageSizes.contains(settings.pageSize)
                      ? settings.pageSize
                      : 100,
                  width: 200,
                  onChanged: (value) => notifier.setPageSize(value ?? 100),
                  options: <AstryxSelectorEntry<int>>[
                    for (final size in _pageSizes)
                      AstryxSelectorOption<int>(value: size, label: '$size'),
                  ],
                ),
                AstryxSwitch(
                  label: 'Confirm before deleting',
                  description:
                      'Ask first when removing rows, objects or '
                      'connections.',
                  value: settings.confirmDeletes,
                  onChanged: notifier.setConfirmDeletes,
                ),
              ],
            ),
          ),
          AstryxSection(
            title: 'Export',
            showDivider: true,
            child: _ExportDefaults(settings: settings, notifier: notifier),
          ),
          AstryxSection(
            title: 'Reset',
            child: _ResetButton(onReset: notifier.reset),
          ),
        ],
      ),
    );
  }
}

/// An accent on top of the theme, or the theme's own.
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.selected, required this.onChanged});

  /// Null means the theme decides.
  final int? selected;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return AstryxField(
      label: 'Accent',
      description:
          'Overrides the theme’s accent. Everything derived from it — '
          'hover, pressed, muted — is regenerated to match.',
      // A grid, not a wrapping row: a selectable card with no width given to it
      // fills the line it is on, so a wrap put one swatch on each row. Columns
      // also line the names up, which a wrap of ragged-width cards does not.
      child: AstryxGrid(
        minWidth: 190,
        gap: AstryxSpacingToken.spacing2,
        children: <Widget>[
          _Swatch(
            name: 'Theme default',
            color: null,
            selected: selected == null,
            onPressed: () => onChanged(null),
          ),
          for (final (name, argb) in dextrAccents)
            _Swatch(
              name: name,
              color: Color(argb),
              selected: selected == argb,
              onPressed: () => onChanged(argb),
            ),
        ],
      ),
    );
  }
}

/// One accent option.
///
/// A card rather than a bare coloured box: it needs a name, a selected state and
/// a focus ring, and `AstryxSelectableCard` is the control that has all three.
/// The name is never conveyed by the colour alone — it is the accessible name,
/// and the tick is a second signal beside the hue.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onPressed,
  });

  final String name;
  final Color? color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);

    return AstryxSelectableCard(
      label: name,
      control: AstryxSelectableCardControl.radio,
      padding: AstryxSpacingToken.spacing2,
      controlSize: AstryxToggleSize.sm,
      selected: selected,
      onSelectedChanged: (_) => onPressed(),
      child: AstryxHStack(
        gap: AstryxSpacingToken.spacing2,
        children: <Widget>[
          Container(
            width: theme.size(AstryxSizeToken.elementSm),
            height: theme.size(AstryxSizeToken.elementSm),
            decoration: BoxDecoration(
              // The theme's own accent, for the "no override" option.
              color: color ?? theme.color(AstryxColorToken.accent),
              borderRadius: theme.borderRadius(AstryxRadiusToken.inner),
              border: Border.all(
                color: theme.color(AstryxColorToken.border),
                width: theme.borderWidth(),
              ),
            ),
          ),
          // Flexible because the card is now a grid cell rather than a row of
          // its own: the name has to give way at the column width instead of
          // pushing past it.
          Flexible(
            child: AstryxText(
              name,
              type: AstryxTextType.supporting,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reset, behind a confirmation: it is one press that changes six settings.
/// What every export dialog opens on.
///
/// Not the whole of the export dialog's options — the ones that are a habit
/// rather than a decision. A format and a null placeholder are the same on every
/// export somebody does; whether that particular JSON is indented is not.
///
/// The null placeholder is a text field rather than a choice because the answer
/// is a string somebody's pipeline decided: `NULL`, `\N`, `(null)`, `-`.
class _ExportDefaults extends StatefulWidget {
  const _ExportDefaults({required this.settings, required this.notifier});

  final AppSettings settings;
  final SettingsNotifier notifier;

  @override
  State<_ExportDefaults> createState() => _ExportDefaultsState();
}

class _ExportDefaultsState extends State<_ExportDefaults> {
  late final TextEditingController _nullText = TextEditingController(
    text: widget.settings.exportNullText,
  );

  @override
  void dispose() {
    _nullText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing5,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxSelector<ExportFormat>(
          label: 'Default format',
          description: 'What the export dialog is set to when it opens.',
          value: settings.exportFormat,
          width: 260,
          onChanged: (value) =>
              widget.notifier.setExportFormat(value ?? ExportFormat.csv),
          options: <AstryxSelectorEntry<ExportFormat>>[
            for (final format in ExportFormat.values)
              AstryxSelectorOption<ExportFormat>(
                value: format,
                label: format.label,
                description: format.description,
              ),
          ],
        ),
        AstryxSwitch(
          label: 'Header row by default',
          description:
              'Whether a CSV or TSV export starts with the column names.',
          value: settings.exportIncludeHeader,
          onChanged: widget.notifier.setExportIncludeHeader,
        ),
        AstryxTextInput(
          label: 'Text for NULL',
          description:
              'What a CSV, TSV or markdown export writes where a value is '
              'missing. Empty gives a blank cell; set something like NULL '
              'where an empty string and a missing value must not look the '
              'same.',
          controller: _nullText,
          width: 260,
          placeholder: 'empty',
          onChanged: widget.notifier.setExportNullText,
        ),
      ],
    );
  }
}

class _ResetButton extends StatefulWidget {
  const _ResetButton({required this.onReset});

  final Future<void> Function() onReset;

  @override
  State<_ResetButton> createState() => _ResetButtonState();
}

class _ResetButtonState extends State<_ResetButton> {
  final AstryxDialogController _confirm = AstryxDialogController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AstryxHStack(
      gap: AstryxSpacingToken.spacing3,
      children: <Widget>[
        AstryxButton(label: 'Reset to defaults', onPressed: _confirm.show),
        AstryxAlertDialog(
          controller: _confirm,
          title: 'Reset every setting?',
          description:
              'Theme, accent, colour mode, density, page size and the '
              'delete confirmation all go back to their defaults. Your '
              'connections are not touched.',
          confirmLabel: 'Reset settings',
          onConfirm: () async {
            // Resolved before the await: the scope is what shows the toast, and
            // reaching for it through a context afterwards is the async-gap bug.
            final toasts = AstryxToastScope.of(context);
            await widget.onReset();
            toasts.show(const AstryxToast(message: 'Settings reset'));
          },
        ),
      ],
    );
  }
}
