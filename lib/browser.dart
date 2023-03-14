import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:buffer/buffer.dart';

import 'http_client.dart';
export 'http_client.dart';

/// HTTP Client in browser environment.
class BrowserClient implements Client {
  @override
  Future<Response> send(Request request) async {
    if (request.timeout != null && request.timeout! > Duration.zero) {
      return _send(request).timeout(request.timeout!);
    } else {
      return _send(request);
    }
  }

  Future<Response> _send(Request request) async {
    ByteBuffer? buffer;

    final body = request.body;
    if (body is List<int>) {
      buffer = castBytes(body).buffer;
    } else if (body is Stream<List<int>>) {
      buffer = (await readAsBytes(body)).buffer;
    } else if (body is StreamFn) {
      final data = await readAsBytes(await body());
      buffer = data.buffer;
    }

    final sendData = buffer ?? request.body;
    final rs = await html.HttpRequest.request(
      request.uri.toString(),
      method: request.method,
      requestHeaders: request.headers.toSimpleMap(),
      sendData: sendData,
    );
    final response = rs.response;
    final headers = Headers(rs.responseHeaders);
    if (response is ByteBuffer) {
      return Response(
          rs.status ?? 0, rs.statusText ?? '', headers, response.asUint8List());
    } else {
      return Response(rs.status ?? 0, rs.statusText ?? '', headers, response);
    }
  }

  @override
  Future close({bool force = false}) async {
    // TODO: throw exception on send() when the [BrowserClient] is closed.
  }
}
