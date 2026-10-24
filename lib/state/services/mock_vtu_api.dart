import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/formatters.dart';
import '../models/vtu.dart';
import '../models/kyc.dart';
import 'backend_service.dart';
import 'mock_lightning.dart';
import 'vtu_api.dart';
import 'shared_prefs_keys.dart';

/// How [MockVtuApi] behaves, switchable from the debug menu.
enum MockScenario {
  success('Success', 'Orders are paid and fulfilled.'),
  billFails('Bill fails', 'Payment works, the provider fails, refund offered.'),
  quoteExpires('Quote expires fast', 'Quotes last 20 seconds instead of 2 minutes.'),
  serverDown('Server down', 'Every request fails as if offline.');

  const MockScenario(this.label, this.description);
  final String label;
  final String description;
}

/// [VtuApi] on the device, following the contract in docs/VTU.md, with a
/// Nigerian catalog and orders that move through their states on a clock:
/// a mock wallet's payment ([MockLightning]) marks an order paid, and it
/// completes (or, in [MockScenario.billFails], becomes refundable) a few
/// seconds later. Orders persist in shared preferences, so they survive a
/// restart.
class MockVtuApi implements VtuApi {
  MockVtuApi(
      {required BackendService backend,
      required String? token,
      required this.scenario})
      : _backend = backend,
        _token = token {
    MockLightning.addListener(_onPayment);
  }

  final BackendService _backend;

  /// The signed-in user's session; null while signed out.
  final String? _token;
  final MockScenario scenario;

  /// Prices and limits are in naira (the only catalog so far).
  static const _currency = 'NGN';

  static const _latency = Duration(milliseconds: 400);

  /// NGN per BTC before the spread. Real quotes come from the rates service.
  static const _ngnPerBtc = 165000000.0;
  static const _spread = 0.015;

  final _random = Random();
  Future<Map<String, _MockOrder>>? _orders;

  void dispose() => MockLightning.removeListener(_onPayment);

  /// Debug only: settles [orderId]'s invoice as if a wallet paid it, for
  /// testing with a real wallet that can't pay a mock invoice.
  Future<void> simulatePayment(String orderId) async {
    final order = (await _db())[orderId];
    if (order != null) MockLightning.pay(order.base.invoice);
  }

  // -------------------------------------------------------------------
  // VtuApi
  // -------------------------------------------------------------------

  @override
  Future<Catalog> getCatalog({String country = 'NG'}) async {
    await _request();
    if (country != 'NG') {
      throw const VtuException(
          VtuErrorCode.notFound, "ScorchePay isn't available there yet.");
    }
    return Catalog.fromJson(_nigeriaCatalog);
  }

  @override
  Future<VtuLimits> getLimits() async {
    await _request();
    final account = await _account();
    return _limits(account.kyc.tier, await _usedToday(account.accountId));
  }

  @override
  Future<CustomerInfo> validateCustomer(
      {required String billerId,
      required String target,
      String? optionId}) async {
    await _request();
    await _account();
    final biller = _biller(billerId);
    final number = TargetField.normalize(target);
    if (!biller.target.isValid(number)) {
      throw VtuException(VtuErrorCode.invalidTarget, biller.target.errorText);
    }
    // Numbers ending in 0000 don't exist, for testing the error.
    if (number.endsWith('0000')) {
      throw VtuException(VtuErrorCode.customerNotFound,
          "We couldn't find a customer with that ${biller.target.label.toLowerCase()}. Check it and try again.");
    }
    final seed = number.codeUnits.fold<int>(0, (a, b) => a * 31 + b);
    return CustomerInfo(
      name: _customerNames[seed.abs() % _customerNames.length],
      address: biller.category == BillCategory.electricity
          ? _addresses[seed.abs() % _addresses.length]
          : null,
    );
  }

  @override
  Future<VtuOrder> createOrder(OrderRequest request) async {
    await _request();
    final account = await _account();
    final order = _MockOrder(
      accountId: account.accountId,
      willFail: scenario == MockScenario.billFails,
      base: await _quote(account, request, orderId: _newId()),
    );
    (await _db())[order.base.id] = order;
    await _save();
    return order.resolve(DateTime.now());
  }

