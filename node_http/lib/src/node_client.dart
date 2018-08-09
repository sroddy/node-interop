// Copyright (c) 2018, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:js';

import 'package:http/http.dart';
import 'package:node_interop/http.dart' as nodeHttp;
import 'package:node_interop/https.dart' as nodeHttps;
import 'package:node_interop/node.dart';
import 'package:node_interop/util.dart';
import 'package:node_io/node_io.dart';

/// HTTP client which uses Node.js I/O system.
///
/// Make sure to call [close] when work with this client is done.
class NodeClient extends BaseClient {
  /// Keep sockets around even when there are no outstanding requests, so they
  /// can be used for future requests without having to reestablish a TCP
  /// connection. Defaults to `true`.
  final bool keepAlive;

  /// When using the keepAlive option, specifies the initial delay for TCP
  /// Keep-Alive packets. Ignored when the keepAlive option is false.
  /// Defaults to 1000.
  final int keepAliveMsecs;

  NodeClient({
    this.keepAlive = true,
    this.keepAliveMsecs = 1000,
  });

  /// Native JavaScript connection agent used by this client for insecure
  /// requests.
  nodeHttp.HttpAgent get httpAgent =>
      _httpAgent ??= nodeHttp.createHttpAgent(new nodeHttp.HttpAgentOptions(
        keepAlive: keepAlive,
        keepAliveMsecs: keepAliveMsecs,
      ));
  nodeHttp.HttpAgent _httpAgent;

  /// Native JavaScript connection agent used by this client for secure
  /// requests.
  nodeHttp.HttpAgent get httpsAgent =>
      _httpsAgent ??= nodeHttps.createHttpsAgent(new nodeHttp.HttpAgentOptions(
        keepAlive: keepAlive,
        keepAliveMsecs: keepAliveMsecs,
      ));
  nodeHttp.HttpAgent _httpsAgent;

  @override
  Future<Response> send(Request request) {
    final handler = new _RequestHandler(this, request);
    return handler.send();
  }

  @override
  void close() {
    httpAgent.destroy();
    httpsAgent.destroy();
  }
}

class _RequestHandler {
  final NodeClient client;
  final Request request;

  _RequestHandler(this.client, this.request);

  final List<_RedirectInfo> _redirects = new List();

  List<int> _body;
  var _headers;

  Future<Response> send() async {
    _headers = jsify(request.headers);
    _body = await request.readAsBytes();
    var context = request.context;

    final followRedirects = context['http.io.follow_redirects'] ?? true;
    final maxRedirects = context['http.io.max_redirects'] ?? 5;
    var isRedirect = request.context['http.io.is_redirect'] ?? false;

    Response response = await _send();
    if (followRedirects && isRedirect) {
      String method = request.method;
      isRedirect = request.context['http.io.is_redirect'] ?? false;
      while (isRedirect) {
        if (_redirects.length < maxRedirects) {
          response = await redirect(response, method);
          isRedirect = request.context['http.io.is_redirect'] ?? false;
          method = _redirects.last.method;
        } else {
          throw new ClientException('Redirect limit exceeded.');
        }
      }
    }
    return response;
  }

  Future<Response> _send({Uri url, String method}) {
    url ??= request.url;
    method ??= request.method;

    var usedAgent =
        (url.scheme == 'http') ? client.httpAgent : client.httpsAgent;
    var sendRequest = (url.scheme == 'http')
        ? nodeHttp.http.request
        : nodeHttps.https.request;

    var pathWithQuery =
        url.hasQuery ? [url.path, '?', url.query].join() : url.path;
    var options = new nodeHttp.RequestOptions(
      protocol: "${url.scheme}:",
      hostname: url.host,
      port: url.port,
      method: method,
      path: pathWithQuery,
      headers: _headers,
      agent: usedAgent,
    );
    var completer = new Completer<Response>();

    void handleResponse(nodeHttp.IncomingMessage response) {
      final rawHeaders = dartify(response.headers) as Map<String, dynamic>;
      final headers = new Map<String, String>();
      for (var key in rawHeaders.keys) {
        final value = rawHeaders[key];
        headers[key] = (value is List) ? value.join(',') : value;
      }
      final controller = new StreamController<List<int>>();
      completer.complete(new Response(
        response.url,
        response.statusCode,
        body: controller.stream,
        headers: headers,
        reasonPhrase: response.statusMessage,
        context: <String, Object>{'http.io.is_redirect': isRedirect(response, method)},
      ));

      response.on('data', allowInterop((Iterable<int> buffer) {
        // buffer is an instance of Node's Buffer.
        controller.add(new List.unmodifiable(buffer));
      }));
      response.on('end', allowInterop(() {
        controller.close();
      }));
    }

    var nodeRequest = sendRequest(options, allowInterop(handleResponse));
    nodeRequest.on('error', allowInterop((e) {
      completer.completeError(e);
    }));

    // TODO: Support StreamedRequest by consuming body asynchronously.
    var buffer = Buffer.from(_body);
    nodeRequest.write(buffer);
    nodeRequest.end();

    return completer.future;
  }

  bool isRedirect(nodeHttp.IncomingMessage message, String method) {
    final statusCode = message.statusCode;
    if (method == "GET" || method == "HEAD") {
      return statusCode == HttpStatus.movedPermanently ||
          statusCode == HttpStatus.found ||
          statusCode == HttpStatus.seeOther ||
          statusCode == HttpStatus.temporaryRedirect;
    } else if (method == "POST") {
      return statusCode == HttpStatus.seeOther;
    }
    return false;
  }

  Future<Response> redirect(Response response,
      [String method, bool followLoops]) {
    // Set method as defined by RFC 2616 section 10.3.4.
    if (response.statusCode == HttpStatus.seeOther && method == "POST") {
      method = "GET";
    }

    String location = response.headers[HttpHeaders.locationHeader];
    if (location == null) {
      throw new StateError("Response has no Location header for redirect.");
    }
    final url = Uri.parse(location);

    if (followLoops != true) {
      for (var redirect in _redirects) {
        if (redirect.location == url) {
          return new Future.error(
              new ClientException("Redirect loop detected."));
        }
      }
    }

    return _send(url: url, method: method).then((response) {
      _redirects.add(new _RedirectInfo(response.statusCode, method, url));
      return response;
    });
  }
}

class _RedirectInfo {
  final int statusCode;
  final String method;
  final Uri location;
  const _RedirectInfo(this.statusCode, this.method, this.location);
}
