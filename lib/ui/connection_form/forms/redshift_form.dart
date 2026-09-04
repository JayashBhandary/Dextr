import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../core/hosts.dart';
import 'connection_form_shell.dart';

class RedshiftFormResult {
  const RedshiftFormResult({
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

class RedshiftForm extends StatefulWidget {
  const RedshiftForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<RedshiftFormResult> onSubmit;
  final VoidCallback onCancel;
  final RedshiftFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(RedshiftFormResult result)? onTest;

  @override
  State<RedshiftForm> createState() => _RedshiftFormState();
}

enum _Entry { fields, endpoint }

class _RedshiftFormState extends State<RedshiftForm>
    with ConnectionFormValidation<RedshiftForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _endpoint;
  late num? _port;
  late String _ssl;
  _Entry _entry = _Entry.fields;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My Redshift');
    _host = TextEditingController(text: initial?.host ?? '');
    _database = TextEditingController(text: initial?.database ?? 'dev');
    _username = TextEditingController(text: initial?.username ?? 'awsuser');
    _password = TextEditingController(text: initial?.password ?? '');
    _endpoint = TextEditingController();
    _port = initial?.port ?? 5439;
    _ssl = initial?.sslMode ?? 'require';
    _host.addListener(_onHostChanged);
  }

  void _onHostChanged() => setState(() {});

  @override
  void dispose() {
    _host.removeListener(_onHostChanged);
    _name.dispose();
    _host.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  /// Whether the password and every row would cross an untrusted network
  /// unencrypted. A cluster is never on this machine, so this is nearly always
  /// worth saying when SSL is off.
  bool get _plainToRemoteHost =>
      _ssl == 'disable' && !isLocalOrPrivateHost(_host.text);

  String _composeEndpoint() =>
      '${_host.text.trim()}:${_port ?? 5439}/${_database.text.trim()}';

  /// Parse what the AWS console calls the endpoint —
  /// `cluster.abc123.eu-west-1.redshift.amazonaws.com:5439/dev` — into the
  /// fields. Returns an error message, or null once they are populated.
  ///
  /// Worth having as its own mode because that string is one click to copy in
  /// the console and three fields to retype by hand, and retyping a host of
  /// that length is where the typo goes.
  String? _applyEndpoint(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return 'Paste the endpoint from the Redshift console.';
    // A JDBC URL pasted whole is the same thing with a prefix.
    for (final prefix in const <String>[
      'jdbc:redshift://',
      'postgresql://',
      'postgres://',
      'redshift://',
    ]) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length);
        break;
      }
    }
    // Credentials in a pasted URL belong in their own fields.
    final at = text.lastIndexOf('@');
    if (at >= 0) {
      final userInfo = text.substring(0, at);
      text = text.substring(at + 1);
      final colon = userInfo.indexOf(':');
      if (colon < 0) {
        _username.text = Uri.decodeComponent(userInfo);
      } else {
        _username.text = Uri.decodeComponent(userInfo.substring(0, colon));
        _password.text = Uri.decodeComponent(userInfo.substring(colon + 1));
      }
    }

    final question = text.indexOf('?');
    if (question >= 0) text = text.substring(0, question);

    final slash = text.indexOf('/');
    if (slash >= 0) {
      final database = text.substring(slash + 1);
      if (database.isNotEmpty) _database.text = database;
      text = text.substring(0, slash);
    }

    final colon = text.lastIndexOf(':');
    if (colon >= 0) {
      final port = int.tryParse(text.substring(colon + 1));
      if (port == null) return 'The port in that endpoint is not a number.';
      _port = port;
      text = text.substring(0, colon);
    }

    if (text.isEmpty) return 'That endpoint has no host in it.';
    _host.text = text;
    return null;
  }

  void _switchEntry(_Entry entry) {
    if (entry == _entry) return;
    setState(() {
      clearValidation();
      if (entry == _Entry.endpoint) {
        // Show what the fields currently say, so the two halves never disagree
        // about what would be saved.
        _endpoint.text = _composeEndpoint();
      } else if (_endpoint.text.trim().isNotEmpty) {
        _applyEndpoint(_endpoint.text);
      }
      _entry = entry;
    });
  }

  RedshiftFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_entry == _Entry.endpoint) {
      final error = _applyEndpoint(_endpoint.text);
      if (error != null) return fail('endpoint', error);
    }
    if (_host.text.trim().isEmpty) {
      return fail('host', 'The cluster endpoint host is required.');
    }
    final port = _port;
    if (port == null) return fail('port', 'A port is required.');
    if (_database.text.trim().isEmpty) {
      return fail('database', 'A database is required.');
    }
    clearValidation();
    return RedshiftFormResult(
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
          label: 'How to enter the cluster',
          value: _entry,
          onChanged: _switchEntry,
          segments: const <AstryxSegment<_Entry>>[
            AstryxSegment(value: _Entry.fields, label: 'Fields'),
            AstryxSegment(value: _Entry.endpoint, label: 'Endpoint'),
          ],
        ),
        if (_entry == _Entry.endpoint)
          AstryxTextInput(
            label: 'Cluster endpoint',
            description:
                'Copied from the Redshift console. Parsed into the fields when '
                'you save or test.',
            controller: _endpoint,
            status: statusFor('endpoint'),
            placeholder:
                'my-cluster.abc123.eu-west-1.redshift.amazonaws.com:5439/dev',
          )
        else ...<Widget>[
          AstryxFormLayout(
            direction: AstryxFormLayoutDirection.horizontal,
            children: <Widget>[
              AstryxTextInput(
                label: 'Host',
                description: 'The cluster or workgroup endpoint, without the '
                    'port.',
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
          AstryxTextInput(
            label: 'Database',
            description: 'A provisioned cluster is created with "dev".',
            controller: _database,
            status: statusFor('database'),
            required: true,
          ),
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
                description: 'Plain TCP. Only for a tunnel that is already '
                    'encrypted.',
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
          // Said beside the decision rather than left in an option
          // description the reader has already scrolled past.
          if (_plainToRemoteHost)
            const AstryxBanner(
              status: AstryxBannerStatus.error,
              title: 'This sends the password in the clear',
              description:
                  'A Redshift cluster is reached across a network, and SSL '
                  'mode is "disable", so the password and every row cross it '
                  'unencrypted. Choose "verifyFull" — Redshift presents a '
                  'certificate from a public authority, so it verifies.',
            ),
        ],
      ],
    );
  }
}
