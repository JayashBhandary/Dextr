import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../../connectors/vector/vector_types.dart';
import '../../../core/hosts.dart';
import '../../../services/file_access.dart';
import 'connection_form_shell.dart';

class VectorFormResult {
  const VectorFormResult({
    required this.name,
    required this.provider,
    required this.mode,
    required this.url,
    this.apiKey,
    this.tenant,
    this.database,
    this.namespace,
    this.directoryPath,
    this.bookmark,
  });

  final String name;
  final VectorProvider provider;
  final VectorMode mode;

  /// Base URL for a server, or the control plane for Pinecone. Empty in file
  /// mode, where there is nothing to reach.
  final String url;

  final String? apiKey;

  /// Chroma's multi-tenancy, empty for the defaults.
  final String? tenant;
  final String? database;

  /// Pinecone's namespace within an index, empty for the default one.
  final String? namespace;

  /// The Chroma persist directory, in file mode.
  final String? directoryPath;

  /// Sandbox permission to reopen [directoryPath] on a later launch, where the
  /// platform requires one.
  final String? bookmark;
}

/// One form for four engines and three ways of reaching them.
///
/// The two choices at the top decide what the rest of the form is: Pinecone has
/// no local mode and no URL worth typing, Chroma has tenants and a persist
/// directory, and only a cloud endpoint has a credential to ask for. Rather
/// than four forms that share a name field, the fields that do not apply are
/// simply absent, and the mode segments that do not apply are disabled with the
/// reason on them.
class VectorForm extends StatefulWidget {
  const VectorForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<VectorFormResult> onSubmit;
  final VoidCallback onCancel;
  final VectorFormResult? initial;

  final Future<void> Function(VectorFormResult result)? onTest;

  @override
  State<VectorForm> createState() => _VectorFormState();
}

