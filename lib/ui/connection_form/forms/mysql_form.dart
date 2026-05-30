import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/tokens.dart';

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
  const MysqlForm({super.key, required this.onSubmit, this.initial});

  final ValueChanged<MysqlFormResult> onSubmit;
  final MysqlFormResult? initial;

  @override
  State<MysqlForm> createState() => _MysqlFormState();
}

class _MysqlFormState extends State<MysqlForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _secure;
  String? _error;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? 'My MySQL');
    _host = TextEditingController(text: i?.host ?? 'localhost');
    _port = TextEditingController(text: '${i?.port ?? 3306}');
    _database = TextEditingController(text: i?.database ?? 'dextr');
    _username = TextEditingController(text: i?.username ?? 'root');
    _password = TextEditingController(text: i?.password ?? '');
    _secure = i?.secure ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _database.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final port = int.tryParse(_port.text.trim());
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name required');
      return;
    }
    if (_host.text.trim().isEmpty) {
      setState(() => _error = 'Host required');
      return;
    }
    if (port == null) {
      setState(() => _error = 'Port must be a number');
      return;
    }
    widget.onSubmit(MysqlFormResult(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: port,
      database: _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      secure: _secure,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Connection name',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _database,
            decoration: const InputDecoration(
              labelText: 'Database',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          SwitchListTile(
            title: const Text('Use TLS'),
            subtitle: const Text('Connect with secure transport'),
            value: _secure,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => setState(() => _secure = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: Spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: Spacing.sm),
              FilledButton(onPressed: _submit, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
