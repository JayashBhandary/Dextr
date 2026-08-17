import 'dart:async';
import 'dart:convert';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connectors/data_source.dart';
import '../../connectors/vector/vector_data_source.dart';
import '../../connectors/vector/vector_types.dart';
import '../../state/active_source_provider.dart';
import '../../state/vector_space_provider.dart';
import '../widgets/dextr_icons.dart';
import 'vector_space_view.dart';

/// The vector space of one collection, flattened onto something you can look at.
///
/// A scatter of the collection's leading principal components — three of them
/// by default, turned with the mouse — with the point under the cursor readable
/// beside it. The plot is the point of the pane but not the whole of it: a
/// canvas says nothing to a screen reader and cannot be read at all by anyone
/// who cannot see it, so every point the plot draws is also reachable from the
/// keyboard and reported as text in the panel, which is where the payload has
/// to be read anyway.
///
/// The working question the pane is built around is "where does this document
/// sit, and what is near it": find a point by its text, make it the probe, and
/// its nearest vectors light up around it with a thread to each.
class VectorPane extends ConsumerStatefulWidget {
  const VectorPane({super.key, required this.container});

  final ContainerRef container;

  @override
  ConsumerState<VectorPane> createState() => _VectorPaneState();
}

class _VectorPaneState extends ConsumerState<VectorPane> {
  /// How much of the collection to read. A projection is only as honest as its
  /// sample, and a bigger one costs a longer wait, so the choice is the
  /// reader's rather than a constant.
  int _sample = 1000;

  /// Two axes or three.
  int _components = 3;

  /// Which payload key the marks are coloured by, or null for one colour.
  String? _colourBy;

  int? _selected;

  /// The point a search settled on, and where it sits in the sample — which is
  /// nowhere, when the text search reached past what was plotted.
  VectorPoint? _probe;
  int? _probeIndex;

  List<VectorPoint> _neighbours = const <VectorPoint>[];
  List<VectorPoint> _matches = const <VectorPoint>[];

  /// Null until a text search has run. False means the engine could not search
  /// itself and only the plotted sample was looked at.
  bool? _searchedWholeCollection;

  bool _busy = false;
  String? _error;

  final TextEditingController _text = TextEditingController();
  final TextEditingController _queryVector = TextEditingController();
  final FocusNode _plotFocus = FocusNode(debugLabel: 'vector-plot');

  @override
  void dispose() {
    _text.dispose();
    _queryVector.dispose();
    _plotFocus.dispose();
    super.dispose();
  }

  VectorSpaceKey get _key => (
    container: widget.container.name,
    sample: _sample,
    components: _components,
  );

  void _refresh() {
    setState(_clearSearch);
    ref.invalidate(vectorSpaceProvider(_key));
  }

  void _clearSearch() {
    _selected = null;
    _probe = null;
    _probeIndex = null;
    _neighbours = const <VectorPoint>[];
    _matches = const <VectorPoint>[];
    _searchedWholeCollection = null;
    _error = null;
  }

  VectorSearchable? get _source {
    final source = ref.read(activeDataSourceProvider).value;
    return source is VectorSearchable ? source : null;
  }

  // --- Finding a probe ------------------------------------------------------

