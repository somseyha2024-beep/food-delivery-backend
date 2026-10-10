import 'dart:io';
import 'package:common/common.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

// status -> (next status, role allowed to perform it)
const transitions = {
  'paid': ('preparing', 'restaurant'),
  'preparing': ('ready', 'restaurant'),
  'ready': ('picked_up', 'driver'),
  'picked_up': ('delivered', 'driver'),
};

Future<void> main() async {
  final env = Platform.environment;
  final secret = env['JWT_SECRET']!;
  final internalKey = env['INTERNAL_KEY']!;
  final db = await connectDb(env['MONGO_URI']!);
  final restaurants = db.collection('restaurants');
  final orders = db.collection('orders');
  await orders.createIndex(keys: {'customerId': 1, 'createdAt': -1});

  bool internalOk(Request r) =>
      safeEquals(r.headers['x-internal-key'] ?? '', internalKey);

  final protected = Router()
    ..post('/restaurants', (Request r) async {
      final denied = requireRole(r, ['restaurant']);
      if (denied != null) return denied;
      final b = await readJson(r);
      final id = ObjectId();
      await restaurants.insertOne({
        '_id': id,
        'ownerId': userIdOf(r),
        'name': b['name'],
        'location': {
          'type': 'Point',
          'coordinates': [b['lng'], b['lat']],
        },
        // menu: [{sku, name, price}]
        'menu': b['menu'] ?? [],
        'createdAt': DateTime.now().toUtc(),
      });
      return json({'id': id.toHexString()}, status: 201);
    })
    ..post('/orders', (Request r) async {
      final denied = requireRole(r, ['customer']);
      if (denied != null) return denied;
      final b = await readJson(r);
      final rest = await restaurants
          .findOne({'_id': ObjectId.fromHexString(b['restaurantId'] as String)});
      if (rest == null) return json({'error': 'restaurant_not_found'}, status: 404);

      final menu = {for (final m in rest['menu'] as List) m['sku']: m};
      var total = 0.0;
      final lines = <Map<String, dynamic>>[];
      for (final i in b['items'] as List) {
        final m = menu[i['sku']];
        final qty = i['qty'] as int;
        if (m == null || qty < 1) {
          return json({'error': 'invalid_item', 'sku': i['sku']}, status: 400);
        }
        total += (m['price'] as num) * qty; // price from DB, never from client
        lines.add({'sku': m['sku'], 'name': m['name'], 'price': m['price'], 'qty': qty});
      }
      if (lines.isEmpty) return json({'error': 'empty_order'}, status: 400);

      final id = ObjectId();
      await orders.insertOne({
        '_id': id,
        'customerId': userIdOf(r),
        'restaurantId': b['restaurantId'],
        'restaurantOwnerId': rest['ownerId'],
        'items': lines,
        'total': double.parse(total.toStringAsFixed(2)),
        'currency': 'USD',
        'deliveryLocation': {
          'type': 'Point',
          'coordinates': [b['lng'], b['lat']],
        },
        'driverId': null,
        'status': 'pending_payment',
        'createdAt': DateTime.now().toUtc(),
      });
      return json({'id': id.toHexString(), 'total': total, 'status': 'pending_payment'},
          status: 201);
    })
    ..get('/orders/<id>', (Request r, String id) async {
      final o = await orders.findOne({'_id': ObjectId.fromHexString(id)});
      if (o == null) return json({'error': 'not_found'}, status: 404);
      final uid = userIdOf(r);
      final allowed = o['customerId'] == uid ||
          o['restaurantOwnerId'] == uid ||
          o['driverId'] == uid ||
          roleOf(r) == 'driver';
      if (!allowed) return json({'error': 'forbidden'}, status: 403);
      return json(serialize(o));
    })
    ..get('/orders', (Request r) async {
      final uid = userIdOf(r);
      final field = switch (roleOf(r)) {
        'restaurant' => 'restaurantOwnerId',
        'driver' => 'driverId',
        _ => 'customerId',
      };
      final list = await orders.find({field: uid}).toList();
      return json(serialize(list));
    })
    ..post('/orders/<id>/accept', (Request r, String id) async {
      final denied = requireRole(r, ['driver']);
      if (denied != null) return denied;
      // atomic claim: only succeeds if nobody has accepted yet
      final res = await orders.updateOne(
        {
          '_id': ObjectId.fromHexString(id),
          'driverId': null,
          'status': {'\$in': ['paid', 'preparing', 'ready']},
        },
        {'\$set': {'driverId': userIdOf(r)}},
      );
      return res.nModified == 1
          ? json({'ok': true})
          : json({'error': 'cannot_accept'}, status: 409);
    })
    ..patch('/orders/<id>/status', (Request r, String id) async {
      final oid = ObjectId.fromHexString(id);
      final o = await orders.findOne({'_id': oid});
      if (o == null) return json({'error': 'not_found'}, status: 404);
      final t = transitions[o['status']];
      if (t == null) return json({'error': 'no_further_transition'}, status: 409);
      final (next, role) = t;
      final denied = requireRole(r, [role]);
      if (denied != null) return denied;
      final uid = userIdOf(r);
      if (role == 'restaurant' && o['restaurantOwnerId'] != uid) {
        return json({'error': 'forbidden'}, status: 403);
      }
      if (role == 'driver' && o['driverId'] != uid) {
        return json({'error': 'forbidden'}, status: 403);
      }
      await orders.updateOne({'_id': oid, 'status': o['status']},
          {'\$set': {'status': next, 'updatedAt': DateTime.now().toUtc()}});
      return json({'status': next});
    });

  final router = Router()
    ..get('/health', (Request r) => json({'ok': true}))
    ..get('/restaurants', (Request r) async =>
        json(serialize(await restaurants.find().toList())))
    // service-to-service only (NOT exposed by the gateway)
    ..get('/internal/orders/<id>', (Request r, String id) async {
      if (!internalOk(r)) return json({'error': 'forbidden'}, status: 403);
      final o = await orders.findOne({'_id': ObjectId.fromHexString(id)});
      return o == null ? json({'error': 'not_found'}, status: 404) : json(serialize(o));
    })
    ..post('/internal/orders/<id>/paid', (Request r, String id) async {
      if (!internalOk(r)) return json({'error': 'forbidden'}, status: 403);
      final res = await orders.updateOne(
        {'_id': ObjectId.fromHexString(id), 'status': 'pending_payment'},
        {'\$set': {'status': 'paid', 'paidAt': DateTime.now().toUtc()}},
      );
      return json({'updated': res.nModified});
    })
    ..mount('/', Pipeline().addMiddleware(authMiddleware(secret)).addHandler(protected.call));

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(errorMiddleware())
      .addHandler(router.call);
  final port = int.parse(env['PORT'] ?? '8080');
  await io.serve(handler, InternetAddress.anyIPv4, port);
  print('order-service on :$port');
}
