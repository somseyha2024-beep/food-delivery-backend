import 'dart:io';
import 'package:common/common.dart';
import 'package:dbcrypt/dbcrypt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:mongo_dart/mongo_dart.dart';

const roles = ['customer', 'driver', 'restaurant'];

Future<void> main() async {
  final env = Platform.environment;
  final secret = env['JWT_SECRET']!;
  final db = await connectDb(env['MONGO_URI']!);
  final users = db.collection('users');
  await users.createIndex(keys: {'email': 1}, unique: true);

  final router = Router()
    ..get('/health', (Request r) => json({'ok': true}))
    ..post('/auth/register', (Request r) async {
      final b = await readJson(r);
      final email = (b['email'] as String).trim().toLowerCase();
      final password = b['password'] as String;
      final role = (b['role'] ?? 'customer') as String;
      if (!email.contains('@') || password.length < 8 || !roles.contains(role)) {
        return json({'error': 'invalid email/password(min 8)/role'}, status: 400);
      }
      if (await users.findOne({'email': email}) != null) {
        return json({'error': 'email_taken'}, status: 409);
      }
      final id = ObjectId();
      await users.insertOne({
        '_id': id,
        'name': b['name'],
        'email': email,
        'phone': b['phone'],
        'role': role,
        'passwordHash': DBCrypt().hashpw(password, DBCrypt().gensalt()),
        'createdAt': DateTime.now().toUtc(),
      });
      return json({
        'id': id.toHexString(),
        'token': signToken(userId: id.toHexString(), role: role, secret: secret),
      }, status: 201);
    })
    ..post('/auth/login', (Request r) async {
      final b = await readJson(r);
      final u = await users.findOne({'email': (b['email'] as String).trim().toLowerCase()});
      if (u == null || !DBCrypt().checkpw(b['password'] as String, u['passwordHash'] as String)) {
        return json({'error': 'invalid_credentials'}, status: 401);
      }
      final id = (u['_id'] as ObjectId).toHexString();
      return json({'token': signToken(userId: id, role: u['role'], secret: secret)});
    })
    ..mount(
        '/auth/me',
        Pipeline().addMiddleware(authMiddleware(secret)).addHandler((Request r) async {
          final u = await users.findOne({'_id': ObjectId.fromHexString(userIdOf(r))});
          if (u == null) return json({'error': 'not_found'}, status: 404);
          u.remove('passwordHash');
          return json(serialize(u));
        }));

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(errorMiddleware())
      .addHandler(router.call);
  final port = int.parse(env['PORT'] ?? '8080');
  await io.serve(handler, InternetAddress.anyIPv4, port);
  print('auth-service on :$port');
}