  /// Looks for points whose text matches, across the whole collection where the
  /// engine can and across the plotted sample where it cannot.
  Future<void> _searchText(VectorSpace space) async {
    final query = _text.text.trim();
    if (query.isEmpty) {
      setState(() => _error = 'Type something to look for.');
      return;
    }
    final source = _source;
    if (source == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = await source.searchVectorText(
        widget.container,
        query,
        limit: _searchLimit,
      );
      if (!mounted) return;

      // Null means the engine has no text search — not that there was nothing
      // to find. The sample already read is searched instead, and the panel
      // says which happened.
      final matches = found ??
          <VectorPoint>[
            for (final point in space.points)
              if (payloadContains(point, query)) point,
          ].take(_searchLimit).toList();

      setState(() {
        _matches = matches;
        _searchedWholeCollection = found != null;
        _busy = false;
        _error = null;
      });

      // One hit is not a list to choose from, it is the answer.
      if (matches.length == 1) await _useAsProbe(space, matches.single);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  /// Makes [point] the probe and fetches what is near it.
  Future<void> _useAsProbe(VectorSpace space, VectorPoint point) async {
    final source = _source;
    if (source == null) return;

    setState(() {
      _probe = point;
      _probeIndex = _indexOf(space, point.id);
      _selected = _probeIndex ?? _selected;
      _busy = true;
      _error = null;
    });

    try {
      final near = await source.nearestVectors(
        widget.container,
        point.vector,
        topK: 20,
      );
      if (!mounted) return;
      setState(() {
        // The probe is its own nearest neighbour at distance zero, which is
        // true and useless — it is already drawn as the probe.
        _neighbours = <VectorPoint>[
          for (final n in near)
            if (n.id != point.id) n,
        ];
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  /// Runs the box's contents as a query vector.
  ///
  /// Vectors only, never text-as-embedding: embedding a phrase would mean
  /// holding a key for an embedding provider and guessing which model produced
  /// the collection, and a query embedded by the wrong model returns confident
  /// nonsense. The text box above searches literally, which is a different and
  /// honest thing.
  Future<void> _searchTypedVector(VectorSpace space) async {
    final raw = _queryVector.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Paste a vector to search with.');
      return;
    }
    final List<double> parsed;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('not an array');
      parsed = <double>[
        for (final v in decoded)
          if (v is num)
            v.toDouble()
          else
            throw const FormatException('not a number'),
      ];
    } on FormatException {
      setState(
        () => _error =
            'That is not a vector. Paste a JSON array of numbers, like '
            '[0.12, -0.4, 0.9].',
      );
      return;
    }
    if (parsed.isEmpty) {
      setState(() => _error = 'That vector is empty.');
      return;
    }
    final expected = space.info.dimension;
    if (expected != null && parsed.length != expected) {
      setState(
        () => _error =
            'This space is $expected-dimensional; that vector has '
            '${parsed.length} components.',
      );
      return;
    }

    await _useAsProbe(
      space,
      VectorPoint(id: 'pasted vector', vector: parsed),
    );
  }

  int? _indexOf(VectorSpace space, String id) {
    for (var i = 0; i < space.points.length; i++) {
      if (space.points[i].id == id) return i;
    }
    return null;
  }

  Set<int> _indicesOf(VectorSpace space, List<VectorPoint> points) {
    if (points.isEmpty) return const <int>{};
    final wanted = <String>{for (final p in points) p.id};
    final out = <int>{};
    for (var i = 0; i < space.points.length; i++) {
      if (wanted.contains(space.points[i].id)) out.add(i);
    }
    return out;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final space = ref.watch(vectorSpaceProvider(_key));

    // Read by what the state *holds*, not by which subclass it is.
    //
    // A provider that failed and is now being retried is an `AsyncLoading`
    // carrying the previous error, so matching `AsyncLoading()` first showed a
    // spinner over the top of a real failure — for ever, if the retry failed
    // the same way. What matters is whether there is a value to draw and
    // whether there is an error to report, and neither question is answered by
    // the class of the wrapper.
    final value = space.value;
    if (value != null) return _body(value);

    final error = space.error;
    if (error != null) {
      return AstryxCenter(
        child: AstryxBanner(
          status: AstryxBannerStatus.error,
          title: 'Could not read this vector space',
          description: '$error',
        ),
      );
    }

    return _VectorLoading(sample: _sample);
  }

  Widget _body(VectorSpace space) {
    if (space.points.isEmpty) {
      return AstryxCenter(
        child: AstryxEmptyState(
          icon: const Icon(DextrIcons.vectors),
          title: 'Nothing in this collection',
          description:
              '${widget.container.name} exists but holds no vectors yet.',
          actions: <Widget>[
            AstryxButton(
              label: 'Check again',
              variant: AstryxButtonVariant.secondary,
              leading: const Icon(DextrIcons.refresh),
              onPressed: _refresh,
            ),
          ],
        ),
      );
    }

    final colouring = _Colouring.of(space, _colourBy);

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        _toolbar(space),
        Expanded(
          child: AstryxHStack(
            gap: AstryxSpacingToken.spacing3,
            align: AstryxStackAlign.stretch,
            mainAxisSize: MainAxisSize.max,
            children: <Widget>[
              Expanded(child: _plot(space, colouring)),
              SizedBox(width: 360, child: _panel(space, colouring)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(VectorSpace space) {
    final info = space.info;
    final explained = space.projection.explained;

    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        AstryxBadge(
          info.dimension == null ? 'width unknown' : '${info.dimension}-d',
          variant: AstryxBadgeVariant.info,
        ),
        AstryxBadge(info.metric.label),
        AstryxText(
          space.truncated
              ? '${space.points.length} of ${info.count} plotted'
              : '${space.points.length} plotted',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
          tabularNumbers: true,
        ),
        // How much of the space survived being flattened. A projection that
        // kept a tenth of the spread is a picture of very little, and clusters
        // read into it may be artefacts of the flattening rather than structure
        // in the data — so the number is stated rather than left to be assumed.
        // Flexible, and the only thing in the row that is: the controls to its
        // right are all at their minimum useful size, so when the pane narrows
        // this is the sentence that gives way rather than the row overflowing.
        if (explained != null)
          Flexible(
            child: AstryxText(
              '· ${(explained * 100).toStringAsFixed(0)}% of the spread kept'
              '${explained < 0.25 ? ' — read clusters with care' : ''}',
              type: AstryxTextType.supporting,
              color: AstryxTextColor.secondary,
              maxLines: 1,
              truncateTooltip: true,
            ),
          ),
        const Spacer(),
        AstryxSegmentedControl<int>(
          label: 'Axes',
          size: AstryxButtonSize.sm,
          value: _components,
          onChanged: (value) => setState(() => _components = value),
          segments: const <AstryxSegment<int>>[
            AstryxSegment<int>(value: 2, label: '2D'),
            AstryxSegment<int>(value: 3, label: '3D'),
          ],
        ),
        SizedBox(
          width: 132,
          child: AstryxSelector<String?>(
            label: 'Colour by',
            labelHidden: true,
            placeholder: 'Colour by',
            size: AstryxInputSize.sm,
            value: _colourBy,
            options: <AstryxSelectorEntry<String?>>[
              const AstryxSelectorOption<String?>(
                value: null,
                label: 'One colour',
              ),
              for (final key in _colourableKeys(space))
                AstryxSelectorOption<String?>(value: key, label: key),
            ],
            onChanged: (value) => setState(() => _colourBy = value),
          ),
        ),
        SizedBox(
          width: 122,
          child: AstryxSelector<int>(
            label: 'Sample',
            labelHidden: true,
            size: AstryxInputSize.sm,
            value: _sample,
            options: <AstryxSelectorEntry<int>>[
              for (final n in const <int>[250, 1000, 2500, 5000])
                AstryxSelectorOption<int>(value: n, label: '$n points'),
            ],
            onChanged: (value) {
              if (value == null || value == _sample) return;
              setState(() {
                _sample = value;
                _selected = null;
              });
            },
          ),
        ),
        AstryxButton(
          label: 'Refresh',
          variant: AstryxButtonVariant.secondary,
          size: AstryxButtonSize.sm,
          leading: const Icon(DextrIcons.refresh),
          onPressed: _refresh,
        ),
      ],
    );
  }

  /// Payload keys worth colouring by: present on most points, and with few
  /// enough distinct values that a legend is readable. A key with a thousand
  /// values is a thousand colours, which is no colouring at all.
  List<String> _colourableKeys(VectorSpace space) {
    final values = <String, Set<String>>{};
    for (final point in space.points) {
      for (final e in point.payload.entries) {
        final v = e.value;
        if (v == null || v is List || v is Map) continue;
        final seen = values.putIfAbsent(e.key, () => <String>{});
        if (seen.length <= _Colouring.maxCategories + 1) seen.add('$v');
      }
    }
    final keys = <String>[
      for (final e in values.entries)
        if (e.value.length > 1 && e.value.length <= _Colouring.maxCategories)
          e.key,
    ]..sort();
    return keys;
  }

  Widget _plot(VectorSpace space, _Colouring colouring) {
    // Deliberately not an `AstryxCard`: a card shrink-wraps its body, and the
    // plot has to be the size of the space left for it. The card's surface is
    // reproduced from the same tokens instead, so it still looks like one.
    final theme = AstryxTheme.of(context);
    final radius = theme.borderRadius(AstryxRadiusToken.container);
    final selected = _selected;
    final point = selected == null ? null : space.points[selected];

    return DecoratedBox(
      key: const ValueKey('vector-plot'),
      decoration: BoxDecoration(
        color: theme.color(AstryxColorToken.backgroundCard),
        borderRadius: radius,
        border: Border.all(color: theme.color(AstryxColorToken.border)),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: VectorSpaceView(
          projection: space.projection,
          threeD: _components == 3,
          colourFor: (index) => colouring.byIndex[index],
          selected: _selected,
          probe: _probeIndex,
          neighbours: _indicesOf(space, _neighbours),
          matches: _indicesOf(space, _matches),
          focusNode: _plotFocus,
          onSelected: (index) => setState(() => _selected = index),
          semanticsLabel:
              '${space.points.length} vectors, projected onto '
              '${_components == 3 ? 'three' : 'two'} dimensions',
          semanticsValue: point == null
              ? 'Nothing selected'
              : 'Selected ${point.id}',
        ),
      ),
    );
  }

  Widget _panel(VectorSpace space, _Colouring colouring) {
    final selected = _selected;
    final point = selected == null ? null : space.points[selected];

    // `scrollable`, because the payload of one point is any length at all and
    // the panel is a fixed column beside a plot that must not be squeezed.
    return AstryxCard(
      padding: AstryxSpacingToken.spacing4,
      scrollable: true,
      child: AstryxVStack(
        gap: AstryxSpacingToken.spacing4,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          _textSearch(space),
          if (_error != null)
            AstryxBanner(
              status: AstryxBannerStatus.error,
              title: 'That did not run',
              description: _error!,
            ),
          if (_matches.isNotEmpty || _searchedWholeCollection != null)
            _matchList(space),
          if (_probe != null) ...<Widget>[
            const AstryxDivider(),
            _probeDetails(space),
          ],
          if (_neighbours.isNotEmpty) _neighbourList(space),
          const AstryxDivider(),
          if (colouring.hasCategories) _legend(colouring),
          _selection(point),
          const AstryxDivider(),
          _vectorSearch(space),
        ],
      ),
    );
  }

  Widget _textSearch(VectorSpace space) => AstryxVStack(
    gap: AstryxSpacingToken.spacing2,
    align: AstryxStackAlign.stretch,
    children: <Widget>[
      AstryxTextInput(
        label: 'Find a point by its text',
        description:
            'Matches the document and metadata literally — not a semantic '
            'search. Pick a result to make it the probe.',
        controller: _text,
        placeholder: 'invoice, subject line, filename…',
        onSubmitted: (_) => _searchText(space),
      ),
      AstryxButton(
        label: 'Search text',
        variant: AstryxButtonVariant.primary,
        size: AstryxButtonSize.sm,
        leading: const Icon(DextrIcons.search),
        loading: _busy,
        onPressed: () => _searchText(space),
      ),
    ],
  );

  /// How many hits a text search asks for. A list to choose a probe from, not
  /// a result set to page through.
  static const int _searchLimit = 50;

  /// What the search found, said in a way that does not overstate it.
  ///
  /// A capped search knows it found *at least* the cap — reporting "50 matched"
  /// when 50 was the limit would read as a total, and someone would conclude
  /// their collection holds fifty matching documents when it holds hundreds.
  String _matchSummary(VectorSpace space, bool whole) {
    final where = whole
        ? 'this collection'
        : 'the ${space.points.length} plotted points';
    if (_matches.isEmpty) {
      return whole
          ? 'Nothing in this collection matched'
          : 'Nothing in the ${space.points.length} plotted points matched';
    }
    if (_matches.length >= _searchLimit) {
      return 'The first $_searchLimit matches in $where — narrow the search to '
          'see fewer';
    }
    return '${_matches.length} matched'
        '${whole ? '' : ' in the plotted sample'}';
  }

  Widget _matchList(VectorSpace space) {
    final whole = _searchedWholeCollection ?? true;
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxText(
          _matchSummary(space, whole),
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
        // The scope of the search is stated whenever it was not the whole
        // collection: "no matches here" and "no matches anywhere" are different
        // answers, and only one of them means the document is not there.
        if (!whole)
          const AstryxText(
            'This engine has no text search of its own, so only the points '
            'already read were looked at. A larger sample looks further.',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.secondary,
          ),
        for (final match in _matches.take(12))
          _MatchRow(
            point: match,
            plotted: _indexOf(space, match.id) != null,
            isProbe: match.id == _probe?.id,
            onPressed: () => _useAsProbe(space, match),
          ),
        if (_matches.length > 12)
          AstryxText(
            'and ${_matches.length - 12} more',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.disabled,
          ),
      ],
    );
  }

  Widget _probeDetails(VectorSpace space) {
    final probe = _probe!;
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxHStack(
          gap: AstryxSpacingToken.spacing2,
          children: <Widget>[
            const AstryxBadge('probe', variant: AstryxBadgeVariant.warning),
            Flexible(
              child: AstryxText(
                probe.id,
                type: AstryxTextType.code,
                maxLines: 1,
                truncateTooltip: true,
              ),
            ),
          ],
        ),
        // A probe found by searching the whole collection may be a point that
        // was never plotted. Saying so is the difference between "I cannot see
        // it" and "it is not there".
        if (_probeIndex == null)
          const AstryxText(
            'Outside the plotted sample, so it has no mark of its own — its '
            'neighbours below are still highlighted where they were plotted.',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.secondary,
          ),
        if (probe.payload[chromaDocumentKey] case final Object document)
          AstryxText(
            '$document',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.secondary,
            maxLines: 4,
          ),
      ],
    );
  }

  Widget _neighbourList(VectorSpace space) {
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxText(
          '${_neighbours.length} closest to the probe',
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
        for (final neighbour in _neighbours)
          _NeighbourRow(
            point: neighbour,
            metric: space.info.metric,
            // A neighbour outside the sample cannot be highlighted in the plot,
            // because it was never plotted. Selecting it would move the
            // selection to nothing.
            onSelect: _indexOf(space, neighbour.id) == null
                ? null
                : () => setState(
                    () => _selected = _indexOf(space, neighbour.id),
                  ),
          ),
      ],
    );
  }

  Widget _legend(_Colouring colouring) => AstryxVStack(
    gap: AstryxSpacingToken.spacing2,
    align: AstryxStackAlign.stretch,
    children: <Widget>[
      AstryxText(
        colouring.key!,
        type: AstryxTextType.supporting,
        color: AstryxTextColor.secondary,
      ),
      for (final entry in colouring.categories.entries)
        AstryxHStack(
          gap: AstryxSpacingToken.spacing2,
          children: <Widget>[
            // The swatch is never the whole message: the value is written
            // beside it, so the legend reads the same to someone who cannot
            // tell two of these colours apart.
            _Swatch(token: colouring.tokenFor(entry.value)),
            Flexible(
              child: AstryxText(
                entry.key,
                type: AstryxTextType.code,
                maxLines: 1,
                truncateTooltip: true,
              ),
            ),
          ],
        ),
    ],
  );

  Widget _selection(VectorPoint? point) {
    if (point == null) {
      return const AstryxVStack(
        gap: AstryxSpacingToken.spacing2,
        align: AstryxStackAlign.stretch,
        children: <Widget>[
          AstryxText('No point selected'),
          AstryxText(
            'Click a mark, or focus the plot and use the arrow keys.',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.secondary,
          ),
        ],
      );
    }

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing3,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxText(point.id, type: AstryxTextType.code, maxLines: 2),
        AstryxText(
          previewVector(point.vector, components: 6),
          type: AstryxTextType.code,
          color: AstryxTextColor.secondary,
          maxLines: 2,
        ),
        AstryxButton(
          label: 'Make this the probe',
          variant: AstryxButtonVariant.secondary,
          size: AstryxButtonSize.sm,
          leading: const Icon(DextrIcons.target),
          loading: _busy,
          onPressed: () {
            final space = ref.read(vectorSpaceProvider(_key)).value;
            if (space != null) _useAsProbe(space, point);
          },
        ),
        if (point.payload.isNotEmpty)
          AstryxMetadataList(
            items: <AstryxMetadataItem>[
              for (final e in point.payload.entries)
                AstryxMetadataItem.text(
                  label: e.key,
                  value: _displayValue(e.value),
                ),
            ],
          ),
      ],
    );
  }

