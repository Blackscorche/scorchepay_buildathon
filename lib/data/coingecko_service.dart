import 'dart:convert';
import 'package:http/http.dart' as http;
import '../theme/app_colors.dart';
import 'models.dart';

/// Live price + 24h change + logo for one coin, keyed by its uppercase
/// symbol.
class CoinGeckoPrice {
  const CoinGeckoPrice(
      {required this.price, required this.changePct, this.logoUrl});
  final double price;
  final double changePct;
  final String? logoUrl;
}

/// Thin client for CoinGecko's free, no-key `/coins/markets` endpoint —
/// used to replace the app's static mock crypto prices with real ones.
class CoinGeckoService {
  CoinGeckoService._();

  static const _ids = 'bitcoin,ethereum,tether,solana,binancecoin';

  static Map<String, CoinGeckoPrice>? _cache;
  static DateTime? _cachedAt;

  /// Cached for 30s so pushing Buy/Sell/Swap right after the Crypto tab
  /// doesn't fire a second request against the free, rate-limited API.
  static Future<Map<String, CoinGeckoPrice>> getPrices() async {
    final cached = _cache;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 30)) {
      return cached;
    }
    final prices = await fetchPrices();
    _cache = prices;
    _cachedAt = DateTime.now();
    return prices;
  }

  static Future<Map<String, CoinGeckoPrice>> fetchPrices() async {
    final uri = Uri.parse(
      'https://api.coingecko.com/api/v3/coins/markets'
      '?vs_currency=usd&ids=$_ids&price_change_percentage=24h',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('CoinGecko returned ${response.statusCode}');
    }
    final list = jsonDecode(response.body) as List;
    return {
      for (final item in list.cast<Map<String, dynamic>>())
        (item['symbol'] as String).toUpperCase(): CoinGeckoPrice(
          price: (item['current_price'] as num).toDouble(),
          changePct:
              (item['price_change_percentage_24h'] as num?)?.toDouble() ?? 0,
          logoUrl: item['image'] as String?,
        ),
    };
  }

  static final _btcPriceCache = <String, (double, DateTime)>{};

  /// Live BTC price in [currency] (e.g. `NGN`), straight from CoinGecko
  /// rather than converted through USD. Cached for 30s per currency.
  static Future<double> getBtcPrice(String currency) async {
    final code = currency.toLowerCase();
    final cached = _btcPriceCache[code];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(seconds: 30)) {
      return cached.$1;
    }
    final uri = Uri.parse('https://api.coingecko.com/api/v3/simple/price'
        '?ids=bitcoin&vs_currencies=$code');
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('CoinGecko returned ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final price = ((json['bitcoin'] as Map?)?[code] as num?)?.toDouble();
    if (price == null) throw Exception('No BTC price in $currency');
    _btcPriceCache[code] = (price, DateTime.now());
    return price;
  }

  static List<CryptoAsset>? _marketCache;
  static DateTime? _marketCachedAt;

  /// The broader coin universe — top N coins by market cap, each with a
  /// live price and 24h change, for search/browse (as opposed to
  /// [getPrices], which only covers the handful of assets the user
  /// already holds). Cached for 60s.
  static Future<List<CryptoAsset>> getMarket({int perPage = 100}) async {
    final cached = _marketCache;
    final cachedAt = _marketCachedAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 60)) {
      return cached;
    }
    final market = await fetchMarket(perPage: perPage);
    _marketCache = market;
    _marketCachedAt = DateTime.now();
    return market;
  }

  static Future<List<CryptoAsset>> fetchMarket({int perPage = 100}) async {
    final uri = Uri.parse(
      'https://api.coingecko.com/api/v3/coins/markets'
      '?vs_currency=usd&order=market_cap_desc&per_page=$perPage&page=1&price_change_percentage=24h',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('CoinGecko returned ${response.statusCode}');
    }
    final list = jsonDecode(response.body) as List;
    return [
      for (final item in list.cast<Map<String, dynamic>>())
        CryptoAsset(
          symbol: (item['symbol'] as String).toUpperCase(),
          name: item['name'] as String,
          glyph: (item['symbol'] as String).substring(0, 1).toUpperCase(),
          price: (item['current_price'] as num?)?.toDouble() ?? 0,
          changePct:
              (item['price_change_percentage_24h'] as num?)?.toDouble() ?? 0,
          holding: '0',
          color: AppColors.categorical[
              (item['symbol'] as String).hashCode.abs() %
                  AppColors.categorical.length],
          logoUrl: item['image'] as String?,
        ),
    ];
  }
}
