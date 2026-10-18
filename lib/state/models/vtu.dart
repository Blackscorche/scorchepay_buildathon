import 'package:flutter/painting.dart' show Color;

// Models for the VTU API contract (see docs/VTU.md). Every type parses
// from and serialises to the JSON the backend sends, so the mock and the
// real API share one shape. Fiat amounts are whole units of the catalog's
// currency (naira); Bitcoin amounts are sats.

/// The bill categories the app offers.
enum BillCategory {
  airtime('Airtime'),
  data('Data'),
  electricity('Electricity'),
  tv('Cable TV');

  const BillCategory(this.label);
  final String label;

  static BillCategory fromJson(Object? value) =>
      values.firstWhere((c) => c.name == value);
}

/// What kind of value a [TargetField] holds, so the app can pick a
/// keyboard without knowing the category.
enum TargetKind {
  phone,
  number,
  text;

  static TargetKind fromJson(Object? value) =>
      values.firstWhere((k) => k.name == value, orElse: () => TargetKind.text);
}

/// Who receives the bill (phone, meter or smartcard number), and how to
/// check it before ordering.
class TargetField {
  const TargetField({
    required this.label,
    required this.hint,
    required this.pattern,
    required this.errorText,
    this.kind = TargetKind.text,
  });

  final String label;
  final String hint;

  /// Whole-value regex the (space-stripped) target must match.
  final String pattern;

  /// Shown when [pattern] doesn't match.
  final String errorText;
  final TargetKind kind;

  /// [value] without spaces or dashes, as sent to the backend.
  static String normalize(String value) =>
      value.replaceAll(RegExp(r'[\s\-]'), '');

  bool isValid(String value) => RegExp(pattern).hasMatch(normalize(value));

  factory TargetField.fromJson(Map<String, dynamic> json) => TargetField(
        label: json['label'] as String,
        hint: json['hint'] as String,
        pattern: json['pattern'] as String,
        errorText: json['errorText'] as String,
        kind: TargetKind.fromJson(json['kind']),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'hint': hint,
        'pattern': pattern,
        'errorText': errorText,
        'kind': kind.name,
      };
}

/// How a biller is priced: the user types an amount ([AmountPricing]) or
/// picks a fixed-price plan ([PlanPricing]).
sealed class BillPricing {
  const BillPricing();

  /// The form's heading for this input.
  String get label;

  factory BillPricing.fromJson(Map<String, dynamic> json) =>
      switch (json['type']) {
        'plans' => PlanPricing.fromJson(json),
        _ => AmountPricing.fromJson(json),
      };

  Map<String, dynamic> toJson();
}

/// A free amount (airtime, electricity), optionally bounded by [min]
/// and/or [max]. The user's tier limits still apply on top.
class AmountPricing extends BillPricing {
  const AmountPricing({
    this.min,
    this.max,
    this.presets = const [],
    this.label = 'Amount',
  });

  @override
  final String label;
  final int? min;
  final int? max;

  /// Quick picks shown as chips.
  final List<int> presets;

  bool allows(int amount) =>
      amount > 0 &&
      (min == null || amount >= min!) &&
      (max == null || amount <= max!);

  factory AmountPricing.fromJson(Map<String, dynamic> json) => AmountPricing(
        label: json['label'] as String? ?? 'Amount',
        min: (json['min'] as num?)?.toInt(),
        max: (json['max'] as num?)?.toInt(),
        presets: [
          for (final p in json['presets'] as List? ?? const [])
            (p as num).toInt()
        ],
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'amount',
        'label': label,
        'min': min,
        'max': max,
        'presets': presets,
      };
}

/// Fixed-price plans (data bundles, TV packages).
class PlanPricing extends BillPricing {
  const PlanPricing({required this.plans, this.label = 'Choose a plan'});

  @override
  final String label;
  final List<BillPlan> plans;

  BillPlan? find(String? id) => plans.where((p) => p.id == id).firstOrNull;

  factory PlanPricing.fromJson(Map<String, dynamic> json) => PlanPricing(
        label: json['label'] as String? ?? 'Choose a plan',
        plans: [
          for (final p in json['plans'] as List)
            BillPlan.fromJson(Map<String, dynamic>.from(p as Map))
        ],
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'plans',
        'label': label,
        'plans': [for (final p in plans) p.toJson()],
      };
}

