import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import 'connection_form_shell.dart';

class S3FormResult {
  const S3FormResult({
    required this.name,
    required this.endpoint,
    this.port,
    required this.region,
    required this.useSSL,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  final String name;
  final String endpoint;
  final int? port;
  final String region;
  final bool useSSL;
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
}

class S3Form extends StatefulWidget {
  const S3Form({
    super.key,
    required this.onSubmit,
    required this.onCancel,
    this.initial,
    this.onTest,
  });

  final ValueChanged<S3FormResult> onSubmit;
  final VoidCallback onCancel;
  final S3FormResult? initial;

  /// Attempts a live connection with the given values; throws on failure.
  final Future<void> Function(S3FormResult result)? onTest;

  @override
  State<S3Form> createState() => _S3FormState();
}

class _S3FormState extends State<S3Form> with ConnectionFormValidation<S3Form> {
  late final TextEditingController _name;
  late final TextEditingController _endpoint;
  late final TextEditingController _region;
  late final TextEditingController _access;
  late final TextEditingController _secret;
  late final TextEditingController _session;
  late num? _port;
  late bool _useSSL;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? 'My S3');
    _endpoint = TextEditingController(
      text: initial?.endpoint ?? 's3.amazonaws.com',
    );
    _region = TextEditingController(text: initial?.region ?? 'us-east-1');
    _access = TextEditingController(text: initial?.accessKeyId ?? '');
    _secret = TextEditingController(text: initial?.secretAccessKey ?? '');
    _session = TextEditingController(text: initial?.sessionToken ?? '');
    _port = initial?.port;
    // Off by default for a new connection: most local MinIO setups serve plain
    // HTTP, and SSL against HTTP is the "wrong version number" trap.
    _useSSL = initial?.useSSL ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _region.dispose();
    _access.dispose();
    _secret.dispose();
    _session.dispose();
    super.dispose();
  }

  S3FormResult? _validate() {
    if (_name.text.trim().isEmpty) {
      return fail('name', 'Give this connection a name.');
    }
    if (_endpoint.text.trim().isEmpty) {
      return fail('endpoint', 'An endpoint host is required.');
    }
    if (_access.text.trim().isEmpty) {
      return fail('access', 'An access key ID is required.');
    }
    if (_secret.text.isEmpty) {
      return fail('secret', 'A secret access key is required.');
    }
    clearValidation();
    return S3FormResult(
      name: _name.text.trim(),
      endpoint: _endpoint.text.trim(),
      port: _port?.toInt(),
      region: _region.text.trim(),
      useSSL: _useSSL,
      accessKeyId: _access.text.trim(),
      secretAccessKey: _secret.text,
      sessionToken: _session.text.trim().isEmpty ? null : _session.text.trim(),
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
              label: 'Endpoint',
              description: 'Host only — no scheme, no bucket.',
              controller: _endpoint,
              status: statusFor('endpoint'),
              required: true,
              placeholder: 's3.amazonaws.com',
            ),
            AstryxNumberInput(
              label: 'Port',
              description: 'Blank uses the protocol default.',
              value: _port,
              min: 1,
              max: 65535,
              integerOnly: true,
              showClear: true,
              optional: true,
              onChanged: (value) => setState(() => _port = value),
            ),
          ],
        ),
        AstryxTextInput(
          label: 'Region',
          controller: _region,
          placeholder: 'us-east-1',
        ),
        AstryxTextInput(
          label: 'Access key ID',
          controller: _access,
          status: statusFor('access'),
          required: true,
        ),
        AstryxTextInput(
          label: 'Secret access key',
          description:
              'Stored in the OS keychain, never in the connection file.',
          controller: _secret,
          status: statusFor('secret'),
          obscureText: true,
          required: true,
        ),
        AstryxTextInput(
          label: 'Session token',
          description: 'Only for temporary STS credentials.',
          controller: _session,
          obscureText: true,
          optional: true,
        ),
        AstryxCheckbox(
          label: 'Use HTTPS',
          description:
              'On for AWS and most hosted S3; off for a local MinIO '
              'serving plain HTTP.',
          value: _useSSL,
          onChanged: (value) => setState(() => _useSSL = value),
        ),
      ],
    );
  }
}
