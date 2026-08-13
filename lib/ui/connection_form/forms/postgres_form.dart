import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';

class PostgresFormResult {
  const PostgresFormResult({
    required this.name,
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.sslMode,
  });

  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String sslMode; // disable | require | verifyFull
}

class PostgresForm extends StatefulWidget {
  const PostgresForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<PostgresFormResult> onSubmit;
  final VoidCallback onCancel;
  final PostgresFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(PostgresFormResult result)? onTest;

  @override
  State<PostgresForm> createState() => _PostgresFormState();
}

enum _Entry { fields, uri }

class _PostgresFormState extends State<PostgresForm>
    with ConnectionFormValidation<PostgresForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _uri;
  late num? _port;
  late String _ssl;
  _Entry _entry = _Entry.fields;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My Postgres');
    _host = TextEditingController(text: initial?.host ?? 'localhost');
    _database = TextEditingController(text: initial?.database ?? 'postgres');
    _username = TextEditingController(text: initial?.username ?? 'postgres');
    _password = TextEditingController(text: initial?.password ?? '');
    _uri = TextEditingController();
    _port = initial?.port ?? 5432;
    _ssl = initial?.sslMode ?? 'require';
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    _uri.dispose();
    super.dispose();
  }

  static const _sslToUri = <String, String>{
    'disable': 'disable',
    'require': 'require',
    'verifyFull': 'verify-full',
  };

  String _composeUri() {
    final user = Uri.encodeComponent(_username.text.trim());
    final password = _password.text.isEmpty
        ? ''
        : ':${Uri.encodeComponent(_password.text)}';
    final auth = user.isEmpty ? '' : '$user$password@';
    final database = Uri.encodeComponent(_database.text.trim());
    return 'postgresql://$auth${_host.text.trim()}:${_port ?? 5432}'
        '/$database?sslmode=${_sslToUri[_ssl]}';
  }

  /// Parses a postgres:// or postgresql:// URI into the fields. Returns an error
  /// message, or null once the fields are populated.
  String? _applyUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        (uri.scheme != 'postgres' && uri.scheme != 'postgresql')) {
      return 'The URI has to start with postgresql:// or postgres://';
    }
    if (uri.host.isEmpty) return 'The URI has no host in it.';

    var username = '';
    var password = '';
    if (uri.userInfo.isNotEmpty) {
      final separator = uri.userInfo.indexOf(':');
      if (separator < 0) {
        username = Uri.decodeComponent(uri.userInfo);
      } else {
        username = Uri.decodeComponent(uri.userInfo.substring(0, separator));
        password = Uri.decodeComponent(uri.userInfo.substring(separator + 1));
      }
    }
    final database = uri.pathSegments.isEmpty
        ? ''
        : Uri.decodeComponent(uri.pathSegments.first);
    _host.text = uri.host;
    _port = uri.hasPort ? uri.port : 5432;
    _database.text = database.isEmpty ? 'postgres' : database;
    _username.text = username;
    _password.text = password;
    _ssl = switch (uri.queryParameters['sslmode']) {
      'disable' => 'disable',
      'verify-full' || 'verify-ca' => 'verifyFull',
      _ => 'require',
    };
    return null;
  }

  void _switchEntry(_Entry entry) {
    if (entry == _entry) return;
    setState(() {
      clearValidation();
      if (entry == _Entry.uri) {
        // Entering URI mode: show what the fields currently say, so the two
        // halves never disagree about what would be saved.
        _uri.text = _composeUri();
      } else if (_uri.text.trim().isNotEmpty) {
        _applyUri(_uri.text);
      }
      _entry = entry;
    });
  }

  PostgresFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_entry == _Entry.uri) {
      final error = _applyUri(_uri.text);
      if (error != null) return fail('uri', error);
    }
    if (_host.text.trim().isEmpty) {
      return fail('host', 'A host is required.');
    }
    final port = _port;
    if (port == null) return fail('port', 'A port is required.');
    clearValidation();
    return PostgresFormResult(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: port.toInt(),
      database: _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      sslMode: _ssl,
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
        AstryxSegmentedControl<_Entry>(
          label: 'How to enter the server',
          value: _entry,
          onChanged: _switchEntry,
          segments: const <AstryxSegment<_Entry>>[
            AstryxSegment(value: _Entry.fields, label: 'Fields'),
            AstryxSegment(value: _Entry.uri, label: 'URI'),
          ],
        ),
        if (_entry == _Entry.uri)
          AstryxTextInput(
            label: 'Connection URI',
            description: 'Parsed into the fields when you save or test.',
            controller: _uri,
            status: statusFor('uri'),
            placeholder:
                'postgresql://user:password@host:5432/database?sslmode=require',
          )
        else ...<Widget>[
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
          AstryxSelector<String>(
            label: 'SSL mode',
            description: 'How much the server certificate is trusted.',
            value: _ssl,
            onChanged: (value) => setState(() => _ssl = value ?? 'require'),
            options: const <AstryxSelectorEntry<String>>[
              AstryxSelectorOption(
                value: 'disable',
                label: 'disable',
                description: 'Plain TCP. For a database on this machine.',
              ),
              AstryxSelectorOption(
                value: 'require',
                label: 'require',
                description: 'Encrypted, certificate not verified.',
              ),
              AstryxSelectorOption(
                value: 'verifyFull',
                label: 'verifyFull',
                description: 'Encrypted, certificate and host verified.',
              ),
            ],
          ),
        ],
      ],
    );
  }
}
