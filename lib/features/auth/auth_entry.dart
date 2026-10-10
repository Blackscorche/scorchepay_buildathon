import 'package:flutter/widgets.dart';

import '../../app_routes.dart';

/// Resets the stack to the signed-out entry point.
///
/// Returning users (anyone who has logged in on this device before) skip
/// past Welcome straight to Login — but Welcome is kept underneath, so
/// Login's back button (and the system back gesture) still reaches it to
/// create a new account instead.
void openAuthEntry(NavigatorState navigator, {required bool returningUser}) {
  navigator.pushNamedAndRemoveUntil(AppRoutes.welcome, (_) => false);
  if (returningUser) navigator.pushNamed(AppRoutes.login);
}