  Widget _vectorSearch(VectorSpace space) => AstryxCollapsible(
    title: 'Search by raw vector',
    child: AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxTextInput.multiline(
          label: 'Query vector',
          labelHidden: true,
          description:
              'A JSON array of ${space.info.dimension ?? 'the right number of'} '
              'numbers.',
          controller: _queryVector,
          placeholder: '[0.12, -0.4, 0.9, …]',
          minLines: 2,
          maxLines: 4,
        ),
        AstryxButton(
          label: 'Search',
          variant: AstryxButtonVariant.secondary,
          size: AstryxButtonSize.sm,
          leading: const Icon(DextrIcons.run),
          loading: _busy,
          onPressed: () => _searchTypedVector(space),
        ),
      ],
    ),
  );

  String _displayValue(Object? value) => switch (value) {
    null => '—',
    String s => s.length <= 400 ? s : '${s.substring(0, 400)}…',
    List() || Map() => jsonEncode(value),
    _ => '$value',
  };
}

/// One text-search hit, offered as a probe.
class _MatchRow extends StatelessWidget {
  const _MatchRow({
    required this.point,
    required this.plotted,
    required this.isProbe,
    required this.onPressed,
  });

  final VectorPoint point;
  final bool plotted;
  final bool isProbe;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final document = point.payload[chromaDocumentKey];
    return AstryxVStack(
      gap: AstryxSpacingToken.spacing0_5,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxHStack(
          gap: AstryxSpacingToken.spacing2,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            Expanded(
              child: AstryxLink(
                point.id,
                type: AstryxTextType.code,
                onPressed: onPressed,
              ),
            ),
            if (isProbe)
              const AstryxBadge('probe', variant: AstryxBadgeVariant.warning)
            else if (!plotted)
              const AstryxBadge('not plotted'),
          ],
        ),
        if (document != null)
          AstryxText(
            '$document',
            type: AstryxTextType.supporting,
            color: AstryxTextColor.secondary,
            maxLines: 2,
          ),
      ],
    );
  }
}

