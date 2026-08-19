import 'package:flutter_riverpod/legacy.dart';

/// How wide the connections rail is when it shows its labels.
const railExpandedWidth = 260.0;

/// How wide it is when it shows its icons alone.
///
/// A row's icon plus the rail's own inset on both sides — wide enough that a
/// glyph is not clipped and narrow enough to be worth collapsing for. Wider
/// than the icon strictly needs: at 64 the rows sat hard against both edges,
/// and a touch target that reaches the window edge is one a drag on the frame
/// competes with.
const railCollapsedWidth = 80.0;

/// Whether the connections rail is showing its icons alone.
///
/// A provider rather than state inside the shell because two widgets need it:
/// the shell decides how wide the rail's column is, and the rail itself decides
/// what goes in it. Not persisted — a collapsed rail is a thing done to make
/// room for the query in front of you, not a preference.
final railCollapsedProvider = StateProvider<bool>((ref) => false);
