import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

/// How an HTTP connection authenticates.
///
/// The names are the strings the connection record already persists, so
/// `mode.name` round-trips through storage unchanged.
enum HttpAuthMode {
  none,
  bearer,
  apiKey,
  basic;

  static HttpAuthMode byName(String? name) =>
      values.firstWhere((mode) => mode.name == name, orElse: () => none);

  String get label => switch (this) {
    none => 'None',
    bearer => 'Bearer token',
    apiKey => 'API key header',
    basic => 'Basic auth',
  };

  String get description => switch (this) {
    none => 'A public endpoint, or one behind a network you are already on.',
    bearer => 'Sent as Authorization: Bearer …',
    apiKey => 'Sent as a header you name.',
    basic => 'Sent as Authorization: Basic …, base64 of user:password.',
  };

  /// What the one secret field is called in this mode.
  String get secretLabel => switch (this) {
    none => 'Secret',
    bearer => 'Bearer token',
    apiKey => 'API key',
    basic => 'user:password',
  };
}

/// The authentication half of the REST and GraphQL forms.
///
/// Shared because the two are the same question — REST and GraphQL differ in
/// what they send, not in how they prove who is sending it.
class HttpAuthFields extends StatelessWidget {
  const HttpAuthFields({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.secret,
    required this.apiKeyHeader,
    this.secretStatus,
  });

  final HttpAuthMode mode;
  final ValueChanged<HttpAuthMode> onModeChanged;
  final TextEditingController secret;
  final TextEditingController apiKeyHeader;
  final AstryxFieldStatus? secretStatus;

  @override
  Widget build(BuildContext context) {
    return AstryxFormLayout(
      children: <Widget>[
        AstryxSelector<HttpAuthMode>(
          label: 'Authentication',
          value: mode,
          onChanged: (value) => onModeChanged(value ?? HttpAuthMode.none),
          options: <AstryxSelectorEntry<HttpAuthMode>>[
            for (final option in HttpAuthMode.values)
              AstryxSelectorOption<HttpAuthMode>(
                value: option,
                label: option.label,
                description: option.description,
              ),
          ],
        ),
        if (mode == HttpAuthMode.apiKey)
          AstryxTextInput(
            label: 'Header name',
            controller: apiKeyHeader,
            placeholder: 'X-API-Key',
          ),
        if (mode != HttpAuthMode.none)
          AstryxTextInput(
            label: mode.secretLabel,
            description: 'Kept in the OS keychain, not in the connection file.',
            controller: secret,
            status: secretStatus,
            obscureText: true,
            required: true,
          ),
      ],
    );
  }
}
