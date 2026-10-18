import 'package:intl/intl.dart';

/// 1234567 -> "1,234,567", grouped for the device's locale.
String groupDigits(int value) => NumberFormat.decimalPattern().format(value);

/// 1500 sats -> "1,500 sats".
String formatSats(int sats) => '${groupDigits(sats)} sats';

/// A whole fiat amount with its currency symbol: (1500, 'NGN') -> "₦1,500".
String formatFiat(int amount, String currency) =>
    '${currencySymbol(currency)}${groupDigits(amount)}';

/// A fiat amount with two decimals: (1234.5, 'USD') -> "$1,234.50".
String formatFiatDecimal(double amount, String currency) =>
    NumberFormat.currency(symbol: currencySymbol(currency), decimalDigits: 2)
        .format(amount);

/// 'NGN' -> '₦'; unknown currencies fall back to their code.
String currencySymbol(String currency) => _symbols[currency] ?? '$currency ';

const _symbols = {'NGN': '₦', 'GHS': 'GH₵', 'KES': 'KSh ', 'USD': '\$'};