  @override
  Future<VtuOrder> requote(String orderId, {OrderRequest? request}) async {
    await _request();
    final account = await _account();
    final order = await _ownOrder(orderId);
    final status = order.resolve(DateTime.now()).status;
    if (status != OrderStatus.awaitingPayment &&
        status != OrderStatus.expired) {
      throw const VtuException(
          VtuErrorCode.alreadyPaid, 'This order has already been paid.');
    }
    final quote = await _quote(account, request ?? order.base.request,
        orderId: order.base.id);
    // The old invoice may have been paid while this was pricing.
    if (order.paidAt != null) {
      MockLightning.cancel(quote.invoice);
      throw const VtuException(
          VtuErrorCode.alreadyPaid, 'This order has already been paid.');
    }
    // Retire the old invoice, so the order can't be paid twice.
    MockLightning.cancel(order.base.invoice);
    order
      ..base = quote
      ..willFail = scenario == MockScenario.billFails;
    await _save();
    return order.resolve(DateTime.now());
  }

  /// Validates [request], checks it against the user's limits (leaving
  /// out [orderId]'s own current quote, when requoting) and prices it
  /// with a fresh invoice, as order [orderId] awaiting payment.
  Future<VtuOrder> _quote(
      ({String accountId, KycInfo kyc}) account, OrderRequest request,
      {required String orderId}) async {
    final biller = _biller(request.billerId);
    if (!biller.available) {
      throw VtuException(VtuErrorCode.billerUnavailable,
          '${biller.name} is unavailable right now. Try again later.');
    }
    final target = TargetField.normalize(request.target);
    if (!biller.target.isValid(target)) {
      throw VtuException(VtuErrorCode.invalidTarget, biller.target.errorText);
    }

    final (amount, plan) = switch (biller.pricing) {
      final PlanPricing pricing => _planPrice(pricing, request.planId),
      final AmountPricing pricing => _freePrice(pricing, request.amount),
    };
    final options = biller.options;
    final option = options?.find(request.optionId);
    if (options != null && option == null) {
      throw VtuException(VtuErrorCode.unknown,
          'Choose a ${options.label.toLowerCase()} to continue.');
    }

    final limits = _limits(account.kyc.tier,
        await _usedToday(account.accountId, excluding: orderId));
    if (amount > limits.maxOrder) {
      final daily = amount > limits.remainingToday && amount <= limits.perOrder;
      throw VtuException(
          VtuErrorCode.overLimit,
          daily
              ? "This is over what's left of your daily limit (${formatFiat(limits.remainingToday, limits.currency)})."
              : 'This is over your ${formatFiat(limits.perOrder, limits.currency)} limit per order.');
    }

    final customer = biller.customerCheck
        ? await validateCustomer(
            billerId: biller.id, target: target, optionId: option?.id)
        : null;

    final now = DateTime.now();
    final sats = (amount / _ngnPerBtc * 1e8 * (1 + _spread)).ceil();
    final expiresAt = now.add(scenario == MockScenario.quoteExpires
        ? const Duration(seconds: 20)
        : const Duration(minutes: 2));
    final invoice = MockLightning.fakeInvoice(sats, _random.nextInt(1 << 30));
    MockLightning.issue(invoice, expiresAt);

    return VtuOrder(
      id: orderId,
      title: _orderTitle(biller, plan: plan, option: option),
      status: OrderStatus.awaitingPayment,
      category: biller.category,
      billerId: biller.id,
      billerName: biller.name,
      target: target,
      amount: amount,
      currency: _currency,
      sats: sats,
      rate: amount / sats * 1e8,
      invoice: invoice,
      createdAt: now,
      expiresAt: expiresAt,
      request: OrderRequest(
        billerId: biller.id,
        target: target,
        optionId: option?.id,
        planId: plan?.id,
        amount: plan == null ? amount : null,
      ),
      planName: plan?.name,
      optionName: option?.name,
      customerName: customer?.name,
    );
  }

  @override
  Future<VtuOrder> getOrder(String orderId) async {
    await _request();
    final order = await _ownOrder(orderId);
    return order.resolve(DateTime.now());
  }

  @override
  Future<List<VtuOrder>> listOrders({int limit = 20}) async {
    await _request();
    final account = await _account();
    final now = DateTime.now();
    final own = (await _db())
        .values
        .where((o) => o.accountId == account.accountId)
        .map((o) => o.resolve(now))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return own.take(limit).toList();
  }

