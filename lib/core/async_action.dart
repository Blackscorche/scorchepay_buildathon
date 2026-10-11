import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks one user-triggered async action on a screen (submit, verify,
/// log in...) as an [AsyncValue], instead of separate busy/error fields.
///
/// ```dart
/// final result = await runAction(() => backend.doThing());
/// if (!mounted || !result.hasValue) return; // failed: shown via actionError
/// ```
mixin AsyncActionMixin<T extends StatefulWidget> on State<T> {
  /// Idle (`AsyncData`), running (`AsyncLoading`) or failed (`AsyncError`).
  AsyncValue<void> actionStatus = const AsyncData(null);

  bool get actionRunning => actionStatus.isLoading;

  /// The last failure's message, for display; null when there is none.
  String? get actionError =>
      actionStatus.hasError ? actionStatus.error.toString() : null;

  /// Runs [action] unless one is already running, tracking it in
  /// [actionStatus]. Exceptions are caught (by [AsyncValue.guard]) and
  /// become [actionError]. The result is returned even if the screen has
  /// gone away meanwhile, so callers that captured what they need (e.g. a
  /// ScaffoldMessenger) can still use it; check `mounted` before using
  /// `context` or `setState`.
  Future<AsyncValue<R>> runAction<R>(Future<R> Function() action) async {
    // Not const: R is a type parameter.
    if (actionRunning) return AsyncLoading<R>();
    setState(() => actionStatus = const AsyncLoading());
    final result = await AsyncValue.guard(action);
    if (mounted) {
      setState(() => actionStatus = result.hasError
          ? AsyncError<void>(result.error!, result.stackTrace!)
          : const AsyncData(null));
    }
    return result;
  }

  /// Clears a shown error, e.g. when the user edits the input.
  void clearActionError() {
    if (actionStatus.hasError) {
      setState(() => actionStatus = const AsyncData(null));
    }
  }
}