class _VectorFormState extends State<VectorForm>
    with ConnectionFormValidation<VectorForm> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _apiKey;
  late final TextEditingController _tenant;
  late final TextEditingController _database;
  late final TextEditingController _namespace;
  late final TextEditingController _directory;

  late VectorProvider _provider;
  late VectorMode _mode;
  String? _bookmark;
  List<AstryxFile> _picked = const <AstryxFile>[];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _provider = initial?.provider ?? VectorProvider.qdrant;
    _mode = initial?.mode ?? VectorMode.local;
    // A record whose mode its provider does not support can only exist by hand
    // editing, and leaving the form on it would offer a Save that cannot work.
    if (!_provider.modes.contains(_mode)) _mode = _provider.modes.first;

    _name = TextEditingController(
      text: initial?.name ?? 'My ${_provider.label}',
    );
    _url = TextEditingController(text: initial?.url ?? _provider.defaultLocalUrl);
    _apiKey = TextEditingController(text: initial?.apiKey ?? '');
    _tenant = TextEditingController(text: initial?.tenant ?? '');
    _database = TextEditingController(text: initial?.database ?? '');
    _namespace = TextEditingController(text: initial?.namespace ?? '');
    _directory = TextEditingController(text: initial?.directoryPath ?? '');
    _bookmark = initial?.bookmark;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _apiKey.dispose();
    _tenant.dispose();
    _database.dispose();
    _namespace.dispose();
    _directory.dispose();
    super.dispose();
  }

  /// Whether the name is still the one this form chose, and so safe to move to
  /// match a new provider. A name the reader typed is theirs and stays put.
  bool get _nameIsDefault => VectorProvider.values.any(
    (p) => _name.text.trim() == 'My ${p.label}',
  );

  void _setProvider(VectorProvider provider) {
    setState(() {
      clearValidation();
      final urlWasDefault = _url.text.trim() == _provider.defaultLocalUrl;
      if (_nameIsDefault) _name.text = 'My ${provider.label}';
      _provider = provider;
      if (!provider.modes.contains(_mode)) _mode = provider.modes.first;
      if (urlWasDefault || _url.text.trim().isEmpty) {
        _url.text = provider.defaultLocalUrl;
      }
    });
  }

  Future<List<AstryxFile>> _pickDirectory(AstryxFilePickRequest request) async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Pick the Chroma persist directory',
    );
    if (path == null || path.isEmpty) return const <AstryxFile>[];
    _directory.text = path;
    // Minted while the picker's grant is still live — it cannot be minted later
    // from the path alone.
    _bookmark = await FileAccess.instance.bookmark(path);
    setState(() {});
    return <AstryxFile>[AstryxFile(name: p.basename(path), handle: path)];
  }

  // --- Validation -----------------------------------------------------------

  VectorFormResult? _validate() {
    final name = _name.text.trim();
    if (name.isEmpty) return fail('name', 'Give this connection a name.');

    if (_mode == VectorMode.file) {
      final directory = _directory.text.trim();
      if (directory.isEmpty) {
        return fail('directory', 'Pick the persist directory to open.');
      }
      return VectorFormResult(
        name: name,
        provider: _provider,
        mode: _mode,
        url: '',
        directoryPath: directory,
        bookmark: _bookmark,
      );
    }

    final url = _url.text.trim();
    if (url.isEmpty) return fail('url', 'A URL is required.');
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return fail(
        'url',
        'That is not a URL. Include the scheme, like '
            'https://example.com:6333.',
      );
    }
    if (parsed.scheme != 'http' && parsed.scheme != 'https') {
      return fail('url', 'Only http and https are supported.');
    }
    // A credential sent over plain HTTP to a host across a network the reader
    // does not control is the credential leaked, and it is not recoverable by
    // rotating a key they will not know to rotate.
    final key = _apiKey.text.trim();
    if (parsed.scheme == 'http' &&
        key.isNotEmpty &&
        !isLocalOrPrivateHost(parsed.host)) {
      return fail(
        'url',
        'This would send the ${_provider.credentialLabel.toLowerCase()} in '
            'the clear to a host outside this network. Use https.',
      );
    }
    if (_provider.requiresCredential && key.isEmpty) {
      return fail('key', '${_provider.label} cannot be reached without one.');
    }

    clearValidation();
    return VectorFormResult(
      name: name,
      provider: _provider,
      mode: _mode,
      url: url,
      apiKey: key.isEmpty ? null : key,
      tenant: _tenant.text.trim(),
      database: _database.text.trim(),
      namespace: _namespace.text.trim(),
    );
  }

  void _submit() {
    final result = _validate();
    if (result != null) widget.onSubmit(result);
  }

  Future<void>? _runTest() {
    final result = _validate();
    if (result == null) return null;
    return widget.onTest!(result);
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ConnectionFormShell(
      nameController: _name,
      nameStatus: statusFor('name'),
      formError: formError,
      onSave: _submit,
      onCancel: widget.onCancel,
      onTest: widget.onTest == null ? null : _runTest,
      children: <Widget>[
        AstryxSelector<VectorProvider>(
          label: 'Engine',
          description: 'Which vector database this connection talks to.',
          value: _provider,
          required: true,
          options: <AstryxSelectorEntry<VectorProvider>>[
            for (final provider in VectorProvider.values)
              AstryxSelectorOption<VectorProvider>(
                value: provider,
                label: provider.label,
                description: provider.blurb,
              ),
          ],
          onChanged: (value) {
            if (value != null) _setProvider(value);
          },
        ),
        AstryxSegmentedControl<VectorMode>(
          label: 'Where it lives',
          value: _mode,
          onChanged: (mode) => setState(() {
            clearValidation();
            _mode = mode;
          }),
          segments: <AstryxSegment<VectorMode>>[
            for (final mode in VectorMode.values)
              AstryxSegment<VectorMode>(
                value: mode,
                label: mode.label,
                // Disabled rather than absent, so the reader can see that the
                // engine they picked is the reason a mode is unavailable
                // instead of wondering where it went.
                enabled: _provider.modes.contains(mode),
              ),
          ],
        ),
        AstryxText(
          _modeExplanation,
          type: AstryxTextType.supporting,
          color: AstryxTextColor.secondary,
        ),
        ..._modeFields(),
      ],
    );
  }

  /// What the chosen mode means for the chosen engine, including why a mode is
  /// missing when one is.
  String get _modeExplanation {
    if (!_provider.modes.contains(VectorMode.file)) {
      final why = _provider == VectorProvider.pinecone
          ? '${_provider.label} is hosted only, so it has no local server and '
                'no on-disk store to open.'
          : '${_provider.label} keeps its vectors in an engine-internal store '
                '(RocksDB, LSM segments) that cannot be read without the '
                'engine running, so File is not offered for it.';
      return '${_mode.blurb} $why';
    }
    if (_mode == VectorMode.file) {
      return 'The persist directory holding chroma.sqlite3, opened read-only. '
          'Vectors come from the hnsw index beside it.';
    }
    return _mode.blurb;
  }

  List<Widget> _modeFields() {
    if (_mode == VectorMode.file) {
      return <Widget>[
        AstryxFileInput(
          label: 'Persist directory',
          description: 'Opened in place, read-only. Nothing is copied.',
          placeholder: 'No directory chosen',
          status: statusFor('directory'),
          required: true,
          files: _picked,
          onPick: _pickDirectory,
          onChanged: (files) => setState(() {
            _picked = files;
            if (files.isEmpty) {
              _directory.clear();
              _bookmark = null;
            }
          }),
        ),
        // Shown, not editable: the picker is what sets it, and a path typed by
        // hand that does not exist fails later with a worse message.
        AstryxTextInput(
          label: 'Path',
          controller: _directory,
          readOnly: true,
          labelHidden: true,
          placeholder: 'No directory picked yet',
        ),
      ];
    }

    return <Widget>[
      AstryxTextInput(
        label: _provider == VectorProvider.pinecone ? 'Control plane' : 'URL',
        description: _provider == VectorProvider.pinecone
            ? 'Where indexes are listed. The per-index hosts are looked up '
                  'from here.'
            : 'Scheme, host and port — the address the engine serves on.',
        controller: _url,
        status: statusFor('url'),
        required: true,
        placeholder: _provider.defaultLocalUrl,
      ),
      AstryxTextInput(
        label: _provider.credentialLabel,
        description: _mode == VectorMode.local
            ? 'Only if this instance was started with authentication on.'
            : 'Kept in the OS keychain, not beside the connection.',
        controller: _apiKey,
        status: statusFor('key'),
        obscureText: true,
        required: _provider.requiresCredential,
        optional: !_provider.requiresCredential,
      ),
      if (_provider == VectorProvider.chroma)
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Tenant',
              controller: _tenant,
              placeholder: 'default_tenant',
              optional: true,
            ),
            AstryxTextInput(
              label: 'Database',
              controller: _database,
              placeholder: 'default_database',
              optional: true,
            ),
          ],
        ),
      if (_provider == VectorProvider.pinecone)
        AstryxTextInput(
          label: 'Namespace',
          description: 'Leave empty for the default namespace.',
          controller: _namespace,
          optional: true,
        ),
    ];
  }
}