  @override
  Future<VtuOrder> requestRefund(String orderId,
      {required String invoice}) async {
    await _request();
    final order = await _ownOrder(orderId);
    final now = DateTime.now();
    if (order.resolve(now).status != OrderStatus.refundable ||
        order.refundRequestedAt != null) {
      throw const VtuException(
          VtuErrorCode.unknown, "This order can't be refunded.");
    }
    final value = invoice.trim().toLowerCase().replaceFirst('lightning:', '');
    final sats = MockLightning.invoiceSats(value);
    if (!value.startsWith('ln') || sats == null) {
      throw const VtuException(VtuErrorCode.invalidInvoice,
          "That isn't a Lightning invoice with an amount. Create one in your wallet and paste it here.");
    }
    if (sats != order.base.sats) {
      throw VtuException(VtuErrorCode.invalidInvoice,
          'The invoice must be for exactly ${formatSats(order.base.sats)}; this one is for ${formatSats(sats)}.');
    }
    order.refundRequestedAt = now;
    await _save();
    return order.resolve(now);
  }

  // -------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------

  /// The signed-in account, as the backend resolves the session.
  Future<({String accountId, KycInfo kyc})> _account() {
    final token = _token;
    if (token == null) {
      throw const VtuException(
          VtuErrorCode.signedOut, 'Your session has ended. Log in again.');
    }
    return _backend.accountSummary(token);
  }

  Future<void> _request() async {
    await Future.delayed(_latency);
    if (scenario == MockScenario.serverDown) {
      throw const VtuException(VtuErrorCode.network,
          "Can't reach ScorchePay. Check your connection and try again.");
    }
  }

  Future<void> _onPayment(String invoice) async {
    final orders = await _db();
    final now = DateTime.now();
    for (final order in orders.values) {
      if (order.base.invoice == invoice &&
          order.paidAt == null &&
          now.isBefore(order.base.expiresAt)) {
        order.paidAt = now;
        await _save();
      }
    }
  }

  Future<_MockOrder> _ownOrder(String orderId) async {
    final account = await _account();
    final order = (await _db())[orderId];
    if (order == null || order.accountId != account.accountId) {
      throw const VtuException(VtuErrorCode.notFound, 'Order not found.');
    }
    return order;
  }

  Biller _biller(String id) {
    final json = (_nigeriaCatalog['billers'] as List)
        .cast<Map<String, dynamic>>()
        .where((b) => b['id'] == id)
        .firstOrNull;
    if (json == null) {
      throw const VtuException(VtuErrorCode.notFound, 'Unknown biller.');
    }
    return Biller.fromJson(json);
  }

  static (int, BillPlan) _planPrice(PlanPricing pricing, String? planId) {
    final plan = pricing.find(planId);
    if (plan == null) {
      throw const VtuException(
          VtuErrorCode.unknown, 'Choose a plan to continue.');
    }
    return (plan.amount, plan);
  }

  static (int, BillPlan?) _freePrice(AmountPricing pricing, int? amount) {
    if (amount == null || !pricing.allows(amount)) {
      final AmountPricing(:min, :max) = pricing;
      throw VtuException(
          VtuErrorCode.unknown,
          switch ((min, max)) {
            (final min?, final max?) =>
              'Enter an amount from ${formatFiat(min, _currency)} to ${formatFiat(max, _currency)}.',
            (final min?, null) =>
              'Enter at least ${formatFiat(min, _currency)}.',
            (null, final max?) =>
              'Enter up to ${formatFiat(max, _currency)}.',
            (null, null) => 'Enter an amount.',
          });
    }
    return (amount, null);
  }

  /// How the backend names an order, per category.
  static String _orderTitle(Biller biller,
          {BillPlan? plan, BillerChoice? option}) =>
      switch (biller.category) {
        BillCategory.airtime => '${biller.name} airtime',
        BillCategory.data => '${biller.name} ${plan?.name ?? 'data'}',
        BillCategory.electricity =>
          option == null ? biller.name : '${biller.name} (${option.name})',
        BillCategory.tv =>
          plan == null ? biller.name : '${biller.name} ${plan.name}',
      };

