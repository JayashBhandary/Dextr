import 'dart:convert';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';

class FirestoreFormResult {
  const FirestoreFormResult({
    required this.name,
    required this.projectId,
    required this.databaseId,
    required this.mode,
    this.emulatorHost,
    this.serviceAccountJson,
  });

  final String name;
  final String projectId;
  final String databaseId;
  final String mode; // serviceAccount | emulator
  final String? emulatorHost;
  final String? serviceAccountJson;
}

class FirestoreForm extends StatefulWidget {
  const FirestoreForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<FirestoreFormResult> onSubmit;
  final VoidCallback onCancel;
  final FirestoreFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(FirestoreFormResult result)? onTest;

  @override
  State<FirestoreForm> createState() => _FirestoreFormState();
}

enum _Mode { serviceAccount, emulator }

class _FirestoreFormState extends State<FirestoreForm>
    with ConnectionFormValidation<FirestoreForm> {
  late final TextEditingController _name;
  late final TextEditingController _projectId;
  late final TextEditingController _databaseId;
  late final TextEditingController _emulatorHost;
  late final TextEditingController _serviceAccount;
  late _Mode _mode;
  List<AstryxFile> _picked = const <AstryxFile>[];

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My Firestore');
    _projectId = TextEditingController(text: initial?.projectId ?? '');
    _databaseId = TextEditingController(
      text: initial?.databaseId ?? '(default)',
    );
    _emulatorHost = TextEditingController(
      text: initial?.emulatorHost ?? 'localhost:8080',
    );
    _serviceAccount = TextEditingController(
      text: initial?.serviceAccountJson ?? '',
    );
    _mode = initial?.mode == 'emulator' ? _Mode.emulator : _Mode.serviceAccount;
  }

  @override
  void dispose() {
    _name.dispose();
    _projectId.dispose();
    _databaseId.dispose();
    _emulatorHost.dispose();
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
    // Reading the project out of the key saves retyping something that is
    // already in the file, and that has to match it exactly.
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

  FirestoreFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_projectId.text.trim().isEmpty) {
      return fail('project', 'A Google Cloud project ID is required.');
    }
    if (_mode == _Mode.serviceAccount) {
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
    } else if (_emulatorHost.text.trim().isEmpty) {
      return fail('emulator', 'An emulator host and port are required.');
    }
    clearValidation();
    return FirestoreFormResult(
      name: _name.text.trim(),
      projectId: _projectId.text.trim(),
      databaseId: _databaseId.text.trim().isEmpty
          ? '(default)'
          : _databaseId.text.trim(),
      mode: _mode == _Mode.emulator ? 'emulator' : 'serviceAccount',
      emulatorHost: _mode == _Mode.emulator ? _emulatorHost.text.trim() : null,
      serviceAccountJson: _mode == _Mode.serviceAccount
          ? _serviceAccount.text
          : null,
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
        AstryxRadioList<_Mode>(
          label: 'How to reach Firestore',
          value: _mode,
          onChanged: (value) => setState(() {
            clearValidation();
            _mode = value;
          }),
          options: const <AstryxRadioOption<_Mode>>[
            AstryxRadioOption(
              value: _Mode.serviceAccount,
              label: 'Service account',
              description: 'A real project, authenticated with a JSON key.',
            ),
            AstryxRadioOption(
              value: _Mode.emulator,
              label: 'Emulator',
              description: 'A local emulator, with no credentials at all.',
            ),
          ],
        ),
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Project ID',
              controller: _projectId,
              status: statusFor('project'),
              required: true,
              placeholder: 'my-project-1234',
            ),
            AstryxTextInput(
              label: 'Database ID',
              controller: _databaseId,
              placeholder: '(default)',
            ),
          ],
        ),
        if (_mode == _Mode.serviceAccount)
          AstryxFileInput(
            label: 'Service-account key',
            description:
                'The JSON stays in the OS keychain, not on disk beside '
                'the connection.',
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
          )
        else
          AstryxTextInput(
            label: 'Emulator host',
            description: 'Host and port, as the emulator prints on startup.',
            controller: _emulatorHost,
            status: statusFor('emulator'),
            required: true,
            placeholder: 'localhost:8080',
          ),
      ],
    );
  }
}
