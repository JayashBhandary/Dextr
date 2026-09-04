import 'dart:convert';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';

class BigqueryFormResult {
  const BigqueryFormResult({
    required this.name,
    required this.projectId,
    required this.location,
    required this.maximumBytesBilled,
    this.serviceAccountJson,
  });

  final String name;
  final String projectId;

  /// The region a query and its datasets have to agree on. Empty means let
  /// BigQuery work it out from the tables the query names.
  final String location;

  /// The scan a query is allowed before BigQuery refuses it, in bytes. Zero
  /// means no cap.
  final int maximumBytesBilled;

  final String? serviceAccountJson;
}

class BigqueryForm extends StatefulWidget {
  const BigqueryForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<BigqueryFormResult> onSubmit;
  final VoidCallback onCancel;
  final BigqueryFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(BigqueryFormResult result)? onTest;

  @override
  State<BigqueryForm> createState() => _BigqueryFormState();
}

class _BigqueryFormState extends State<BigqueryForm>
    with ConnectionFormValidation<BigqueryForm> {
  /// One gibibyte, which is where BigQuery's own free tier sits and about a
  /// thousandth of what an accidental full-table scan costs.
  static const _defaultCapBytes = 1 << 30;

  late final TextEditingController _name;
  late final TextEditingController _projectId;
  late final TextEditingController _location;
  late final TextEditingController _serviceAccount;
  late num? _capGiB;
  List<AstryxFile> _picked = const <AstryxFile>[];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My BigQuery');
    _projectId = TextEditingController(text: initial?.projectId ?? '');
    _location = TextEditingController(text: initial?.location ?? '');
    _serviceAccount = TextEditingController(
      text: initial?.serviceAccountJson ?? '',
    );
    final cap = initial?.maximumBytesBilled ?? _defaultCapBytes;
    _capGiB = cap <= 0 ? 0 : cap / (1 << 30);
  }

  @override
  void dispose() {
    _name.dispose();
    _projectId.dispose();
    _location.dispose();
    _serviceAccount.dispose();
    super.dispose();
  }

  Future<List<AstryxFile>> _pickKey(AstryxFilePickRequest request) async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pick the service-account JSON',
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );
    if (file == null) return const <AstryxFile>[];
    final bytes = await file.readAsBytes();
    _serviceAccount.text = utf8.decode(bytes, allowMalformed: true);
    // The project is already in the key file, and it has to match it exactly,
    // so it is read out rather than retyped.
    try {
      final decoded = jsonDecode(_serviceAccount.text);
      if (decoded is Map && decoded['project_id'] is String) {
        _projectId.text = decoded['project_id'] as String;
      }
    } catch (_) {
      // Not JSON, or not a key file. Validation will say so.
    }
    setState(() {});
    return <AstryxFile>[
      AstryxFile(
        name: file.name,
        size: file.size,
        mimeType: 'application/json',
      ),
    ];
  }

  BigqueryFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_serviceAccount.text.trim().isEmpty) {
      return fail('key', 'Pick a service-account JSON key.');
    }
    try {
      final decoded = jsonDecode(_serviceAccount.text);
      if (decoded is! Map || decoded['private_key'] == null) {
        return fail('key', 'That JSON is not a service-account key.');
      }
    } catch (_) {
      return fail('key', 'That file is not valid JSON.');
    }
    if (_projectId.text.trim().isEmpty) {
      return fail('project', 'A Google Cloud project ID is required.');
    }
    clearValidation();
    final gib = _capGiB ?? 0;
    return BigqueryFormResult(
      name: _name.text.trim(),
      projectId: _projectId.text.trim(),
      location: _location.text.trim(),
      maximumBytesBilled: gib <= 0 ? 0 : (gib * (1 << 30)).round(),
      serviceAccountJson: _serviceAccount.text,
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
        AstryxFileInput(
          label: 'Service-account key',
          description:
              'The JSON stays in the OS keychain, not on disk beside the '
              'connection. The role needs BigQuery Data Viewer and BigQuery '
              'Job User.',
          placeholder: 'No key chosen',
          accept: const <String>['.json', 'application/json'],
          status: statusFor('key'),
          required: true,
          files: _picked,
          onPick: _pickKey,
          onChanged: (files) => setState(() {
            _picked = files;
            if (files.isEmpty) _serviceAccount.clear();
          }),
        ),
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Project ID',
              description: 'Filled in from the key. This is the project '
                  'billed for the queries.',
              controller: _projectId,
              status: statusFor('project'),
              required: true,
              placeholder: 'my-project-1234',
            ),
            AstryxTextInput(
              label: 'Location',
              description: 'Left empty, BigQuery infers it from the tables.',
              controller: _location,
              optional: true,
              placeholder: 'EU, or europe-west2',
            ),
          ],
        ),
        AstryxNumberInput(
          label: 'Maximum data scanned per query (GiB)',
          // The one setting on this form that is about money rather than about
          // reaching the server, so it says what it prevents.
          description:
              'BigQuery refuses a query that would scan more than this, '
              'before running any of it. Zero removes the limit.',
          value: _capGiB,
          min: 0,
          max: 1048576,
          onChanged: (value) => setState(() => _capGiB = value),
        ),
        if ((_capGiB ?? 0) <= 0)
          const AstryxBanner(
            status: AstryxBannerStatus.warning,
            title: 'No limit on what a query can scan',
            description:
                'BigQuery bills by the byte scanned, and a mistyped WHERE '
                'clause on a large table scans all of it. With no limit, '
                'nothing here will stop that query before it runs.',
          ),
        const AstryxBanner(
          status: AstryxBannerStatus.info,
          title: 'Browsing a table is free; querying it is not',
          description:
              'Opening a table reads rows straight out of storage, which '
              'BigQuery does not bill as a query. Running SQL in the Query '
              'pane does, and so does sorting or filtering a browse.',
        ),
        const AstryxBanner(
          status: AstryxBannerStatus.info,
          title: 'The grid is read-only here',
          description:
              'BigQuery has no enforced primary key, so no WHERE clause '
              'identifies exactly one row to edit. Use INSERT, UPDATE and '
              'DELETE in the Query pane, where what they match is visible.',
        ),
      ],
    );
  }
}
