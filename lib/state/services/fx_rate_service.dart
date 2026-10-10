import 'dart:convert';
import 'package:http/http.dart' as http;

/// Live fiat FX rates, free and keyless — the currency-side equivalent
/// of [CoinGeckoService]. `open.er-api.com` is a community-run mirror
/// of ECB-adjacent rates that (unlike Frankfurter, which only covers
/// ~30 major currencies) actually includes NGN and GHS, which is the
/// whole point for a Nigeria-first app.
class FxRateService {
  FxRateService._();

  static Map<String, double>? _cache;
  static DateTime? _cachedAt;

  /// Every rate as "1 unit of [code] in NGN" — the same shape
  /// [LocalAppState.fxRatesToNgn] already expects, so this is a drop-in
  /// refresh rather than a schema change.
  static Future<Map<String, double>> getRatesToNgn() async {
    final cached = _cache;
    final cachedAt = _cachedAt;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < const Duration(hours: 1)) {
      return cached;
    }
    final rates = await fetchRatesToNgn();
    _cache = rates;
    _cachedAt = DateTime.now();
    return rates;
  }

  static Future<Map<String, double>> fetchRatesToNgn() async {
    final uri = Uri.parse('https://open.er-api.com/v6/latest/NGN');
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('FX rate API returned ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['result'] != 'success') {
      throw Exception('FX rate API result: ${json['result']}');
    }
    final rates = (json['rates'] as Map<String, dynamic>);
    final out = <String, double>{'NGN': 1.0};
    for (final entry in rates.entries) {
      final perNgn = (entry.value as num).toDouble();
      if (perNgn <= 0) continue;
      out[entry.key] = 1 / perNgn; // invert: NGN-per-1-unit-of-code
    }
    return out;
  }
}
