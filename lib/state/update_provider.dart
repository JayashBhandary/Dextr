import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/logger.dart';
import '../services/update_service.dart';

final updateServiceProvider = Provider<UpdateService>((ref) {
  final service = UpdateService();
  ref.onDispose(service.dispose);
  return service;
});

/// The outcome of the last update check.
///
/// `data(null)` is "nobody has asked yet", which is a third state the page has to
/// draw differently from "up to date": a check that has not run is not a result,
/// and saying so is not the same as saying nothing was found.
class UpdateNotifier extends StateNotifier<AsyncValue<UpdateCheck?>> {
  UpdateNotifier(this._ref) : super(const AsyncValue<UpdateCheck?>.data(null));

  final Ref _ref;

  /// Asks the release feed, once. A second press while one is in flight is
  /// ignored rather than queued.
  Future<void> check() async {
    if (state.isLoading) return;
    state = const AsyncValue<UpdateCheck?>.loading();
    try {
      final result = await _ref.read(updateServiceProvider).check();
      state = AsyncValue<UpdateCheck?>.data(result);
    } on UpdateException catch (e, st) {
      // Already phrased for a reader — passed through as it is.
      state = AsyncValue<UpdateCheck?>.error(e, st);
    } catch (e, st) {
      // Anything else is a bug rather than a network fact, so the user gets one
      // sentence and the detail goes to the log.
      log.e('Update check failed', error: e, stackTrace: st);
      state = AsyncValue<UpdateCheck?>.error(
        const UpdateException(
          'Something went wrong checking for updates. The log has the detail.',
        ),
        st,
      );
    }
  }
}

final updateProvider =
    StateNotifierProvider<UpdateNotifier, AsyncValue<UpdateCheck?>>(
      UpdateNotifier.new,
    );
