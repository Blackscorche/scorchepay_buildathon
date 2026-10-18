import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/kyc_status_badge.dart';
import '../../core/widgets/section_title.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/providers/profile_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../vtu/vtu_section.dart';
import '../wallet/wallet_section.dart';

/// The entire app, trimmed to one screen: VTU/bill payments (airtime,
/// data, electricity, TV), the user's connected Lightning wallets and
/// their recent orders. No send money, escrow, savings, P2P,
/// gift cards, merchant/admin tooling or server-backed "live" mode —
/// this branch intentionally doesn't have those pages at all.
class VtuDashboardScreen extends ConsumerStatefulWidget {
  const VtuDashboardScreen({super.key});

  @override
  ConsumerState<VtuDashboardScreen> createState() => _VtuDashboardScreenState();
}

class _VtuDashboardScreenState extends ConsumerState<VtuDashboardScreen> {
  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need your PIN to log back in.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      // ScorchePayApp navigates to the signed-out entry point.
      await ref.read(appStateProvider.notifier).logout();
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not log out. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(userProfileProvider);
    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          profile.displayName.isEmpty
                              ? 'Hello'
                              : 'Hello, ${profile.displayName}',
                          style: AppText.pageTitle),
                      const SizedBox(height: 2),
                      Text('Top up and check your crypto balance',
                          style: AppText.bodyMuted),
                      const SizedBox(height: 8),
                      KycStatusBadge(kyc: profile.kyc),
                    ],
                  ),
                ),
                IconCircleButton(icon: AppIcons.logout, onTap: _logout),
              ],
            ),
            const VtuSection(),
            const SectionTitle('Wallet'),
            const WalletSection(),
            const RecentOrdersSection(),
          ],
        ),
      ),
    );
  }
}
