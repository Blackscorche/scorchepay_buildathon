import 'package:flutter/material.dart';

import '../../state/models/kyc.dart';
import 'status_badge.dart';

/// Pill showing the user's KYC tier and status, e.g. "Tier 0 · Unverified".
/// Use it wherever user details are shown. The values come from the
/// backend (see `kycProvider` / `UserProfile.kyc`).
class KycStatusBadge extends StatelessWidget {
  const KycStatusBadge({super.key, required this.kyc});

  final KycInfo kyc;

  @override
  Widget build(BuildContext context) {
    return StatusBadge(
      label: '${kyc.tierLabel} · ${kyc.status.label}',
      tone: switch (kyc.status) {
        KycStatus.unverified => BadgeTone.neutral,
        KycStatus.pending => BadgeTone.info,
        KycStatus.verified => BadgeTone.good,
        KycStatus.rejected => BadgeTone.crit,
      },
    );
  }
}