/// The wait before a vector space appears, with some idea of what it is doing.
///
/// Reading a thousand embeddings is megabytes over the wire and the projection
/// that follows is real arithmetic, so this is a wait that can legitimately run
/// to several seconds. A bare spinner makes "slow" and "hung" look identical —
/// naming the stage and showing the clock is the difference between waiting and
/// wondering.
class _VectorLoading extends StatefulWidget {
  const _VectorLoading({required this.sample});

  final int sample;

  @override
  State<_VectorLoading> createState() => _VectorLoadingState();
}

class _VectorLoadingState extends State<_VectorLoading> {
  late final Stopwatch _elapsed = Stopwatch()..start();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _elapsed.elapsed.inSeconds;

    return AstryxCenter(
      child: AstryxVStack(
        gap: AstryxSpacingToken.spacing3,
        align: AstryxStackAlign.center,
        children: <Widget>[
          AstryxSpinner(
            label: seconds < 3
                ? 'Reading the vectors'
                : 'Reading up to ${widget.sample} vectors, then projecting them',
          ),
          if (seconds >= 3)
            AstryxText(
              '${seconds}s so far',
              type: AstryxTextType.supporting,
              color: AstryxTextColor.secondary,
              tabularNumbers: true,
            ),
          // Past this it is worth saying what to do about it, rather than
          // leaving someone to guess whether it is ever going to finish.
          if (seconds >= 15)
            const AstryxText(
              'Still going. A large collection over a slow link takes a while; '
              'a smaller sample will open sooner.',
              type: AstryxTextType.supporting,
              color: AstryxTextColor.secondary,
              justify: AstryxTextJustify.center,
            ),
        ],
      ),
    );
  }
}

