import 'dart:convert';
import 'dart:io';
import 'package:common/common.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main() async {
  final env = Platform.environment;
  final secret = env['JWT_SECRET']!;
  final internalKey = env['INTERNAL_KEY']!;
  final webhookSecret = env['PAYMENT_WEBHOOK_SECRET']!;
  final orderUrl = env['ORDER_SERVICE_URL']!;
  final isProd = env['APP_ENV'] == 'production';
  final db = await connectDb(env['MONGO_URI']!);
  final payments = db.collection('payments');
  await payments.createIndex(keys: {'orderId': 1});

  final internalHeaders = {'x-internal-key': internalKey};

  /// Marks payment paid + tells order-service. Idempotent.
  Future<bool> settle(ObjectId paymentId, String status) async {
    final p = await payments.findOne({'_id': paymentId});
    if (p == null || p['status'] != 'pending') return false; // replay-safe
    await payments.updateOne({'_id': paymentId},
        {'\$set': {'status': status, 'settledAt': DateTime.now().toUtc()}});
    if (status == 'paid') {
      await http.post(Uri.parse('$orderUrl/internal/orders/${p['orderId']}/paid'),
          headers: internalHeaders);
    }
    return true;
  }

  final protected = Router()
    ..post('/payments', (Request r) async {
      final denied = requireRole(r, ['customer']);
      if (denied != null) return denied;
      final b = await readJson(r);
      final orderId = b['orderId'] as String;
      final resp = await http.get(Uri.parse('$orderUrl/internal/orders/$orderId'),
          headers: internalHeaders);
      if (resp.statusCode != 200) return json({'error': 'order_not_found'}, status: 404);
      final order = jsonDecode(resp.body) as Map<String, dynamic>;
      if (order['customerId'] != userIdOf(r)) return json({'error': 'forbidden'}, status: 403);
      if (order['status'] != 'pending_payment') {
        return json({'error': 'order_not_payable'}, status: 409);
      }
      final id = ObjectId();
      await payments.insertOne({
        '_id': id,
        'orderId': orderId,
        'userId': userIdOf(r),
        'amount': order['total'],
        'currency': order['currency'],
        'provider': 'payway',
        'status': 'pending',
        'createdAt': DateTime.now().toUtc(),
      });
      // TODO: replace with a real ABA PayWay / KHQR "create transaction" call.
      // Return the QR string / checkout URL that the mobile app should display.
      return json({
        'paymentId': id.toHexString(),
        'amount': order['total'],
        'checkoutUrl': 'https://payway.example/checkout?tran_id=${id.toHexString()}',
      }, status: 201);
    })
    ..get('/payments/<id>', (Request r, String id) async {
      final p = await payments.findOne({'_id': ObjectId.fromHexString(id)});
      if (p == null || p['userId'] != userIdOf(r)) return json({'error': 'not_found'}, status: 404);
      return json(serialize(p));
    });

  final router = Router()
    ..get('/health', (Request r) => json({'ok': true}))
    // Provider callback. Authenticated by HMAC signature, not JWT.
    ..post('/payments/webhook', (Request r) async {
      final raw = await r.readAsString();
      final expected =
          Hmac(sha256, utf8.encode(webhookSecret)).convert(utf8.encode(raw)).toString();
      if (!safeEquals(r.headers['x-signature'] ?? '', expected)) {
        return json({'error': 'bad_signature'}, status: 401);
      }
      final b = jsonDecode(raw) as Map<String, dynamic>;
      final pid = ObjectId.fromHexString(b['tran_id'] as String);
      final p = await payments.findOne({'_id': pid});
      if (p == null) return json({'error': 'not_found'}, status: 404);
      if ((p['amount'] as num) != (b['amount'] as num)) {
        return json({'error': 'amount_mismatch'}, status: 400);
      }
      await settle(pid, b['status'] == 'approved' ? 'paid' : 'failed');
      return json({'ok': true});
    })
    // DEV ONLY: pretend the provider approved the payment.
    ..post('/payments/<id>/simulate-paid', (Request r, String id) async {
      if (isProd) return json({'error': 'not_found'}, status: 404);
      final ok = await settle(ObjectId.fromHexString(id), 'paid');
      return json({'settled': ok});
    })
    ..mount('/', Pipeline().addMiddleware(authMiddleware(secret)).addHandler(protected.call));

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(errorMiddleware())
      .addHandler(router.call);
  final port = int.parse(env['PORT'] ?? '8080');
  await io.serve(handler, InternetAddress.anyIPv4, port);
  print('payment-service on :$port');
}
