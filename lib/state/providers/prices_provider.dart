import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/coingecko_service.dart';
import 'app_state_notifier.dart';

/// Live price of 1 BTC in the user's preferred currency. Errors (offline,
/// rate-limited) are left to callers, which can simply show sats alone.
final btcPriceProvider = FutureProvider.autoDispose<double>((ref) {
  final currency = ref.watch(appStateProvider
      .select((s) => s.valueOrNull?.localState.preferredCurrency ?? 'NGN'));
  return CoinGeckoService.getBtcPrice(currency);
});