/// A fixed-price product: a data bundle or TV package.
class BillPlan {
  const BillPlan(
      {required this.id, required this.name, required this.amount, this.validity});

  final String id;
  final String name;
  final int amount;
  final String? validity;

  factory BillPlan.fromJson(Map<String, dynamic> json) => BillPlan(
        id: json['id'] as String,
        name: json['name'] as String,
        amount: (json['amount'] as num).toInt(),
        validity: json['validity'] as String?,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'amount': amount, 'validity': validity};
}

/// A choice the biller needs before ordering, such as prepaid/postpaid
/// metering.
class BillerOptions {
  const BillerOptions({required this.label, required this.choices});

  /// The form's heading, e.g. "Meter type".
  final String label;
  final List<BillerChoice> choices;

  BillerChoice? find(String? id) =>
      choices.where((c) => c.id == id).firstOrNull;

  factory BillerOptions.fromJson(Map<String, dynamic> json) => BillerOptions(
        label: json['label'] as String,
        choices: [
          for (final c in json['choices'] as List)
            BillerChoice.fromJson(Map<String, dynamic>.from(c as Map))
        ],
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'choices': [for (final c in choices) c.toJson()],
      };
}

class BillerChoice {
  const BillerChoice({required this.id, required this.name});

  final String id;
  final String name;

  factory BillerChoice.fromJson(Map<String, dynamic> json) =>
      BillerChoice(id: json['id'] as String, name: json['name'] as String);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// One network, disco or TV provider in the catalog. The order form is
/// built from it: [options] (if any), [target], then [pricing].
class Biller {
  const Biller({
    required this.id,
    required this.category,
    required this.name,
    required this.target,
    required this.pricing,
    this.shortName,
    this.brandColor,
    this.options,
    this.customerCheck = false,
    this.available = true,
  });

  final String id;
  final BillCategory category;
  final String name;

  /// Short label for tiles ("Ikeja" for "Ikeja Electric").
  final String? shortName;

  /// `#RRGGBB`, for the biller's tile.
  final String? brandColor;
  final TargetField target;
  final BillPricing pricing;
  final BillerOptions? options;

  /// Whether the target's holder name must be confirmed before ordering
  /// (meters and smartcards).
  final bool customerCheck;

  /// False while the provider is down; shown but not selectable.
  final bool available;

  String get label => shortName ?? name;

