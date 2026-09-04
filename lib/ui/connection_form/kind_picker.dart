import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../connectors/registry.dart';
import '../../core/capabilities.dart';
import '../widgets/dextr_icons.dart';

/// Which backend a new connection talks to.
///
/// Selectable cards rather than a radio list: each option carries an icon and a
/// line about what it is, which is more than a radio row holds. Each card is its
/// own tab stop — the cost of the extra content.
class KindPicker extends StatelessWidget {
  const KindPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final DataSourceKind selected;
  final ValueChanged<DataSourceKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final registry = ConnectorRegistry.instance;

    return AstryxGrid(
      minWidth: 210,
      gap: AstryxSpacingToken.spacing3,
      children: <Widget>[
        for (final kind in DataSourceKind.values)
          AstryxSelectableCard(
            label: kind.label,
            semanticsHint: registry.isSupported(kind)
                ? _describe(kind)
                : '${_describe(kind)}. Not available in this build.',
            control: AstryxSelectableCardControl.radio,
            padding: AstryxSpacingToken.spacing3,
            // Room for a title and the two lines the longest description wraps
            // to. Without a floor, a card with a one-line description paints a
            // shorter box than its neighbours and centres its content inside
            // the row's height, dropping its icon half a line below theirs.
            minHeight: 88,
            selected: kind == selected,
            enabled: registry.isSupported(kind),
            onSelectedChanged: (_) => onChanged(kind),
            child: AstryxHStack(
              gap: AstryxSpacingToken.spacing3,
              // Aligned to the top, not centred: a card whose description wraps
              // to two lines is taller than one whose does not, and centring
              // drops its icon half a line below its neighbours' across the
              // grid.
              align: AstryxStackAlign.start,
              children: <Widget>[
                DextrIcon(DextrIcons.forKind(kind), size: AstryxIconSize.md),
                Flexible(
                  child: AstryxVStack(
                    gap: AstryxSpacingToken.spacing0_5,
                    children: <Widget>[
                      AstryxText(kind.label, maxLines: 1),
                      AstryxText(
                        _describe(kind),
                        type: AstryxTextType.supporting,
                        color: AstryxTextColor.secondary,
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _describe(DataSourceKind kind) => switch (kind) {
    DataSourceKind.sqlite => 'A single file on this machine',
    DataSourceKind.postgres => 'Server, schemas, SQL',
    DataSourceKind.mysql => 'Server, databases, SQL',
    DataSourceKind.redshift => 'A cluster, over the Postgres protocol',
    DataSourceKind.snowflake => 'Warehouses and databases, over REST',
    DataSourceKind.bigquery => 'Datasets and tables, billed by the byte',
    DataSourceKind.firestore => 'Collections over the REST API',
    DataSourceKind.mongo => 'Collections and documents',
    DataSourceKind.redis => 'Keys, with their types and TTLs',
    DataSourceKind.s3 => 'Buckets and objects',
    DataSourceKind.rest => 'Saved HTTP calls',
    DataSourceKind.graphql => 'Saved queries against one endpoint',
    DataSourceKind.vector => 'Embeddings, plotted as a space',
  };
}
