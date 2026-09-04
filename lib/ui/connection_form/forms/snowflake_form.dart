import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../connectors/snowflake/snowflake_types.dart';
import 'connection_form_shell.dart';

class SnowflakeFormResult {
  const SnowflakeFormResult({
    required this.name,
    required this.account,
    required this.warehouse,
    required this.database,
    required this.schema,
    required this.role,
    required this.authMode,
    required this.token,
  });

  final String name;
  final String account;
  final String warehouse;
  final String database;
  final String schema;
  final String role;
  final SnowflakeAuth authMode;
  final String token;
}

class SnowflakeForm extends StatefulWidget {
  const SnowflakeForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<SnowflakeFormResult> onSubmit;
  final VoidCallback onCancel;
  final SnowflakeFormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(SnowflakeFormResult result)? onTest;

  @override
  State<SnowflakeForm> createState() => _SnowflakeFormState();
}

class _SnowflakeFormState extends State<SnowflakeForm>
    with ConnectionFormValidation<SnowflakeForm> {
  late final TextEditingController _name;
  late final TextEditingController _account;
  late final TextEditingController _warehouse;
  late final TextEditingController _database;
  late final TextEditingController _schema;
  late final TextEditingController _role;
  late final TextEditingController _token;
  late SnowflakeAuth _auth;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My Snowflake');
    _account = TextEditingController(text: initial?.account ?? '');
    _warehouse = TextEditingController(text: initial?.warehouse ?? '');
    _database = TextEditingController(text: initial?.database ?? '');
    _schema = TextEditingController(text: initial?.schema ?? 'PUBLIC');
    _role = TextEditingController(text: initial?.role ?? '');
    _token = TextEditingController(text: initial?.token ?? '');
    _auth = initial?.authMode ?? SnowflakeAuth.pat;
    // The endpoint preview below is derived from the account, so the field has
    // to be watched rather than read once at build.
    _account.addListener(_onAccountChanged);
  }

  void _onAccountChanged() => setState(() {});

  @override
  void dispose() {
    _account.removeListener(_onAccountChanged);
    _name.dispose();
    _account.dispose();
    _warehouse.dispose();
    _database.dispose();
    _schema.dispose();
    _role.dispose();
    _token.dispose();
    super.dispose();
  }

  SnowflakeFormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_account.text.trim().isEmpty) {
      return fail('account', 'An account identifier is required.');
    }
    if (_token.text.trim().isEmpty) {
      return fail('token', 'A token is required — this is how the API '
          'authenticates.');
    }
    if (_warehouse.text.trim().isEmpty) {
      return fail('warehouse', 'A warehouse is required: without one there is '
          'no compute to run a query on.');
    }
    if (_database.text.trim().isEmpty) {
      return fail('database', 'A database is required — it is what the rail '
          'lists tables from.');
    }
    clearValidation();
    return SnowflakeFormResult(
      name: _name.text.trim(),
      account: _account.text.trim(),
      warehouse: _warehouse.text.trim(),
      database: _database.text.trim(),
      schema: _schema.text.trim(),
      role: _role.text.trim(),
      authMode: _auth,
      token: _token.text,
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
    final account = _account.text.trim();

    return ConnectionFormShell(
      nameController: _name,
      nameStatus: statusFor('name'),
      formError: formError,
      onSave: _submit,
      onCancel: widget.onCancel,
      onTest: widget.onTest == null ? null : _runTest,
      children: <Widget>[
        AstryxTextInput(
          label: 'Account identifier',
          description:
              'From the Snowflake URL: the part before '
              '.snowflakecomputing.com. A full hostname works too.',
          controller: _account,
          status: statusFor('account'),
          required: true,
          placeholder: 'xy12345.eu-west-1',
        ),
        // The account identifier is the field people get wrong, and the error
        // it produces is a DNS failure that names nothing. Showing the host it
        // resolves to makes the mistake visible before the connection is
        // attempted.
        if (account.isNotEmpty)
          AstryxBanner(
            status: AstryxBannerStatus.info,
            title: 'Dextr will call https://${snowflakeHost(account)}',
            description: 'Its /api/v2/statements endpoint. If that is not your '
                'account URL, the identifier above is not right.',
          ),
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Warehouse',
              description: 'The compute that runs the queries.',
              controller: _warehouse,
              status: statusFor('warehouse'),
              required: true,
              placeholder: 'COMPUTE_WH',
            ),
            AstryxTextInput(
              label: 'Role',
              description: 'Left empty, your default role.',
              controller: _role,
              optional: true,
              placeholder: 'ANALYST',
            ),
          ],
        ),
        AstryxFormLayout(
          direction: AstryxFormLayoutDirection.horizontal,
          children: <Widget>[
            AstryxTextInput(
              label: 'Database',
              controller: _database,
              status: statusFor('database'),
              required: true,
              placeholder: 'ANALYTICS',
            ),
            AstryxTextInput(
              label: 'Schema',
              description: 'The default for unqualified names.',
              controller: _schema,
              placeholder: 'PUBLIC',
            ),
          ],
        ),
        AstryxRadioList<SnowflakeAuth>(
          label: 'Token type',
          value: _auth,
          onChanged: (value) => setState(() {
            clearValidation();
            _auth = value;
          }),
          options: <AstryxRadioOption<SnowflakeAuth>>[
            for (final mode in SnowflakeAuth.values)
              AstryxRadioOption<SnowflakeAuth>(
                value: mode,
                label: mode.label,
                description: mode.description,
              ),
          ],
        ),
        AstryxTextInput(
          label: _auth.label,
          description: 'Kept in the OS keychain, not beside the connection.',
          controller: _token,
          status: statusFor('token'),
          obscureText: true,
          required: true,
        ),
        // Stated where the choice is made rather than left for someone to
        // discover by looking for an option that is not there.
        const AstryxBanner(
          status: AstryxBannerStatus.info,
          title: 'Key-pair authentication is not offered',
          description:
              'It signs a JWT with an RSA key, and neither Dart nor anything '
              'Dextr depends on can produce that signature. A programmatic '
              'access token is the closest equivalent: scope it to a role and '
              'give it an expiry in Snowflake.',
        ),
        // Both of these are absences with a cause, and both change what
        // someone should expect from the workspace, so they are said here
        // rather than found later.
        const AstryxBanner(
          status: AstryxBannerStatus.warning,
          title: 'No transactions over this transport',
          description:
              'Every statement is its own HTTP request and its own session, so '
              'there is nowhere for a BEGIN to live between two of them. The '
              'Query pane will not offer a transaction.',
        ),
      ],
    );
  }
}
