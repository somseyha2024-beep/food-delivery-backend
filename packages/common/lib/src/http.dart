import 'dart:convert';
import 'package:shelf/shelf.dart';

Response json(Object? body, {int status = 200}) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );

Future<Map<String, dynamic>> readJson(Request r) async {
  final body = await r.readAsString();
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('JSON object expected');
  }
  return decoded;
}

/// Turns bad input into 400 and unexpected errors into 500 (no stack leak).
Middleware errorMiddleware() => (inner) => (req) async {
      try {
        return await inner(req);
      } on FormatException catch (e) {
        return json({'error': 'bad_request', 'message': e.message}, status: 400);
      } on ArgumentError catch (e) {
        return json({'error': 'bad_request', 'message': '${e.message}'}, status: 400);
      } on TypeError {
        return json({'error': 'bad_request', 'message': 'invalid field types'}, status: 400);
      } catch (e, st) {
        print('ERROR ${req.method} ${req.url}: $e\n$st');
        return json({'error': 'internal_error'}, status: 500);
      }
    };

/// Constant-time string comparison (for signatures / keys).
bool safeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return r == 0;
}
