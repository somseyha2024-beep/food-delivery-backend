import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'http.dart';

String signToken({
  required String userId,
  required String role,
  required String secret,
  Duration ttl = const Duration(hours: 12),
}) =>
    JWT({'sub': userId, 'role': role}).sign(SecretKey(secret), expiresIn: ttl);

/// Returns {sub, role} or null if invalid/expired.
Map<String, dynamic>? verifyToken(String token, String secret) {
  try {
    return JWT.verify(token, SecretKey(secret)).payload as Map<String, dynamic>;
  } on JWTException {
    return null;
  }
}

Middleware authMiddleware(String secret) => (inner) => (req) {
      final h = req.headers['authorization'];
      if (h == null || !h.startsWith('Bearer ')) {
        return json({'error': 'unauthorized'}, status: 401);
      }
      final p = verifyToken(h.substring(7), secret);
      if (p == null) return json({'error': 'invalid_token'}, status: 401);
      return inner(req.change(context: {'userId': p['sub'], 'role': p['role']}));
    };

String userIdOf(Request r) => r.context['userId'] as String;
String roleOf(Request r) => r.context['role'] as String;

/// Returns a 403 Response if the caller's role is not allowed, else null.
Response? requireRole(Request r, List<String> roles) =>
    roles.contains(roleOf(r)) ? null : json({'error': 'forbidden'}, status: 403);
