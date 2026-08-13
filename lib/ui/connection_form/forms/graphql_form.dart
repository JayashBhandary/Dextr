import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';
import 'http_auth_fields.dart';
import 'rest_form.dart' show validateOperationsJson;

class GraphqlFormResult {
  const GraphqlFormResult({
    required this.name,
    required this.endpoint,
    required this.authMode,
    this.apiKeyHeader,
    this.bearerToken,
    this.apiKey,
    this.basicAuth,
    required this.operationsJson,
  });

  final String name;
  final String endpoint;
  final String authMode; // none | bearer | apiKey | basic
  final String? apiKeyHeader;
  final String? bearerToken;
  final String? apiKey;
  final String? basicAuth;
  final String operationsJson;
}

class GraphqlForm extends StatefulWidget {
  const GraphqlForm({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
  });

  final ValueChanged<GraphqlFormResult> onSubmit;
  final VoidCallback onCancel;
  final GraphqlFormResult? initial;

  @override
  State<GraphqlForm> createState() => _GraphqlFormState();
}

class _GraphqlFormState extends State<GraphqlForm>
    with ConnectionFormValidation<GraphqlForm> {
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _apiKeyHeader;
  late final TextEditingController _secret;
  late final TextEditingController _operations;
  late HttpAuthMode _authMode;

  static const _exampleOperations = '''[
  {"name": "Countries",
   "query": "query { countries { code name emoji } }",
   "rowsPath": "countries"}
]''';

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My GraphQL API');
    _endpoint = TextEditingController(
      text: initial?.endpoint ?? 'https://countries.trevorblades.com/',
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
    _endpoint.dispose();
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
    final url = Uri.tryParse(_endpoint.text.trim());
    if (_endpoint.text.trim().isEmpty || url == null || !url.hasScheme) {
      fail('endpoint', 'An endpoint URL including https:// is required.');
      return;
    }
    if (_authMode != HttpAuthMode.none && _secret.text.isEmpty) {
      fail('secret', 'This authentication mode needs a value.');
      return;
    }
    final operationsError = validateOperationsJson(_operations.text);
    if (operationsError != null) {
      fail('operations', operationsError);
      return;
    }
    clearValidation();
    widget.onSubmit(
      GraphqlFormResult(
        name: _name.text.trim(),
        endpoint: _endpoint.text.trim(),
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
      children: <Widget>[
        AstryxTextInput(
          label: 'Endpoint',
          description: 'The single URL every query is posted to.',
          controller: _endpoint,
          status: statusFor('endpoint'),
          required: true,
          placeholder: 'https://api.example.com/graphql',
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
          description:
              'A JSON array. Each entry needs a name, a query, and the '
              'rowsPath the list of rows sits at in the response.',
          controller: _operations,
          status: statusFor('operations'),
          minLines: 6,
          maxLines: 14,
        ),
      ],
    );
  }
}
