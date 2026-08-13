import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../../connectors/data_source.dart';
import '../../core/capabilities.dart';

/// A Lucide glyph sized and coloured from the tokens.
///
/// Every astryx control that has an icon slot — a button's `leading`, an
/// `AstryxNavIcon`, a menu row's `icon` — wraps that slot in an `IconTheme`
/// carrying the control's own foreground colour and icon size, so a bare `Icon`
/// put there is already right and must stay bare: a primary button's icon is
/// `onAccent`, not `iconPrimary`, and hard-coding either would break one of them.
///
/// This is for the other places — a table cell, the body of a card — where
/// nothing has set an `IconTheme` and Flutter's fallback applies: **black, at
/// 24 pixels**, whatever the colour mode says. Black is invisible on a dark
/// surface, and 24 is half again the size the design system uses.
class DextrIcon extends StatelessWidget {
  const DextrIcon(
    this.icon, {
    super.key,
    this.size = AstryxIconSize.sm,
    this.color = AstryxIconColor.primary,
    this.label,
  });

  final IconData icon;
  final AstryxIconSize size;
  final AstryxIconColor color;

  /// An accessible name. Null — the default — marks the glyph decorative,
  /// which is right whenever the text beside it already says what it means.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = AstryxTheme.of(context);
    final token = color.token;
    final glyph = Icon(
      icon,
      size: size.pixels,
      color: token == null ? IconTheme.of(context).color : theme.color(token),
    );
    return label == null
        ? ExcludeSemantics(child: glyph)
        : Semantics(
            label: label,
            child: ExcludeSemantics(child: glyph),
          );
  }
}

/// The glyphs Dextr needs beyond astryx_ui's own registry.
///
/// `AstryxIconName` covers the 28 semantic names the widget set draws with —
/// chevrons, ticks, a funnel. A database tool also needs a table, a bucket and
/// a plug, so those come straight from Lucide, which is the set astryx_ui's
/// default registry is backed by. Same family, so they sit together.
abstract final class DextrIcons {
  /// The icon standing for a whole connection, by backend.
  static IconData forKind(DataSourceKind kind) => switch (kind) {
    DataSourceKind.sqlite => LucideIcons.fileCode,
    DataSourceKind.postgres => LucideIcons.database,
    DataSourceKind.mysql => LucideIcons.database,
    DataSourceKind.firestore => LucideIcons.sparkles,
    DataSourceKind.mongo => LucideIcons.leaf,
    DataSourceKind.s3 => LucideIcons.cloud,
    DataSourceKind.rest => LucideIcons.plug,
    DataSourceKind.graphql => LucideIcons.braces,
  };

  /// The icon standing for one container inside a connection.
  static IconData forContainer(ContainerRef container) =>
      switch (container.subtype) {
        'bucket' => LucideIcons.folder,
        'view' => LucideIcons.eye,
        'collection' => LucideIcons.listTree,
        _ => LucideIcons.table2,
      };

  /// The icon for one entry in a file browser, from its name.
  static IconData forFile(FileEntry entry) {
    if (entry.isFolder) return LucideIcons.folder;
    final ext = p.extension(entry.name).toLowerCase().replaceFirst('.', '');
    const image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico', 'svg'};
    const archive = {'zip', 'tar', 'gz', 'tgz', 'rar', '7z', 'bz2', 'xz'};
    const code = {
      'dart',
      'js',
      'ts',
      'jsx',
      'tsx',
      'py',
      'java',
      'c',
      'cpp',
      'h',
      'hpp',
      'go',
      'rs',
      'rb',
      'sh',
      'sql',
      'css',
      'html',
      'htm',
      'xml',
    };
    const data = {'json', 'csv', 'tsv', 'yaml', 'yml', 'toml', 'ini', 'env'};
    if (image.contains(ext)) return LucideIcons.image;
    if (archive.contains(ext)) return LucideIcons.fileArchive;
    if (code.contains(ext)) return LucideIcons.fileCode;
    if (data.contains(ext)) return LucideIcons.fileJson;
    if (ext == 'pdf') return LucideIcons.fileText;
    return LucideIcons.file;
  }

  static const bucket = LucideIcons.folder;
  static const columnKey = LucideIcons.key;
  static const column = LucideIcons.columns3;
  static const copy = LucideIcons.copy;
  static const delete = LucideIcons.trash2;
  static const download = LucideIcons.download;
  static const edit = LucideIcons.pencil;
  static const folderPlus = LucideIcons.folderPlus;
  static const insert = LucideIcons.plus;
  static const link = LucideIcons.link;
  static const move = LucideIcons.cornerUpRight;
  static const newConnection = LucideIcons.boxes;
  static const preview = LucideIcons.eye;
  static const refresh = LucideIcons.refreshCw;
  static const run = LucideIcons.play;
  static const settings = LucideIcons.settings;
  static const terminal = LucideIcons.terminal;
  static const unplug = LucideIcons.unplug;
  static const up = LucideIcons.arrowUp;
  static const upload = LucideIcons.upload;

  // The window controls, for the platforms that have no native ones once the
  // title bar is hidden.
  static const windowMinimize = LucideIcons.minus;
  static const windowMaximize = LucideIcons.square;
  static const windowRestore = LucideIcons.copy;
  static const windowClose = LucideIcons.x;
}
