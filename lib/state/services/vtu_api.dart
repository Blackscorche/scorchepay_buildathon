import '../models/vtu.dart';

/// The VTU backend: catalog, limits, orders and refunds (contract in
/// docs/VTU.md). Calls are made as the signed-in user: implementations
/// hold the session, so callers never pass a token.
///
/// Only `MockVtuApi` exists for now; an HTTP implementation of this same
/// interface replaces it once the backend's signet API is up.
abstract class VtuApi {
  Future<Catalog> getCatalog({String country = 'NG'});

  Future<VtuLimits> getLimits();

  /// Looks up the holder of a meter or smartcard. Throws
  /// [VtuErrorCode.customerNotFound].
  Future<CustomerInfo> validateCustomer(
      {required String billerId, required String target, String? optionId});

  /// Locks a quote and returns the order with its invoice, awaiting
  /// payment. Throws [VtuErrorCode.overLimit] when the user's tier caps
  /// don't allow it.
  Future<VtuOrder> createOrder(OrderRequest request);

  Future<VtuOrder> getOrder(String orderId);

  /// The user's orders, newest first.
  Future<List<VtuOrder>> listOrders({int limit = 20});

  /// Claims a refund for a [OrderStatus.refundable] order by having the
  /// backend pay [invoice] (BOLT11, for exactly the order's sats).
  Future<VtuOrder> requestRefund(String orderId,
      {required String invoice});
}

enum VtuErrorCode {
  overLimit,
  invalidTarget,
  customerNotFound,
  quoteExpired,
  billerUnavailable,
  invalidInvoice,
  signedOut,
  notFound,
  network,
  unknown,
}

/// Thrown by [VtuApi]. Its [toString] is the user-facing message.
class VtuException implements Exception {
  const VtuException(this.code, this.message);

  final VtuErrorCode code;
  final String message;

  @override
  String toString() => message;
}
