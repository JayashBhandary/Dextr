import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';

class MysqlFormResult {
  const MysqlFormResult({
    required this.name,
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.secure,
  });

  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final bool secure;
}

class MysqlForm extends StatefulWidget {
  const MysqlForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<MysqlFormResult> onSubmit;
  final VoidCallback onCancel;
  final MysqlFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(MysqlFormResult result)? onTest;

  @override
  State<MysqlForm> createState() => _MysqlFormState();
}

class _MysqlFormState extends State<MysqlForm>
    with ConnectionFormValidation<MysqlForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late num? _port;
  late bool _secure;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My MySQL');
    _host = TextEditingController(text: initial?.host ?? 'localhost');
    _database = TextEditingController(text: initial?.database ?? 'dextr');
    _username = TextEditingController(text: initial?.username ?? 'root');
    _password = TextEditingController(text: initial?.password ?? '');
    _port = initial?.port ?? 3306;
    _secure = initial?.secure ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  MysqlFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_host.text.trim().isEmpty) return fail('host', 'A host is required.');
    final port = _port;
    if (port == null) return fail('port', 'A port is required.');
    clearValidation();
    return MysqlFormResult(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: port.toInt(),
      database: _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      secure: _secure,
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
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Host',
              controller: _host,
              status: statusFor('host'),
              required: true,
            ),
            AstryxNumberInput(
              label: 'Port',
              value: _port,
              min: 1,
              max: 65535,
              integerOnly: true,
              status: statusFor('port'),
              onChanged: (value) => setState(() => _port = value),
            ),
          ],
        ),
        AstryxTextInput(label: 'Database', controller: _database),
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(label: 'Username', controller: _username),
            AstryxTextInput(
              label: 'Password',
              controller: _password,
              obscureText: true,
              optional: true,
            ),
          ],
        ),
        // A checkbox, not a switch: this form has a Save button, and nothing on
        // it takes effect until that is pressed.
        AstryxCheckbox(
          label: 'Connect over TLS',
          description: 'Required by most hosted MySQL; usually off locally.',
          value: _secure,
          onChanged: (value) => setState(() => _secure = value),
        ),
      ],
    );
  }
}
