import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/export/export_format.dart';
import '../../core/logger.dart';
import '../../core/version.dart';
import '../../domain/app_settings.dart';
import '../../services/app_reset.dart';
import '../../services/update_service.dart';
import '../../state/app_reset_provider.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import '../../state/update_provider.dart';
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
          const AstryxSection(
            title: 'Updates',
            description:
                'Which build this is, and whether a newer one has been '
                'published.',
            showDivider: true,
            child: _Updates(),
          ),
          AstryxSection(
            title: 'Reset',
            description:
                'Puts the settings above back to their defaults. Your '
                'connections stay where they are.',
            showDivider: true,
            child: _ResetButton(onReset: notifier.reset),
          ),
          const AstryxSection(
            title: 'Reset application',
            description:
                'Removes everything Dextr has stored on this machine, so the '
                'next launch is a first launch.',
            child: _ResetApplication(),
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

/// The version this build is, and what the release feed says about it.
///
/// The check is a button rather than something that happens on open: this is a
/// database client, and a page that phones out to github.com the moment it is
/// looked at is a page that does something the user did not ask for on a machine
/// where that may be noticed.
///
/// Nothing here writes to the installed application. Replacing /opt/dextr or
/// /Applications/Dextr.app needs the privileges the install scripts ask for, and
/// a client that could quietly elevate itself to overwrite its own binary would
/// be a worse thing to have than the update it saves. So "Update now" opens the
/// release and hands over the one-line command that installs it.
class _Updates extends ConsumerStatefulWidget {
  const _Updates();

  @override
  ConsumerState<_Updates> createState() => _UpdatesState();
}

class _UpdatesState extends ConsumerState<_Updates> {
  Future<void> _openRelease(UpdateCheck check) async {
    final toasts = AstryxToastScope.of(context);
    try {
      await ref.read(externalOpenProvider).openUrl(check.releaseUrl);
      toasts.show(
        const AstryxToast(
          message:
              'Release page opened. Run the command below to install it.',
        ),
      );
    } catch (e, st) {
      log.e('Could not open the release page', error: e, stackTrace: st);
      toasts.show(
        AstryxToast(
          message: 'Could not open a browser: $e',
          type: AstryxToastType.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateProvider);

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing4,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxMetadataList(
          direction: AstryxMetadataListDirection.inline,
          items: <AstryxMetadataItem>[
            AstryxMetadataItem.text(label: 'Version', value: appVersion),
            AstryxMetadataItem.text(label: 'Releases', value: appRepository),
          ],
        ),
        AstryxHStack(
          children: <Widget>[
            AstryxButton(
              label: 'Check for updates',
              variant: AstryxButtonVariant.secondary,
              loading: state.isLoading,
              onPressed: ref.read(updateProvider.notifier).check,
            ),
          ],
        ),
        // Three outcomes, and the one nobody has asked for yet draws nothing:
        // a banner saying "not checked" is a banner saying nothing happened.
        ...switch (state) {
          AsyncError(:final error) => <Widget>[
            AstryxBanner(
              status: AstryxBannerStatus.error,
              title: 'Could not check for updates',
              description: '$error',
            ),
          ],
          AsyncData(value: final UpdateCheck check) => _result(check),
          _ => const <Widget>[],
        },
      ],
    );
  }

  /// What a completed check has to say.
  List<Widget> _result(UpdateCheck check) {
    if (!check.isUpdateAvailable) {
      return <Widget>[
        AstryxBanner(
          status: AstryxBannerStatus.success,
          title: 'Dextr is up to date',
          description:
              '${check.latestVersion} is the newest published release.',
        ),
      ];
    }

    return <Widget>[
      AstryxBanner(
        status: AstryxBannerStatus.info,
        title: '${check.latestVersion} is available',
        description:
            'This build is ${check.currentVersion}. Updating replaces the '
            'installed application and asks for your password, so it is done '
            'by the installer rather than from in here — your connections and '
            'settings are left where they are.',
        actions: <Widget>[
          AstryxButton(
            label: 'Update now',
            size: AstryxButtonSize.sm,
            onPressed: () => _openRelease(check),
          ),
        ],
      ),
      // The command, not a description of it: it is the same one-liner the
      // README documents, and the block carries its own copy button.
      AstryxCodeBlock(
        UpdateService.installCommand(),
        language: UpdateService.installShell(),
        wrap: true,
      ),
    ];
  }
}

/// Reset, behind a confirmation: it is one press that changes six settings.
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

/// The factory reset: every connection, every credential, every setting.
///
/// Kept in its own section, away from the settings reset above it, because the
/// two are one word apart in the UI and worlds apart in consequence. The banner
/// is permanent rather than something the dialog says for the first time — a
/// user has to be able to see what this does *before* pressing anything.
class _ResetApplication extends ConsumerStatefulWidget {
  const _ResetApplication();

  @override
  ConsumerState<_ResetApplication> createState() => _ResetApplicationState();
}

class _ResetApplicationState extends ConsumerState<_ResetApplication> {
  final AstryxDialogController _confirm = AstryxDialogController();

  /// Whether a wipe is in flight. The keychain and two files are several
  /// awaits, and a second press part-way through would run the whole thing
  /// again over half-deleted state.
  bool _running = false;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    if (_running) return;
    setState(() => _running = true);
    // Resolved before the await: the scope is what shows the toast, and
    // reaching for it through a context afterwards is the async-gap bug.
    final toasts = AstryxToastScope.of(context);
    try {
      final report = await resetApplication(ref);
      toasts.show(
        AstryxToast(
          message: _summarise(report),
          type: report.isClean
              ? AstryxToastType.neutral
              : AstryxToastType.error,
          // A failure stays until it is dismissed. What survived a reset is a
          // credential still on the machine, and five seconds is not long
          // enough to read that and decide what to do about it.
          duration: report.isClean ? const Duration(seconds: 5) : Duration.zero,
        ),
      );
    } catch (e, st) {
      // Caught rather than left to the zone: the one press a user makes here is
      // the one they most need an answer to, and an uncaught error would leave
      // the button spinning with nothing said.
      log.e('Application reset failed', error: e, stackTrace: st);
      toasts.show(
        AstryxToast(
          message: 'Reset failed: $e',
          type: AstryxToastType.error,
          duration: Duration.zero,
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// What the toast says: the counts, then anything that did not go.
  String _summarise(AppResetReport report) {
    final connections = report.connectionsRemoved;
    final credentials = report.credentialsRemoved;
    final done =
        'Application reset. '
        '$connections connection${connections == 1 ? '' : 's'} and '
        '$credentials credential${credentials == 1 ? '' : 's'} removed.';
    if (report.isClean) return done;
    return '$done ${report.failures.join(' ')}';
  }

  @override
  Widget build(BuildContext context) {
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing4,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        // announce: false — it is part of the page every time it is opened, and
        // reading it out on arrival is noise rather than a warning.
        const AstryxBanner(
          status: AstryxBannerStatus.warning,
          title: 'This cannot be undone',
          description:
              'Every connection, every password and key saved in the '
              'keychain, and every setting on this page is deleted. Open tabs '
              'close. Nothing is exported first, and there is no way to get '
              'any of it back — the databases themselves are untouched, but '
              'you will have to set each connection up again from scratch.',
          announce: false,
        ),
        AstryxHStack(
          children: <Widget>[
            AstryxButton(
              label: 'Reset application',
              variant: AstryxButtonVariant.destructive,
              loading: _running,
              onPressed: _confirm.show,
            ),
          ],
        ),
        AstryxAlertDialog(
          controller: _confirm,
          title: 'Erase everything and start over?',
          description:
              'Every connection and every credential Dextr has saved is '
              'deleted from this machine, along with your settings. This '
              'cannot be undone.',
          confirmLabel: 'Erase everything',
          destructive: true,
          onConfirm: _reset,
          child: const AstryxText(
            'Your databases and their contents are not touched — only what '
            'Dextr stored about how to reach them.',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.secondary,
          ),
        ),
      ],
    );
  }
}