  static VtuLimits _limits(int tier, int usedToday) => tier >= 1
      ? VtuLimits(
          currency: _currency,
          tier: tier,
          perOrder: 200000,
          daily: 1000000,
          usedToday: usedToday)
      : VtuLimits(
          currency: _currency,
          tier: 0,
          perOrder: 10000,
          daily: 30000,
          usedToday: usedToday,
          nextTier: const VtuLimits(
              currency: _currency,
              tier: 1,
              perOrder: 200000,
              daily: 1000000,
              usedToday: 0),
        );

  /// Today's spend: paid orders, plus unexpired quotes (they hold the
  /// limit until they expire). Failed and refunded ones don't count.
  Future<int> _usedToday(String accountId, {String? excluding}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var total = 0;
    for (final order in (await _db()).values) {
      if (order.accountId != accountId ||
          order.base.id == excluding ||
          order.base.createdAt.isBefore(today)) {
        continue;
      }
      final status = order.resolve(now).status;
      if (status == OrderStatus.expired ||
          status == OrderStatus.refundable ||
          status == OrderStatus.refunded) {
        continue;
      }
      total += order.base.amount;
    }
    return total;
  }

  String _newId() => List.generate(
      12, (_) => 'abcdefghjkmnpqrstuvwxyz23456789'[_random.nextInt(31)]).join();

  Future<Map<String, _MockOrder>> _db() => _orders ??= _load();

  Future<Map<String, _MockOrder>> _load() async {
    final orders = <String, _MockOrder>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SharedPrefsKeys.mockVtuOrders);
      if (raw != null) {
        for (final json in jsonDecode(raw) as List) {
          final order =
              _MockOrder.fromJson(Map<String, dynamic>.from(json as Map));
          orders[order.base.id] = order;
        }
      }
    } catch (_) {
      // Unreadable: start with no orders.
    }
    return orders;
  }

  Future<void> _save() async {
    try {
      final orders = await _db();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          SharedPrefsKeys.mockVtuOrders, jsonEncode([for (final o in orders.values) o.toJson()]));
    } catch (_) {
      // Best-effort: the in-memory copy still serves this run.
    }
  }
}

/// A stored order plus the mock's bookkeeping. Its status is worked out
/// from timestamps whenever it's read ([resolve]), so no timers are
/// needed and a restart picks up where it left off.
class _MockOrder {
  _MockOrder({
    required this.accountId,
    required this.base,
    required this.willFail,
    this.paidAt,
    this.refundRequestedAt,
  });

  final String accountId;

  /// The order as last quoted (awaiting payment). Replaced on a requote.
  VtuOrder base;

  /// The provider fails this bill ([MockScenario.billFails]).
  bool willFail;
  DateTime? paidAt;
  DateTime? refundRequestedAt;

  static const _fulfilAfter = Duration(milliseconds: 1500);
  static const _doneAfter = Duration(seconds: 5);
  static const _refundAfter = Duration(seconds: 4);

  VtuOrder resolve(DateTime now) {
    final paid = paidAt;
    if (paid == null) {
      return _with(now.isAfter(base.expiresAt)
          ? OrderStatus.expired
          : OrderStatus.awaitingPayment);
    }
    final elapsed = now.difference(paid);
    if (elapsed < _fulfilAfter) return _with(OrderStatus.paid);
    if (elapsed < _doneAfter) return _with(OrderStatus.fulfilling);
    if (!willFail) return _with(OrderStatus.done, receipt: _receipt());

    final refunded = refundRequestedAt;
    if (refunded != null && now.difference(refunded) >= _refundAfter) {
      return _with(OrderStatus.refunded);
    }
    return _with(OrderStatus.refundable,
        failureReason:
            "${base.billerName} couldn't complete this bill. Your sats can be refunded.",
        refundRequested: refunded != null);
  }

