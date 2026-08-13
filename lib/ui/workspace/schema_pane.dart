import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connectors/data_source.dart';
import '../../state/schema_provider.dart';
import '../../state/settings_provider.dart';
import '../widgets/dextr_icons.dart';

/// The columns of one container, as a table of its own.
///
/// A table rather than a list: these are records with four fields each, and the
/// question being asked of them — which column is nullable, which one is the key
/// — is answered by reading down a column, which is what a table is for.
class SchemaPane extends ConsumerWidget {
  const SchemaPane({super.key, required this.container});

  final ContainerRef container;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = ref.watch(containerSchemaProvider(container));
    final density = ref.watch(settingsProvider).density;

    return switch (schema) {
      AsyncLoading() => const AstryxCenter(
        child: AstryxSpinner(label: 'Reading the schema'),
      ),
      AsyncError(:final error) => AstryxCenter(
        child: AstryxBanner(
          status: AstryxBannerStatus.error,
          title: 'Could not read the schema',
          description: '$error',
        ),
      ),
      AsyncData(:final value) => AstryxVStack(
        gap: AstryxSpacingToken.spacing3,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          AstryxHStack(
            gap: AstryxSpacingToken.spacing2,
            mainAxisSize: MainAxisSize.max,
            children: <Widget>[
              AstryxText(
                value.columns.length == 1
                    ? '1 column'
                    : '${value.columns.length} columns',
                type: AstryxTextType.supporting,
                color: AstryxTextColor.secondary,
                tabularNumbers: true,
              ),
              if (value.pkColumns.isNotEmpty) ...<Widget>[
                const Spacer(),
                AstryxBadge(
                  'key: ${value.pkColumns.join(', ')}',
                  variant: AstryxBadgeVariant.info,
                ),
              ],
            ],
          ),
          Expanded(child: _columnTable(value, density)),
        ],
      ),
    };
  }

  Widget _columnTable(ContainerSchema schema, AstryxTableDensity density) {
    return AstryxTable<ColumnSchema>(
      label: 'Columns of ${container.qualified}',
      rows: schema.columns,
      density: density,
      keyOf: (column) => column.name,
      rowLabelOf: (column) => column.name,
      emptyState: const AstryxEmptyState(
        title: 'No columns',
        description: 'The source reported no columns for this object.',
        size: AstryxEmptyStateSize.compact,
      ),
      columns: <AstryxTableColumn<ColumnSchema>>[
        AstryxTableColumn<ColumnSchema>(
          id: 'name',
          header: 'Column',
          width: const AstryxTableColumnWidth.flex(1.4),
          compare: (a, b) => a.name.compareTo(b.name),
          cellBuilder: (context, column) => AstryxHStack(
            gap: AstryxSpacingToken.spacing2,
            children: <Widget>[
              // The key is marked with a glyph and repeated in the accessible
              // name, so it is not carried by an icon alone.
              if (column.isPrimaryKey)
                const DextrIcon(
                  DextrIcons.columnKey,
                  size: AstryxIconSize.xsm,
                  color: AstryxIconColor.accent,
                )
              else
                const DextrIcon(
                  DextrIcons.column,
                  size: AstryxIconSize.xsm,
                  color: AstryxIconColor.secondary,
                ),
              Flexible(
                child: AstryxText(
                  column.name,
                  type: AstryxTextType.code,
                  maxLines: 1,
                  semanticsLabel: column.isPrimaryKey
                      ? '${column.name}, primary key'
                      : column.name,
                ),
              ),
            ],
          ),
        ),
        AstryxTableColumn<ColumnSchema>(
          id: 'type',
          header: 'Type',
          compare: (a, b) => a.typeLabel.compareTo(b.typeLabel),
          cellBuilder: (context, column) => AstryxText(
            column.typeLabel,
            type: AstryxTextType.code,
            color: AstryxTextColor.secondary,
            maxLines: 1,
          ),
        ),
        AstryxTableColumn<ColumnSchema>(
          id: 'nullable',
          header: 'Nullable',
          width: const AstryxTableColumnWidth.fixed(110),
          cellBuilder: (context, column) => AstryxBadge(
            column.nullable ? 'NULL' : 'NOT NULL',
            variant: column.nullable
                ? AstryxBadgeVariant.neutral
                : AstryxBadgeVariant.info,
          ),
        ),
        AstryxTableColumn<ColumnSchema>(
          id: 'default',
          header: 'Default',
          cellBuilder: (context, column) => column.defaultExpr == null
              ? const AstryxText(
                  '—',
                  color: AstryxTextColor.disabled,
                  semanticsLabel: 'none',
                )
              : AstryxText(
                  column.defaultExpr!,
                  type: AstryxTextType.code,
                  maxLines: 1,
                ),
        ),
      ],
    );
  }
}