  Color? get color {
    final hex = brandColor;
    if (hex == null || hex.length != 7) return null;
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

  factory Biller.fromJson(Map<String, dynamic> json) => Biller(
        id: json['id'] as String,
        category: BillCategory.fromJson(json['category']),
        name: json['name'] as String,
        shortName: json['shortName'] as String?,
        brandColor: json['brandColor'] as String?,
        target: TargetField.fromJson(
            Map<String, dynamic>.from(json['target'] as Map)),
        pricing: BillPricing.fromJson(
            Map<String, dynamic>.from(json['pricing'] as Map)),
        options: json['options'] is Map
            ? BillerOptions.fromJson(
                Map<String, dynamic>.from(json['options'] as Map))
            : null,
        customerCheck: json['customerCheck'] as bool? ?? false,
        available: json['available'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category.name,
        'name': name,
        'shortName': shortName,
        'brandColor': brandColor,
        'target': target.toJson(),
        'pricing': pricing.toJson(),
        'options': options?.toJson(),
        'customerCheck': customerCheck,
        'available': available,
      };
}

/// `GET /catalog?country=`: everything a country offers.
class Catalog {
  const Catalog(
      {required this.country, required this.currency, required this.billers});

  /// ISO 3166-1 alpha-2, e.g. `NG`.
  final String country;

  /// ISO 4217, e.g. `NGN`.
  final String currency;
  final List<Biller> billers;

  List<Biller> billersFor(BillCategory category) => [
        for (final b in billers)
          if (b.category == category) b
      ];

  Set<BillCategory> get categories => {for (final b in billers) b.category};

  factory Catalog.fromJson(Map<String, dynamic> json) => Catalog(
        country: json['country'] as String,
        currency: json['currency'] as String,
        billers: [
          for (final b in json['billers'] as List)
            Biller.fromJson(Map<String, dynamic>.from(b as Map))
        ],
      );

  Map<String, dynamic> toJson() => {
        'country': country,
        'currency': currency,
        'billers': [for (final b in billers) b.toJson()],
      };
}

/// `GET /limits`: the signed-in user's caps at their KYC tier.
class VtuLimits {
  const VtuLimits({
    required this.currency,
    required this.tier,
    required this.perOrder,
    required this.daily,
    required this.usedToday,
    this.nextTier,
  });

  /// ISO 4217 code the amounts are in; limits can differ per currency.
  final String currency;
  final int tier;
  final int perOrder;
  final int daily;
  final int usedToday;

  /// Caps after verifying; null at the top tier.
  final VtuLimits? nextTier;

  int get remainingToday => (daily - usedToday).clamp(0, daily);

  /// The most a single order can be right now.
  int get maxOrder => perOrder < remainingToday ? perOrder : remainingToday;

  factory VtuLimits.fromJson(Map<String, dynamic> json) => VtuLimits(
        currency: json['currency'] as String,
        tier: (json['tier'] as num).toInt(),
        perOrder: (json['perOrder'] as num).toInt(),
        daily: (json['daily'] as num).toInt(),
        usedToday: (json['usedToday'] as num?)?.toInt() ?? 0,
        nextTier: json['nextTier'] is Map
            ? VtuLimits.fromJson(
                Map<String, dynamic>.from(json['nextTier'] as Map))
            : null,
      );

  Map<String, dynamic> toJson() => {
        'currency': currency,
        'tier': tier,
        'perOrder': perOrder,
        'daily': daily,
        'usedToday': usedToday,
        'nextTier': nextTier?.toJson(),
      };
}

/// `POST /customers/validate`: who owns a meter or smartcard.
class CustomerInfo {
  const CustomerInfo({required this.name, this.address});

  final String name;
  final String? address;

  factory CustomerInfo.fromJson(Map<String, dynamic> json) => CustomerInfo(
      name: json['name'] as String, address: json['address'] as String?);

  Map<String, dynamic> toJson() => {'name': name, 'address': address};
}

/// `POST /orders` body. Kept by the app so an expired quote can be
/// re-requested unchanged.
class OrderRequest {
  const OrderRequest({
    required this.billerId,
    required this.target,
    this.optionId,
    this.planId,
    this.amount,
  });

  final String billerId;
  final String target;

  /// The chosen [BillerOptions] choice, if the biller has options.
  final String? optionId;

  /// Set for plan billers; [amount] for free-amount ones.
  final String? planId;
  final int? amount;

  factory OrderRequest.fromJson(Map<String, dynamic> json) => OrderRequest(
        billerId: json['billerId'] as String,
        target: json['target'] as String,
        optionId: json['optionId'] as String?,
        planId: json['planId'] as String?,
        amount: (json['amount'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'billerId': billerId,
        'target': target,
        'optionId': optionId,
        'planId': planId,
        'amount': amount,
      };
}

/// Where an order is (system design §03).
enum OrderStatus {
  awaitingPayment('Awaiting payment'),
  paid('Paid'),
  fulfilling('Processing'),
  done('Completed'),
  expired('Expired'),
  refundable('Refund available'),
  refunded('Refunded');

  const OrderStatus(this.label);
  final String label;

  /// Nothing more will happen without the user (or ever).
  bool get isFinal =>
      this == done || this == expired || this == refundable || this == refunded;

  static OrderStatus fromJson(Object? value) =>
      values.firstWhere((s) => s.name == value);
}

/// What the user gets for a completed order. The backend decides what
/// it holds per biller (e.g. an electricity token and units, or an
/// airtime PIN) as labelled [items], so the app shows any receipt without
/// knowing the category.
class OrderReceipt {
  const OrderReceipt(
      {required this.reference, this.message, this.items = const []});

  /// The provider's reference.
  final String reference;

  /// A sentence summing it up, e.g. "₦1,000 MTN airtime sent to …".
  final String? message;
  final List<ReceiptItem> items;

  factory OrderReceipt.fromJson(Map<String, dynamic> json) => OrderReceipt(
        reference: json['reference'] as String,
        message: json['message'] as String?,
        items: [
          for (final item in json['items'] as List? ?? const [])
            ReceiptItem.fromJson(Map<String, dynamic>.from(item as Map))
        ],
      );

  Map<String, dynamic> toJson() => {
        'reference': reference,
        'message': message,
        'items': [for (final item in items) item.toJson()],
      };
}

/// One labelled value on a receipt.
class ReceiptItem {
  const ReceiptItem({
    required this.label,
    required this.value,
    this.primary = false,
    this.copyable = false,
  });

  final String label;
  final String value;

  /// What the user came for (e.g. the token): shown large.
  final bool primary;

  /// Offer a copy button.
  final bool copyable;

  factory ReceiptItem.fromJson(Map<String, dynamic> json) => ReceiptItem(
        label: json['label'] as String,
        value: json['value'] as String,
        primary: json['primary'] as bool? ?? false,
        copyable: json['copyable'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'value': value,
        'primary': primary,
        'copyable': copyable,
      };
}

/// `GET /orders/:id`: one shape for every state.
class VtuOrder {
  const VtuOrder({
    required this.id,
    required this.title,
    required this.status,
    required this.category,
    required this.billerId,
    required this.billerName,
    required this.target,
    required this.amount,
    required this.currency,
    required this.sats,
    required this.rate,
    required this.invoice,
    required this.createdAt,
    required this.expiresAt,
    required this.request,
    this.planName,
    this.optionName,
    this.customerName,
    this.paidAt,
    this.receipt,
    this.failureReason,
    this.refundRequested = false,
  });

  final String id;

  /// What was bought, e.g. "MTN airtime" or "DStv Compact". Written by the
  /// backend, which knows each biller's naming.
  final String title;
  final OrderStatus status;
  final BillCategory category;
  final String billerId;
  final String billerName;

  /// Phone, meter or smartcard number. The backend deletes it after
  /// fulfilment, so finished orders may show it masked.
  final String target;
  final int amount;
  final String currency;

  /// What the invoice asks for.
  final int sats;

  /// Fiat per BTC used for the quote, spread included.
  final double rate;

  /// BOLT11 invoice that expires with the quote.
  final String invoice;
  final DateTime createdAt;
  final DateTime expiresAt;
  final OrderRequest request;
  final String? planName;
  final String? optionName;
  final String? customerName;
  final DateTime? paidAt;
  final OrderReceipt? receipt;
  final String? failureReason;

  /// A refund invoice was submitted and is being paid.
  final bool refundRequested;

  /// The status still changes without the user doing anything.
  bool get inProgress => !status.isFinal || refundRequested;

  Duration timeLeft([DateTime? now]) {
    final left = expiresAt.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  factory VtuOrder.fromJson(Map<String, dynamic> json) => VtuOrder(
        id: json['id'] as String,
        title: json['title'] as String,
        status: OrderStatus.fromJson(json['status']),
        category: BillCategory.fromJson(json['category']),
        billerId: json['billerId'] as String,
        billerName: json['billerName'] as String,
        target: json['target'] as String,
        amount: (json['amount'] as num).toInt(),
        currency: json['currency'] as String,
        sats: (json['sats'] as num).toInt(),
        rate: (json['rate'] as num).toDouble(),
        invoice: json['invoice'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        request: OrderRequest.fromJson(
            Map<String, dynamic>.from(json['request'] as Map)),
        planName: json['planName'] as String?,
        optionName: json['optionName'] as String?,
        customerName: json['customerName'] as String?,
        paidAt: json['paidAt'] == null
            ? null
            : DateTime.parse(json['paidAt'] as String),
        receipt: json['receipt'] is Map
            ? OrderReceipt.fromJson(
                Map<String, dynamic>.from(json['receipt'] as Map))
            : null,
        failureReason: json['failureReason'] as String?,
        refundRequested: json['refundRequested'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'status': status.name,
        'category': category.name,
        'billerId': billerId,
        'billerName': billerName,
        'target': target,
        'amount': amount,
        'currency': currency,
        'sats': sats,
        'rate': rate,
        'invoice': invoice,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        'request': request.toJson(),
        'planName': planName,
        'optionName': optionName,
        'customerName': customerName,
        'paidAt': paidAt?.toUtc().toIso8601String(),
        'receipt': receipt?.toJson(),
        'failureReason': failureReason,
        'refundRequested': refundRequested,
      };
}
