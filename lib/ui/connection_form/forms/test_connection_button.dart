import 'package:astryx_ui/astryx_ui.dart';
import 'package:flutter/widgets.dart';

import '../../../core/errors.dart';

enum _TestStatus { idle, running, success, failure }

/// "Test connection", with the result inline beneath it.
///
/// [run] is invoked on press: it returns null when the form is invalid — the
/// form shows its own validation message in that case — otherwise a future that
/// completes on success and throws on failure.
class TestConnectionButton extends StatefulWidget {
  const TestConnectionButton({super.key, required this.run});

  final Future<void>? Function() run;

  @override
  State<TestConnectionButton> createState() => _TestConnectionButtonState();
}

class _TestConnectionButtonState extends State<TestConnectionButton> {
  _TestStatus _status = _TestStatus.idle;
  String? _message;

  Future<void> _test() async {
    final future = widget.run();
    if (future == null) {
      setState(() {
        _status = _TestStatus.idle;
        _message = null;
      });
      return;
    }
    setState(() {
      _status = _TestStatus.running;
      _message = null;
    });
    try {
      await future;
      if (!mounted) return;
      setState(() {
        _status = _TestStatus.success;
        _message = 'Connected, and the server answered a ping.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _TestStatus.failure;
        _message = e is DextrError ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _status == _TestStatus.running;
    final message = _message;

    return AstryxVStack(
      gap: AstryxSpacingToken.spacing2,
      align: AstryxStackAlign.stretch,
      children: <Widget>[
        AstryxHStack(
          children: <Widget>[
            AstryxButton(
              label: 'Test connection',
              loading: running,
              onPressed: _test,
            ),
          ],
        ),
        // A banner rather than a coloured line: the outcome is announced when it
        // arrives, and it carries an icon as well as a colour, so the result
        // does not depend on telling green from red.
        if (message != null)
          AstryxBanner(
            status: _status == _TestStatus.success
                ? AstryxBannerStatus.success
                : AstryxBannerStatus.error,
            title: _status == _TestStatus.success
                ? 'Connection successful'
                : 'Could not connect',
            description: message,
            onDismiss: () => setState(() {
              _status = _TestStatus.idle;
              _message = null;
            }),
          ),
      ],
    );
  }
}
