import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import 'test_connection_button.dart';

/// The shape every connection form shares: a name, the backend's own fields, a
/// way to try it, and the two buttons that end the page.
///
/// Eight backends, one arrangement. Each form supplies its fields and its
/// validation; the order — configure, verify, save — is the same in all of them
/// because it is the order the work happens in.
class ConnectionFormShell extends StatelessWidget {
  const ConnectionFormShell({
    super.key,
    required this.nameController,
    required this.nameStatus,
    required this.children,
    required this.onSave,
    required this.onCancel,
    this.onTest,
    this.formError,
    this.saveLabel = 'Save connection',
  });

  final TextEditingController nameController;
  final AstryxFieldStatus? nameStatus;

  /// The backend's own fields.
  final List<Widget> children;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  /// Null for a backend with nothing to connect to yet — a saved-operation list
  /// is not something that can be pinged.
  final Future<void>? Function()? onTest;

  /// A problem that belongs to the form rather than to one field.
  final String? formError;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final onTest = this.onTest;
    final formError = this.formError;

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing5,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxFormLayout(
          children: <Widget>[
            AstryxTextInput(
              label: 'Connection name',
              description: 'What this connection is called in the rail.',
              controller: nameController,
              status: nameStatus,
              required: true,
            ),
            ...children,
          ],
        ),
        if (formError != null)
          AstryxBanner(
            status: AstryxBannerStatus.error,
            title: 'This cannot be saved yet',
            description: formError,
          ),
        if (onTest != null) ...<Widget>[
          const AstryxDivider(),
          TestConnectionButton(run: onTest),
        ],
        const AstryxDivider(),
        AstryxHStack(
          gap: AstryxSpacingToken.spacing2,
          justify: AstryxStackJustify.end,
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            AstryxButton(label: 'Cancel', onPressed: onCancel),
            AstryxButton(
              label: saveLabel,
              variant: AstryxButtonVariant.primary,
              onPressed: onSave,
            ),
          ],
        ),
      ],
    );
  }
}

/// Puts a validation message on the field it belongs to.
///
/// A form-level "Host required" makes the reader find the host field themselves;
/// `AstryxFieldStatus` on that field says it where they are looking, and is
/// announced assertively because it is blocking them.
mixin ConnectionFormValidation<T extends StatefulWidget> on State<T> {
  String? _field;
  String? _message;

  /// Records a failure against [field] and returns null, so a validator can
  /// `return fail('host', 'Host required')`.
  Null fail(String field, String message) {
    setState(() {
      _field = field;
      _message = message;
    });
    return null;
  }

  void clearValidation() {
    if (_field == null && _message == null) return;
    setState(() {
      _field = null;
      _message = null;
    });
  }

  /// The status for one field, or null when the failure is elsewhere.
  AstryxFieldStatus? statusFor(String field) =>
      _field == field && _message != null
      ? AstryxFieldStatus.error(_message!)
      : null;

  /// A failure with no field to sit on — a combination that does not work.
  String? get formError => _field == '' ? _message : null;
}
