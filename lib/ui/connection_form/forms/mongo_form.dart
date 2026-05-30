import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/tokens.dart';

class MongoFormResult {
  const MongoFormResult({
    required this.name,
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.tls,
  });

  final String name;
  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final bool tls;
}

class MongoForm extends StatefulWidget {
  const MongoForm({super.key, required this.onSubmit, this.initial});

  final ValueChanged<MongoFormResult> onSubmit;
  final MongoFormResult? initial;

  @override
  State<MongoForm> createState() => _MongoFormState();
}

class _MongoFormState extends State<MongoForm> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _database;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _tls;
  String? _error;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _name = TextEditingController(text: i?.name ?? 'My Mongo');
    _host = TextEditingController(text: i?.host ?? 'localhost');
    _port = TextEditingController(text: '${i?.port ?? 27017}');
    _database = TextEditingController(text: i?.database ?? 'dextr');
    _username = TextEditingController(text: i?.username ?? '');
    _password = TextEditingController(text: i?.password ?? '');
    _tls = i?.tls ?? false;
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
    widget.onSubmit(MongoFormResult(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: port,
      database: _database.text.trim().isEmpty ? 'admin' : _database.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      tls: _tls,
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
              labelText: 'Database (auth DB)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Username (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password (optional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: Spacing.md),
          SwitchListTile(
            title: const Text('Use TLS'),
            value: _tls,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => setState(() => _tls = v),
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