  VtuOrder _with(OrderStatus status,
          {OrderReceipt? receipt,
          String? failureReason,
          bool refundRequested = false}) =>
      VtuOrder(
        id: base.id,
        title: base.title,
        status: status,
        category: base.category,
        billerId: base.billerId,
        billerName: base.billerName,
        target: base.target,
        amount: base.amount,
        currency: base.currency,
        sats: base.sats,
        rate: base.rate,
        invoice: base.invoice,
        createdAt: base.createdAt,
        expiresAt: base.expiresAt,
        request: base.request,
        planName: base.planName,
        optionName: base.optionName,
        customerName: base.customerName,
        paidAt: paidAt,
        receipt: receipt,
        failureReason: failureReason,
        refundRequested: refundRequested,
      );

  /// What the provider returns per category, as receipt items.
  OrderReceipt _receipt() {
    final reference = 'SP-${base.id.toUpperCase()}';
    final amount = formatFiat(base.amount, base.currency);
    return switch (base.category) {
      BillCategory.airtime => OrderReceipt(
          reference: reference,
          message: '$amount ${base.billerName} airtime sent to ${base.target}.'),
      BillCategory.data => OrderReceipt(
          reference: reference,
          message: '${base.planName} sent to ${base.target}.'),
      BillCategory.electricity when base.request.optionId == 'postpaid' =>
        OrderReceipt(
            reference: reference,
            message: '$amount paid to meter ${base.target}.'),
      BillCategory.electricity => OrderReceipt(
          reference: reference,
          message: 'Enter the token on your meter to load the units.',
          items: [
            ReceiptItem(
                label: 'Token',
                value: _meterToken(),
                primary: true,
                copyable: true),
            ReceiptItem(
                label: 'Units',
                value: '${(base.amount / 225).toStringAsFixed(1)} kWh'),
          ]),
      BillCategory.tv => OrderReceipt(
          reference: reference,
          message:
              '${base.billerName} ${base.planName} active on smartcard ${base.target}.'),
    };
  }

  /// A 20-digit prepaid token, stable per order.
  String _meterToken() {
    final digits = base.id.codeUnits
        .fold<int>(7, (a, b) => (a * 131 + b) % 100000000000);
    final token = digits.toString().padLeft(11, '0') +
        (digits * 7 % 1000000000).toString().padLeft(9, '0');
    return [for (var i = 0; i < 20; i += 4) token.substring(i, i + 4)]
        .join('-');
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'base': base.toJson(),
        'willFail': willFail,
        'paidAt': paidAt?.toUtc().toIso8601String(),
        'refundRequestedAt': refundRequestedAt?.toUtc().toIso8601String(),
      };

  factory _MockOrder.fromJson(Map<String, dynamic> json) => _MockOrder(
        accountId: json['accountId'] as String,
        base: VtuOrder.fromJson(Map<String, dynamic>.from(json['base'] as Map)),
        willFail: json['willFail'] as bool? ?? false,
        paidAt: json['paidAt'] == null
            ? null
            : DateTime.parse(json['paidAt'] as String).toLocal(),
        refundRequestedAt: json['refundRequestedAt'] == null
            ? null
            : DateTime.parse(json['refundRequestedAt'] as String).toLocal(),
      );
}

const _customerNames = [
  'ADEBAYO OLUWASEUN',
  'CHIOMA NWOSU',
  'IBRAHIM MUSA',
  'FUNMILAYO ADEYEMI',
  'EMEKA OKAFOR',
  'HALIMA BELLO',
];

const _addresses = [
  '14 Admiralty Way, Lekki, Lagos',
  '7 Aminu Kano Crescent, Wuse 2, Abuja',
  '22 Allen Avenue, Ikeja, Lagos',
  '3 Stadium Road, Port Harcourt',
];

// ---------------------------------------------------------------------
// Nigeria catalog fixture (GET /catalog?country=NG). Prices are
// illustrative; the real catalog comes from the provider.
// ---------------------------------------------------------------------

const _phone = {
  'kind': 'phone',
  'label': 'Phone number',
  'hint': '0803 123 4567',
  'pattern': r'^0[789][01]\d{8}$',
  'errorText': 'Enter an 11-digit Nigerian number, like 0803 123 4567.',
};

const _meter = {
  'kind': 'number',
  'label': 'Meter number',
  'hint': '11 to 13 digits',
  'pattern': r'^\d{11,13}$',
  'errorText': 'Meter numbers are 11 to 13 digits.',
};

const _smartcard = {
  'kind': 'number',
  'label': 'Smartcard (IUC) number',
  'hint': '10 or 11 digits',
  'pattern': r'^\d{10,11}$',
  'errorText': 'Smartcard numbers are 10 or 11 digits.',
};

