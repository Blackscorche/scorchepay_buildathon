/// Stands in for the Lightning network between the mock wallets
/// (`MockWalletService`) and the mock VTU backend (`MockVtuApi`): the
/// backend issues invoices here and a mock wallet "pays" them, which the
/// backend sees as a settled payment. Nothing leaves the device.
class MockLightning {
  MockLightning._();

  static final _invoices = <String, DateTime>{};
  static final _listeners = <void Function(String invoice)>{};

  /// Registers an invoice the mock backend issued, payable until
  /// [expiresAt].
  static void issue(String invoice, DateTime expiresAt) =>
      _invoices[invoice] = expiresAt;

  static void addListener(void Function(String invoice) listener) =>
      _listeners.add(listener);

  static void removeListener(void Function(String invoice) listener) =>
      _listeners.remove(listener);

  /// Settles [invoice]. Throws [StateError] if it has expired, like a real
  /// wallet refusing an expired invoice. Invoices this run didn't issue
  /// (e.g. after a restart) are accepted.
  static void pay(String invoice) {
    final expiresAt = _invoices[invoice];
    if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
      throw StateError('Invoice expired');
    }
    for (final listener in List.of(_listeners)) {
      listener(invoice);
    }
  }

  /// The amount a BOLT11 invoice asks for, in sats (rounded up), or null
  /// if it has none or isn't one.
  static int? invoiceSats(String invoice) {
    final match = RegExp(r'^ln[a-z]+?(\d+)([munp])?1')
        .firstMatch(invoice.trim().toLowerCase());
    if (match == null) return null;
    final value = int.parse(match.group(1)!);
    // Amounts are in BTC with an optional multiplier; 1 BTC = 1e8 sats.
    final satsPerUnit = switch (match.group(2)) {
      'm' => 1e5,
      'u' => 1e2,
      'n' => 1e-1,
      'p' => 1e-4,
      _ => 1e8,
    };
    return (value * satsPerUnit).ceil();
  }

  /// A BOLT11-shaped (but unpayable on a real network) signet invoice for
  /// [sats], so QR codes, copy buttons and parsing all work.
  static String fakeInvoice(int sats, int seed) {
    const charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
    var x = seed & 0x7fffffff;
    final data = StringBuffer();
    for (var i = 0; i < 180; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      data.write(charset[x % charset.length]);
    }
    return 'lntbs${sats * 10}n1$data';
  }
}
