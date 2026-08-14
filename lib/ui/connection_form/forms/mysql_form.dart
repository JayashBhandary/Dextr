import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../connectors/mysql/mysql_ssl.dart';
import '../../../core/hosts.dart';
import 'connection_form_shell.dart';

class MysqlFormResult {
  const MysqlFormResult({
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
  final MysqlSslMode sslMode;
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
  late MysqlSslMode _sslMode;

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
    _sslMode = initial?.sslMode ?? MysqlSslMode.disable;
    // The warning below depends on the host, so the field has to be watched
    // rather than read once at build.
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
    super.dispose();
  }

  /// Whether this configuration sends credentials somewhere it cannot verify.
  ///
  /// Both halves matter: unverified TLS to a database on this machine is not
  /// worth a warning, and plain TCP to one across the internet is worth a loud
  /// one. Shown while the connection is being *decided*, which is the only
  /// moment the user can act on it.
  bool get _unprotectedToRemoteHost =>
      !isLocalOrPrivateHost(_host.text) && !_sslMode.encrypts;

  bool get _unverifiedToRemoteHost =>
      !isLocalOrPrivateHost(_host.text) && _sslMode.encrypts;

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
      sslMode: _sslMode,
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
        // A selector rather than a checkbox, and worded like the Postgres one.
        // "Connect over TLS" invited the reading that ticking it made the
        // connection trustworthy, which for this driver it does not.
        AstryxSelector<MysqlSslMode>(
          label: 'SSL mode',
          description: 'How much the server certificate is trusted.',
          value: _sslMode,
          onChanged: (value) =>
              setState(() => _sslMode = value ?? MysqlSslMode.disable),
          options: <AstryxSelectorEntry<MysqlSslMode>>[
            for (final mode in MysqlSslMode.values)
              AstryxSelectorOption<MysqlSslMode>(
                value: mode,
                label: mode.label,
                description: mode.description,
              ),
          ],
        ),
        // Said here, beside the decision, rather than left for the user to
        // infer from an option description they have already scrolled past.
        if (_unprotectedToRemoteHost)
          const AstryxBanner(
            status: AstryxBannerStatus.error,
            title: 'This sends the password in the clear',
            description:
                'The host is not on this machine and SSL mode is "disable", so '
                'the MySQL handshake and every row cross the network '
                'unencrypted. Choose "require", or reach the server through an '
                'SSH tunnel or a VPN.',
          ),
        if (_unverifiedToRemoteHost)
          const AstryxBanner(
            status: AstryxBannerStatus.warning,
            title: 'Encrypted, but the server is not verified',
            description:
                'MySQL connections here accept any certificate, so this hides '
                'the traffic from an observer but does not prove you reached '
                'the right server. On a network you do not control, tunnel to '
                'the database instead.',
          ),
      ],
    );
  }
}
