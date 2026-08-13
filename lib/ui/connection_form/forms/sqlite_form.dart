import 'package:astryx_ui/astryx_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';

import '../../../services/file_access.dart';
import 'connection_form_shell.dart';

class SqliteFormResult {
  const SqliteFormResult({
    required this.name,
    required this.filePath,
    this.bookmark,
  });

  final String name;
  final String filePath;

  /// Sandbox permission to reopen [filePath] on a later launch, where the
  /// platform requires one. Null when the path alone suffices.
  final String? bookmark;
}

class SqliteForm extends StatefulWidget {
  const SqliteForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<SqliteFormResult> onSubmit;
  final VoidCallback onCancel;
  final SqliteFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(SqliteFormResult result)? onTest;

  @override
  State<SqliteForm> createState() => _SqliteFormState();
}

class _SqliteFormState extends State<SqliteForm>
    with ConnectionFormValidation<SqliteForm> {
  late final TextEditingController _name;
  late final TextEditingController _path;
  List<AstryxFile> _picked = const <AstryxFile>[];

  /// Travels with the path: whatever set one has to set the other, or a saved
  /// connection ends up with permission to reopen a different file.
  String? _bookmark;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My SQLite DB');
    _path = TextEditingController(text: initial?.filePath ?? '');
    _bookmark = initial?.bookmark;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  /// The field validates and displays; the application opens the dialog. That
  /// seam is why `onPick` exists — astryx_ui depends on no picker plugin.
  Future<List<AstryxFile>> _pick(AstryxFilePickRequest request) async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pick a SQLite database',
    );
    final path = file?.path;
    if (path == null) return const <AstryxFile>[];
    _path.text = path;
    // Minted here, while the picker's grant is still live — it cannot be
    // minted later from the path alone.
    _bookmark = await FileAccess.instance.bookmark(path);
    return <AstryxFile>[
      AstryxFile(name: file!.name, size: file.size, handle: path),
    ];
  }

  SqliteFormResult? _validate() {
    final name = _name.text.trim();
    final path = _path.text.trim();
    if (name.isEmpty) return fail('name', 'Give this connection a name.');
    if (path.isEmpty) {
      return fail('file', 'Pick the .db or .sqlite file to open.');
    }
    clearValidation();
    return SqliteFormResult(name: name, filePath: path, bookmark: _bookmark);
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
          label: 'Database file',
          description: 'Opened in place. Nothing is copied.',
          // Without this the summary falls back to the same string as the
          // button beside it, and the row reads "Choose file … Choose file".
          placeholder: 'No file chosen',
          accept: const <String>['.db', '.sqlite', '.sqlite3'],
          status: statusFor('file'),
          required: true,
          files: _picked,
          onPick: _pick,
          onChanged: (files) => setState(() {
            _picked = files;
            if (files.isEmpty) {
              _path.text = '';
              _bookmark = null;
            }
          }),
        ),
        // Shown, not editable: the picker is what sets it, and a path typed by
        // hand that does not exist fails later with a worse message.
        AstryxTextInput(
          label: 'Path',
          controller: _path,
          readOnly: true,
          labelHidden: true,
          placeholder: 'No file picked yet',
        ),
      ],
    );
  }
}
