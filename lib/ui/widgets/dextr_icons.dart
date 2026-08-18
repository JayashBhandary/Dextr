import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../connectors/data_source.dart';
import '../../core/capabilities.dart';
import '../../core/files/file_kind.dart';

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
    DataSourceKind.vector => LucideIcons.chartScatter,
  };

  /// The icon standing for one container inside a connection.
  static IconData forContainer(ContainerRef container) =>
      switch (container.subtype) {
        'bucket' => LucideIcons.folder,
        'view' => LucideIcons.eye,
        'collection' => LucideIcons.listTree,
        _ => LucideIcons.table2,
      };

  /// The icon for one entry in a file browser.
  ///
  /// Driven by [FileKind], which is the one place that decides what a file *is*.
  /// This used to carry three extension tables of its own, so a format could be
  /// previewable and still draw a blank page — or draw a document icon and have
  /// no preview.
  static IconData forFile(FileEntry entry) {
    if (entry.isFolder) return LucideIcons.folder;
    return switch (FileKind.of(entry)) {
      FileKind.image => LucideIcons.image,
      FileKind.delimited => LucideIcons.fileSpreadsheet,
      FileKind.spreadsheet => LucideIcons.fileSpreadsheet,
      FileKind.document => LucideIcons.fileText,
      FileKind.pdf => LucideIcons.fileText,
      FileKind.video => LucideIcons.fileVideo,
      FileKind.audio => LucideIcons.fileAudio,
      FileKind.archive => LucideIcons.fileArchive,
      // Text splits again by what the text is, because "a file of words" and "a
      // file of code" are different things to someone scanning a bucket.
      FileKind.text =>
        _codeExtensions.contains(FileKind.extensionOf(entry.name))
            ? LucideIcons.fileCode
            : _dataExtensions.contains(FileKind.extensionOf(entry.name))
            ? LucideIcons.fileJson
            : LucideIcons.fileText,
      FileKind.binary => LucideIcons.file,
    };
  }

  static const _codeExtensions = <String>{
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

  static const _dataExtensions = <String>{
    'json',
    'jsonl',
    'yaml',
    'yml',
    'toml',
    'ini',
    'env',
  };

  static const alert = LucideIcons.circleAlert;
  static const bucket = LucideIcons.folder;
  static const columnKey = LucideIcons.key;
  static const column = LucideIcons.columns3;
  static const copy = LucideIcons.copy;
  static const delete = LucideIcons.trash2;
  static const docs = LucideIcons.bookOpen;
  static const download = LucideIcons.download;
  static const edit = LucideIcons.pencil;
  static const export = LucideIcons.fileOutput;
  static const folderPlus = LucideIcons.folderPlus;
  static const info = LucideIcons.info;
  static const insert = LucideIcons.plus;
  static const link = LucideIcons.link;
  static const move = LucideIcons.cornerUpRight;
  static const newConnection = LucideIcons.boxes;
  static const preview = LucideIcons.eye;
  static const refresh = LucideIcons.refreshCw;
  static const run = LucideIcons.play;
  static const search = LucideIcons.search;
  static const settings = LucideIcons.settings;
  static const target = LucideIcons.crosshair;
  static const terminal = LucideIcons.terminal;
  static const vectors = LucideIcons.chartScatter;
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
