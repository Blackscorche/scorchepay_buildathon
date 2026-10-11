/// Where the user is in identity verification, as the backend reports it.
/// The app never decides this itself — it only displays it.
enum KycStatus {
  /// No verification started. Every account starts here, at tier 0.
  unverified,

  /// Verification started with the provider (Mono myPass); waiting on
  /// its result.
  pending,

  verified,
  rejected;

  String get label => switch (this) {
        KycStatus.unverified => 'Unverified',
        KycStatus.pending => 'Verification pending',
        KycStatus.verified => 'Verified',
        KycStatus.rejected => 'Verification failed',
      };

  /// Unknown or missing values read as [unverified], so a newer backend
  /// status never breaks an older app.
  static KycStatus fromJson(Object? value) => KycStatus.values
      .firstWhere((s) => s.name == value, orElse: () => KycStatus.unverified);
}

/// The user's KYC tier and status. Backend-derived: limits are set per
/// tier on the backend, and tier goes up only after verification.
class KycInfo {
  const KycInfo({required this.tier, required this.status});

  /// Where every new account starts.
  const KycInfo.initial()
      : tier = 0,
        status = KycStatus.unverified;

  final int tier;
  final KycStatus status;

  String get tierLabel => 'Tier $tier';

  Map<String, dynamic> toJson() => {'tier': tier, 'status': status.name};

  factory KycInfo.fromJson(Map<String, dynamic> json) => KycInfo(
        tier: (json['tier'] as num?)?.toInt() ?? 0,
        status: KycStatus.fromJson(json['status']),
      );

  @override
  bool operator ==(Object other) =>
      other is KycInfo && other.tier == tier && other.status == status;

  @override
  int get hashCode => Object.hash(tier, status);
}
