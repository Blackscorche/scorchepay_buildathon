import 'dart:typed_data';

/// Details collected across the sign-up screens (details -> OTP -> PIN ->
/// profile -> biometric prompt). Nothing is sent to create the account
/// until the last screen, so each screen passes an updated copy along.
class SignUpDraft {
  const SignUpDraft({
    required this.displayName,
    required this.contact,
    required this.verificationId,
    this.signUpToken,
    this.pin,
    this.username,
    this.photo,
  });

  final String displayName;

  /// Phone number or email, as entered.
  final String contact;

  /// Identifies the OTP challenge sent to [contact] (for verify / resend).
  final String verificationId;

  /// Proof from the backend that [contact] was verified. Set by the OTP
  /// screen.
  final String? signUpToken;

  final String? pin;
  final String? username;

  /// Profile photo (image file contents), uploaded once the account
  /// exists. The backend works out the image type.
  final Uint8List? photo;

  SignUpDraft copyWith({
    String? displayName,
    String? verificationId,
    String? signUpToken,
    String? pin,
    String? username,
    Uint8List? photo,
    bool clearPhoto = false,
  }) =>
      SignUpDraft(
        displayName: displayName ?? this.displayName,
        contact: contact,
        verificationId: verificationId ?? this.verificationId,
        signUpToken: signUpToken ?? this.signUpToken,
        pin: pin ?? this.pin,
        username: username ?? this.username,
        photo: clearPhoto ? null : (photo ?? this.photo),
      );
}
