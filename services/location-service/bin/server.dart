import 'dart:convert';
import 'dart:io';
import 'package:common/common.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// NOTE: in-memory subscribers => single instance only.
// To scale horizontally, fan out through Redis pub/sub.
final trackers = <String, Set<WebSocketChannel>>{};

Future<void> main() async {
  final env = Platform.environment;
  final secret = env['JWT_SECRET']!;
  final db = await connectDb(env['MONGO_URI']!);
  final locs = db.collection('driver_locations');
  await locs.createIndex(keys: {'location': '2dsphere'});
  // drivers that stopped reporting disappear after 5 minutes
    await db.runCommand({
    'createIndexes': 'driver_locations',
    'indexes': [
      {'key': {'updatedAt': 1}, 'name': 'updatedAt_ttl', 'expireAfterSeconds': 300}
    ],
  });

  Future<void> saveLocation(String driverId, num lat, num lng) async {
    await locs.updateOne(
      {'_id': driverId},
      {
        '\$set': {
          'location': {'type': 'Point', 'coordinates': [lng, lat]},
          'updatedAt': DateTime.now().toUtc(),
        }
      },
      upsert: true,
    );
  }

  final protected = Router()
    ..post('/drivers/location', (Request r) async {
      final denied = requireRole(r, ['driver']);
      if (denied != null) return denied;
      final b = await readJson(r);
      await saveLocation(userIdOf(r), b['lat'] as num, b['lng'] as num);
      return json({'ok': true});
    })
    ..get('/drivers/nearby', (Request r) async {
      final q = r.url.queryParameters;
      final lat = double.parse(q['lat']!), lng = double.parse(q['lng']!);
      final radius = double.parse(q['radius'] ?? '3000'); // metres
      final list = await locs.find({
        'location': {
          '\$near': {
            '\$geometry': {'type': 'Point', 'coordinates': [lng, lat]},
            '\$maxDistance': radius,
          }
        }
      }).toList();
      return json(serialize(list));
    });

  final router = Router()
    ..get('/health', (Request r) => json({'ok': true}))
    // Driver app streams {lat, lng, orderId?} JSON frames.
    ..get('/ws/driver', (Request r) {
      final p = verifyToken(r.url.queryParameters['token'] ?? '', secret);
      if (p == null || p['role'] != 'driver') return json({'error': 'unauthorized'}, status: 401);
      return webSocketHandler((WebSocketChannel ch, _) {
        ch.stream.listen((msg) async {
          try {
            final m = jsonDecode(msg as String) as Map<String, dynamic>;
            await saveLocation(p['sub'], m['lat'] as num, m['lng'] as num);
            final oid = m['orderId'] as String?;
            if (oid != null) {
              final frame = jsonEncode({'lat': m['lat'], 'lng': m['lng']});
              for (final c in trackers[oid] ?? <WebSocketChannel>{}) {
                c.sink.add(frame);
              }
            }
          } catch (_) {
            ch.sink.add(jsonEncode({'error': 'bad_frame'}));
          }
        });
      })(r);
    })
    // Customer app watches the driver of an order.
    // TODO: verify the caller owns the order (ask order-service).
    ..get('/ws/track/<orderId>', (Request r, String orderId) {
      if (verifyToken(r.url.queryParameters['token'] ?? '', secret) == null) {
        return json({'error': 'unauthorized'}, status: 401);
      }
      return webSocketHandler((WebSocketChannel ch, _) {
        trackers.putIfAbsent(orderId, () => {}).add(ch);
        ch.stream.listen((_) {}, onDone: () => trackers[orderId]?.remove(ch));
      })(r);
    })
    ..mount('/', Pipeline().addMiddleware(authMiddleware(secret)).addHandler(protected.call));

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(errorMiddleware())
      .addHandler(router.call);
  final port = int.parse(env['PORT'] ?? '8080');
  await io.serve(handler, InternetAddress.anyIPv4, port);
  print('location-service on :$port');
}
