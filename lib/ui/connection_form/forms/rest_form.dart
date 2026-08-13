import 'dart:convert';

import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';
import 'http_auth_fields.dart';

class RestFormResult {
  const RestFormResult({
    required this.name,
    required this.baseUrl,
    required this.authMode,
    this.apiKeyHeader,
    this.bearerToken,
    this.apiKey,
    this.basicAuth,
    required this.operationsJson,
  });

  final String name;
  final String baseUrl;
  final String authMode; // none | bearer | apiKey | basic
  final String? apiKeyHeader;
  final String? bearerToken;
  final String? apiKey;
  final String? basicAuth;
  final String operationsJson;
}

class RestForm extends StatefulWidget {
  const RestForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
  });

  final ValueChanged<RestFormResult> onSubmit;
  final VoidCallback onCancel;
  final RestFormResult? initial;

  @override
  State<RestForm> createState() => _RestFormState();
}

class _RestFormState extends State<RestForm>
    with ConnectionFormValidation<RestForm> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKeyHeader;
  late final TextEditingController _secret;
  late final TextEditingController _operations;
  late HttpAuthMode _authMode;

  static const _exampleOperations = '''[
  {"name": "Users",    "method": "GET",  "path": "/users"},
  {"name": "User #1",  "method": "GET",  "path": "/users/1"},
  {"name": "New user", "method": "POST", "path": "/users",
   "body": "{\\"name\\": \\"Alice\\", \\"email\\": \\"a@x.io\\"}"}
]''';

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My REST API');
    _baseUrl = TextEditingController(
      text: initial?.baseUrl ?? 'https://jsonplaceholder.typicode.com',
    );
    _apiKeyHeader = TextEditingController(
      text: initial?.apiKeyHeader ?? 'X-API-Key',
    );
    _secret = TextEditingController(
      text: initial?.bearerToken ?? initial?.apiKey ?? initial?.basicAuth ?? '',
    );
    _operations = TextEditingController(
      text: initial?.operationsJson ?? _exampleOperations,
    );
    _authMode = HttpAuthMode.byName(initial?.authMode);
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKeyHeader.dispose();
    _secret.dispose();
    _operations.dispose();
    super.dispose();
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      fail('name', 'Give this connection a name.');
      return;
    }
    final url = Uri.tryParse(_baseUrl.text.trim());
    if (_baseUrl.text.trim().isEmpty || url == null || !url.hasScheme) {
      fail('baseUrl', 'A base URL including https:// is required.');
      return;
    }
    if (_authMode != HttpAuthMode.none && _secret.text.isEmpty) {
      fail('secret', 'This authentication mode needs a value.');
      return;
    }
    // The operations list drives the whole object tree for this connection, so
    // a typo here would otherwise surface as an empty rail with no explanation.
    final operationsError = validateOperationsJson(_operations.text);
    if (operationsError != null) {
      fail('operations', operationsError);
      return;
    }
    clearValidation();
    widget.onSubmit(
      RestFormResult(
        name: _name.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        authMode: _authMode.name,
        apiKeyHeader: _authMode == HttpAuthMode.apiKey
            ? _apiKeyHeader.text.trim()
            : null,
        bearerToken: _authMode == HttpAuthMode.bearer ? _secret.text : null,
        apiKey: _authMode == HttpAuthMode.apiKey ? _secret.text : null,
        basicAuth: _authMode == HttpAuthMode.basic ? _secret.text : null,
        operationsJson: _operations.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConnectionFormShell(
      nameController: _name,
      nameStatus: statusFor('name'),
      formError: formError,
      onSave: _submit,
      onCancel: widget.onCancel,
      // Nothing to ping: a REST connection is a base URL and a list of saved
      // calls, and "does this host answer" is not a question this form can ask
      // without picking one of them arbitrarily.
      children: <Widget>[
        AstryxTextInput(
          label: 'Base URL',
          description: 'Each operation path is appended to this.',
          controller: _baseUrl,
          status: statusFor('baseUrl'),
          required: true,
          placeholder: 'https://api.example.com',
        ),
        HttpAuthFields(
          mode: _authMode,
          onModeChanged: (mode) => setState(() {
            clearValidation();
            _authMode = mode;
          }),
          secret: _secret,
          secretStatus: statusFor('secret'),
          apiKeyHeader: _apiKeyHeader,
        ),
        AstryxTextArea(
          label: 'Operations',
          description: 'A JSON array. Each entry becomes a row in the rail.',
          controller: _operations,
          status: statusFor('operations'),
          minLines: 6,
          maxLines: 14,
        ),
      ],
    );
  }
}

/// Checks that an operations list is a JSON array of named objects.
///
/// Returns a message, or null when it is usable.
String? validateOperationsJson(String raw) {
  if (raw.trim().isEmpty) return 'At least one operation is needed.';
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    return 'That is not valid JSON: $e';
  }
  if (decoded is! List) return 'The operations have to be a JSON array.';
  if (decoded.isEmpty) return 'At least one operation is needed.';
  for (final (index, entry) in decoded.indexed) {
    if (entry is! Map) return 'Operation ${index + 1} is not an object.';
    if (entry['name'] is! String || (entry['name'] as String).trim().isEmpty) {
      return 'Operation ${index + 1} has no "name".';
    }
  }
  return null;
}