/// One neighbour, with its distance.
class _NeighbourRow extends StatelessWidget {
  const _NeighbourRow({
    required this.point,
    required this.metric,
    this.onSelect,
  });

  final VectorPoint point;
  final VectorMetric metric;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final score = point.score;
    return AstryxHStack(
      gap: AstryxSpacingToken.spacing2,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        Expanded(
          child: onSelect == null
              ? AstryxText(
                  point.id,
                  type: AstryxTextType.code,
                  maxLines: 1,
                  truncateTooltip: true,
                )
              : AstryxLink(
                  point.id,
                  type: AstryxTextType.code,
                  onPressed: onSelect,
                ),
        ),
        if (score != null)
          AstryxText(
            score.toStringAsFixed(4),
            type: AstryxTextType.code,
            color: AstryxTextColor.secondary,
            tabularNumbers: true,
            semanticsLabel:
                '${metric.higherIsCloser ? 'similarity' : 'distance'} '
                '${score.toStringAsFixed(4)}',
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.token});

  final AstryxColorToken token;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: AstryxTheme.of(context).color(token),
      shape: BoxShape.circle,
    ),
  );
}

/// How the marks are coloured: by a payload key, or not at all.
class _Colouring {
  const _Colouring._({
    this.key,
    required this.categories,
    required this.byIndex,
  });