// Any amount: only the user's tier limits cap it.
const _airtimeAmount = {
  'type': 'amount',
  'presets': [100, 200, 500, 1000, 2000, 5000],
};

const _powerAmount = {
  'type': 'amount',
  'min': 1000,
  'max': 500000,
  'presets': [2000, 5000, 10000, 20000],
};

const _meterTypes = {
  'label': 'Meter type',
  'choices': [
    {'id': 'prepaid', 'name': 'Prepaid'},
    {'id': 'postpaid', 'name': 'Postpaid'},
  ],
};

const _networks = [
  ('mtn', 'MTN', '#FFCC08'),
  ('airtel', 'Airtel', '#FF3B30'),
  ('glo', 'Glo', '#00A651'),
  ('9mobile', '9mobile', '#00A99D'),
];

const _dataSizes = [
  ('1gb-1d', '1GB', '1 day', 500),
  ('1gb-7d', '1GB', '7 days', 800),
  ('2gb-30d', '2GB', '30 days', 1500),
  ('5gb-30d', '5GB', '30 days', 3500),
  ('10gb-30d', '10GB', '30 days', 6000),
  ('20gb-30d', '20GB', '30 days', 10000),
];

const _discos = [
  ('ikedc', 'Ikeja Electric', 'Ikeja', '#E30613'),
  ('ekedc', 'Eko Electric', 'Eko', '#0072BC'),
  ('aedc', 'Abuja Electric', 'Abuja', '#00A651'),
  ('phed', 'Port Harcourt Electric', 'PH', '#F7941D'),
  ('ibedc', 'Ibadan Electric', 'Ibadan', '#662D91'),
];

const _tvProviders = [
  ('dstv', 'DStv', '#0098DA', [
    ('padi', 'Padi', 4400),
    ('yanga', 'Yanga', 6000),
    ('confam', 'Confam', 11000),
    ('compact', 'Compact', 19000),
  ]),
  ('gotv', 'GOtv', '#5BB947', [
    ('smallie', 'Smallie', 1900),
    ('jinja', 'Jinja', 3900),
    ('jolli', 'Jolli', 5800),
    ('max', 'Max', 8500),
  ]),
  ('startimes', 'StarTimes', '#F28C00', [
    ('nova', 'Nova', 2100),
    ('basic', 'Basic', 4000),
    ('classic', 'Classic', 6000),
  ]),
];

final Map<String, dynamic> _nigeriaCatalog = {
  'country': 'NG',
  'currency': 'NGN',
  'billers': [
    for (final (id, name, color) in _networks)
      {
        'id': '$id-airtime',
        'category': 'airtime',
        'name': name,
        'brandColor': color,
        'target': _phone,
        'pricing': _airtimeAmount,
      },
    for (final (id, name, color) in _networks)
      {
        'id': '$id-data',
        'category': 'data',
        'name': name,
        'brandColor': color,
        'target': _phone,
        'pricing': {
          'type': 'plans',
          'label': 'Choose a plan',
          'plans': [
            for (final (i, (planId, size, validity, price))
                in _dataSizes.indexed)
              {
                'id': '$id-$planId',
                'name': size,
                'validity': validity,
                // Small per-network differences, like real price lists.
                'amount': price + (id == 'mtn' ? 0 : (i + 1) * 50),
              }
          ],
        },
      },
    for (final (id, name, short, color) in _discos)
      {
        'id': id,
        'category': 'electricity',
        'name': name,
        'shortName': short,
        'brandColor': color,
        'target': _meter,
        'pricing': _powerAmount,
        'options': _meterTypes,
        'customerCheck': true,
      },
    for (final (id, name, color, plans) in _tvProviders)
      {
        'id': id,
        'category': 'tv',
        'name': name,
        'brandColor': color,
        'target': _smartcard,
        'pricing': {
          'type': 'plans',
          'label': 'Choose a package',
          'plans': [
            for (final (planId, planName, price) in plans)
              {
                'id': '$id-$planId',
                'name': planName,
                'validity': '1 month',
                'amount': price,
              }
          ],
        },
        'customerCheck': true,
      },
  ],
};
