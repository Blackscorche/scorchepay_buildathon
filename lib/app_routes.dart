/// go_router paths for the top-level screens (see `app_router.dart`).
/// Screens that need data passed in (OTP contact, PIN confirmation) are
/// pushed directly with MaterialPageRoute from within the flow instead —
/// see e.g. SignUpScreen -> OtpVerificationScreen, CreatePinScreen ->
/// ConfirmPinScreen.
class AppRoutes {
  AppRoutes._();

  static const onboarding = '/onboarding';
  static const welcome = '/welcome';
  // Nested under welcome, so opening either keeps Welcome underneath
  // (back goes to Welcome).
  static const signup = '/welcome/signup';
  static const login = '/welcome/login';
  static const home = '/home';
}