  /// Eight is what the palette has distinct hues for, and about as many as a
  /// legend can be scanned at a glance.
  static const int maxCategories = 8;

  /// Which key the colours mean, or null for one colour throughout.
  final String? key;

  /// Value → palette slot, in first-seen order.
  final Map<String, int> categories;

  /// Point index → palette slot, or -1 for "no value for this key".
  final List<int> byIndex;

  bool get hasCategories => key != null && categories.isNotEmpty;

  AstryxColorToken tokenFor(int slot) =>
      spacePalette[slot % spacePalette.length];

  static _Colouring of(VectorSpace space, String? key) {
    if (key == null) {
      return _Colouring._(
        key: null,
        categories: const <String, int>{},
        byIndex: List<int>.filled(space.points.length, -1),
      );
    }
    final categories = <String, int>{};
    final byIndex = List<int>.filled(space.points.length, -1);
    for (var i = 0; i < space.points.length; i++) {
      final value = space.points[i].payload[key];
      if (value == null || value is List || value is Map) continue;
      final label = '$value';
      final slot = categories.putIfAbsent(label, () => categories.length);
      if (slot >= maxCategories) continue;
      byIndex[i] = slot;
    }
    categories.removeWhere((_, slot) => slot >= maxCategories);
    return _Colouring._(key: key, categories: categories, byIndex: byIndex);
  }
}
