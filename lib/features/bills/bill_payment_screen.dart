import 'package:flutter/material.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/detail_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

class BillPackage {
  const BillPackage(this.label, this.price);
  final String label;
  final String price;
}

/// One shared screen for every "provider + account ID + amount-or-plan"
/// bill flow (Electricity, Internet, Betting, Education use free-amount;
/// Cable TV uses fixed packages) — configured per bill type rather than
/// duplicated, the same way Airtime/Data already work.
class BillPaymentScreen extends StatefulWidget {
  const BillPaymentScreen({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.providers,
    required this.idLabel,
    required this.idHint,
    this.packages,
    this.payLabel = 'Pay bill',
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> providers;
  final String idLabel;
  final String idHint;
  final List<BillPackage>? packages;
  final String payLabel;

  @override
  State<BillPaymentScreen> createState() => _BillPaymentScreenState();
}

class _BillPaymentScreenState extends State<BillPaymentScreen> {
  int _provider = 0;
  int? _package;
  final _idController = TextEditingController();
  final _amountController = TextEditingController();

  @override
  void dispose() {
    _idController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  bool get _canPay {
    if (_idController.text.trim().isEmpty) return false;
    if (widget.packages != null) return _package != null;
    return _amountController.text.trim().isNotEmpty;
  }

  void _pay() {
    final amount = widget.packages != null
        ? widget.packages![_package!].price
        : '₦${_amountController.text.trim()}';
    showAppModal(
      context,
      icon: AppIcons.check,
      iconColor: AppColors.gain,
      title: 'Payment successful',
      message:
          '$amount paid to ${widget.providers[_provider]} for ${_idController.text.trim()}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          children: [
            DetailHeader(
                icon: widget.icon,
                title: widget.title,
                subtitle: widget.subtitle),
            const SizedBox(height: 22),
            Text('Provider', style: AppText.sectionTitle),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (int i = 0; i < widget.providers.length; i++)
                  _Chip(
                      label: widget.providers[i],
                      selected: i == _provider,
                      onTap: () => setState(() => _provider = i)),
              ],
            ),
            const SizedBox(height: 22),
            Text(widget.idLabel, style: AppText.sectionTitle),
            const SizedBox(height: 10),
            TextField(
              controller: _idController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: widget.idHint),
            ),
            const SizedBox(height: 22),
            if (widget.packages != null) ...[
              Text('Choose a package', style: AppText.sectionTitle),
              const SizedBox(height: 10),
              for (int i = 0; i < widget.packages!.length; i++)
                _PackageRow(
                    package: widget.packages![i],
                    selected: i == _package,
                    onTap: () => setState(() => _package = i)),
            ] else ...[
              Text('Amount', style: AppText.sectionTitle),
              const SizedBox(height: 10),
              TextField(
                controller: _amountController,
                onChanged: (_) => setState(() {}),
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(hintText: '0.00', prefixText: '₦'),
              ),
            ],
            const SizedBox(height: 28),
            PrimaryButton(
                label: widget.payLabel, onPressed: _canPay ? _pay : null),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.accent : AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _PackageRow extends StatelessWidget {
  const _PackageRow(
      {required this.package, required this.selected, required this.onTap});

  final BillPackage package;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(child: Text(package.label, style: AppText.body)),
            Text(package.price,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color:
                        selected ? AppColors.accent : AppColors.textPrimary)),
            const SizedBox(width: 10),
            Icon(selected ? AppIcons.check : AppIcons.chevronRight,
                size: 16, color: selected ? AppColors.accent : AppColors.muted),
          ],
        ),
      ),
    );
  }
}
