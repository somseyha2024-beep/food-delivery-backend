import 'package:mongo_dart/mongo_dart.dart';

Future<Db> connectDb(String uri) async {
  final db = await Db.create(uri);
  await db.open();
  return db;
}

/// Convert Mongo documents (ObjectId, DateTime) into JSON-safe values.
dynamic serialize(dynamic v) {
  if (v is ObjectId) return v.toHexString();
  if (v is DateTime) return v.toUtc().toIso8601String();
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), serialize(val)));
  if (v is List) return v.map(serialize).toList();
  return v;
}
