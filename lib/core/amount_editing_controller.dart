import 'package:flutter/widgets.dart';

import 'formatters.dart';

/// A [TextEditingController] for whole money amounts: it keeps only
/// digits, groups them as the user types ("12500" shows "12,500"), keeps
/// the cursor beside the digit it was next to, and exposes the value as
/// [amount].
class AmountEditingController extends TextEditingController {
  AmountEditingController({int? amount})
      : super(text: amount == null ? '' : groupDigits(amount));

  /// Longest amount accepted, so the value always fits in an int.
  static const _maxDigits = 15;
  static final _nonDigits = RegExp(r'\D');

  /// The typed amount, or null when empty.
  int? get amount {
    final digits = text.replaceAll(_nonDigits, '');
    return digits.isEmpty ? null : int.parse(digits);
  }

  set amount(int? newAmount) {
    final formatted = newAmount == null ? '' : groupDigits(newAmount);
    value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  @override
  set value(TextEditingValue newValue) {
    var digits = newValue.text.replaceAll(_nonDigits, '');
    if (digits.length > _maxDigits) digits = digits.substring(0, _maxDigits);
    final formatted = digits.isEmpty ? '' : groupDigits(int.parse(digits));
    if (formatted == newValue.text) {
      super.value = newValue;
      return;
    }

    // Keep the same number of digits to the cursor's right.
    final cursor = newValue.selection.isValid
        ? newValue.selection.extentOffset.clamp(0, newValue.text.length)
        : newValue.text.length;
    final digitsAfter =
        newValue.text.substring(cursor).replaceAll(_nonDigits, '').length;
    var offset = formatted.length;
    for (var seen = 0; offset > 0 && seen < digitsAfter; offset--) {
      if (!_nonDigits.hasMatch(formatted[offset - 1])) seen++;
    }
    super.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
