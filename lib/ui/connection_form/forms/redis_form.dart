import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../core/hosts.dart';
import 'connection_form_shell.dart';

class RedisFormResult {
  const RedisFormResult({
    required this.name,
    required this.host,
    required this.port,
    required this.db,
    required this.username,
    required this.password,
    required this.tls,
  });

  final String name;
  final String host;
  final int port;

  /// Which numbered database the connection selects. The rail still lists the
  /// others; this is the one it opens on.
  final int db;

  /// A Redis 6 ACL user. Empty for a server with a plain `requirepass`.
  final String username;
  final String password;
  final bool tls;
}

class RedisForm extends StatefulWidget {
  const RedisForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<RedisFormResult> onSubmit;
  final VoidCallback onCancel;
  final RedisFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(RedisFormResult result)? onTest;

  @override
  State<RedisForm> createState() => _RedisFormState();
}

class _RedisFormState extends State<RedisForm>
    with ConnectionFormValidation<RedisForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late num? _port;
  late num? _db;
  late bool _tls;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My Redis');
    _host = TextEditingController(text: initial?.host ?? 'localhost');
    _username = TextEditingController(text: initial?.username ?? '');
    _password = TextEditingController(text: initial?.password ?? '');
    _port = initial?.port ?? 6379;
    _db = initial?.db ?? 0;
    _tls = initial?.tls ?? false;
    // The warning below depends on the host, so the field is watched rather
    // than read once at build.
    _host.addListener(_onHostChanged);
  }

  void _onHostChanged() => setState(() {});

  @override
  void dispose() {
    _host.removeListener(_onHostChanged);
    _name.dispose();
    _host.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Whether the password would cross a network nobody here controls in the
  /// clear. Redis `AUTH` sends it as a plain argument, so without TLS it is
  /// readable by anything on the path.
  bool get _plainToRemoteHost =>
      !_tls && !isLocalOrPrivateHost(_host.text) && _password.text.isNotEmpty;

  RedisFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_host.text.trim().isEmpty) {
      return fail('host', 'A host is required.');
    }
    final port = _port;
    if (port == null) return fail('port', 'A port is required.');
    final db = _db;
    if (db == null) {
      return fail(
        'db',
        'A database index is required — 0 is the default one.',
      );
    }
    if (_username.text.trim().isNotEmpty && _password.text.isEmpty) {
      return fail('password', 'An ACL username needs a password: Redis sends '
          'both together.');
    }
    clearValidation();
    return RedisFormResult(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: port.toInt(),
      db: db.toInt(),
      username: _username.text.trim(),
      password: _password.text,
      tls: _tls,
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
        AstryxNumberInput(
          label: 'Database',
          description:
              'Which numbered database to open on. The rail lists the others '
              'beside it.',
          value: _db,
          min: 0,
          max: 63,
          integerOnly: true,
          status: statusFor('db'),
          onChanged: (value) => setState(() => _db = value),
        ),
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Username',
              description: 'A Redis 6 ACL user. Empty for requirepass.',
              controller: _username,
              optional: true,
              placeholder: 'default',
            ),
            AstryxTextInput(
              label: 'Password',
              controller: _password,
              status: statusFor('password'),
              obscureText: true,
              optional: true,
              // The banner below turns on when there is a password and no TLS,
              // so a keystroke here has to repaint it.
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
        AstryxCheckbox(
          label: 'Connect over TLS',
          description:
              'Required by most managed Redis. Off for a local redis-server, '
              'which does not listen for TLS unless it was built for it.',
          value: _tls,
          onChanged: (value) => setState(() => _tls = value),
        ),
        if (_plainToRemoteHost)
          const AstryxBanner(
            status: AstryxBannerStatus.error,
            title: 'This sends the password in the clear',
            description:
                'The host is not on this machine and TLS is off. Redis AUTH '
                'sends the password as a plain command argument, so anything '
                'on the path can read it — and then every key with it. Turn '
                'TLS on, or reach the server through an SSH tunnel.',
          ),
      ],
    );
  }
}
