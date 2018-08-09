// Copyright (c) 2017, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

@TestOn('node')
library http_test;

import 'dart:convert';

import 'package:node_http/node_http.dart' as http;
import 'package:node_io/node_io.dart';
import 'package:test/test.dart';

void main() {
  group('HTTP client', () {
    HttpServer server;

    setUpAll(() async {
      server = await HttpServer.bind('127.0.0.1', 8181);
      server.listen((request) async {
        if (request.uri.path == '/test') {
          String body = await request.map(utf8.decode).join();
          request.response.headers.contentType = ContentType.text;
          request.response.headers.set('X-Foo', 'bar');
          request.response.headers.set('set-cookie',
              ['JSESSIONID=verylongid; Path=/somepath; HttpOnly']);
          request.response.statusCode = HttpStatus.ok;
          if (body != null && body.isNotEmpty) {
            request.response.write(body);
          } else {
            request.response.write('ok');
          }
          request.response.close();
        } else if (request.uri.path == '/redirect-to-test') {
          request.response.statusCode = HttpStatus.movedPermanently;
          request.response.headers
              .set(HttpHeaders.locationHeader, 'http://127.0.0.1:8181/test');
          request.response.close();
        } else if (request.uri.path == '/redirect-loop') {
          request.response.statusCode = HttpStatus.movedPermanently;
          request.response.headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:8181/redirect-loop');
          request.response.close();
        }
      });
    });

    tearDownAll(() async {
      await server.close();
    });

    test('make get request', () async {
      var client = new http.NodeClient();
      var response = await client.get('http://127.0.0.1:8181/test');
      final body = await response.readAsString();
      expect(response.statusCode, 200);
      expect(response.contentLength, greaterThan(0));
      expect(body, equals('ok'));
      expect(response.headers, contains('content-type'));
      expect(response.headers['set-cookie'],
          'JSESSIONID=verylongid; Path=/somepath; HttpOnly');
      client.close();
    });

    test('make post request with a body', () async {
      var client = new http.NodeClient();
      var response =
          await client.post('http://127.0.0.1:8181/test', 'hello');
      final body = await response.readAsString();
      expect(response.statusCode, 200);
      expect(response.contentLength, greaterThan(0));
      expect(body, equals('hello'));
      client.close();
    });

    test('make get request with library-level get method', () async {
      var response = await http.get('http://127.0.0.1:8181/test');
      final body = await response.readAsString();
      expect(response.statusCode, 200);
      expect(response.contentLength, greaterThan(0));

      expect(body, equals('ok'));
      expect(response.headers, contains('content-type'));
      expect(response.headers['set-cookie'],
          'JSESSIONID=verylongid; Path=/somepath; HttpOnly');
    });

    test('follows redirects', () async {
      var client = new http.NodeClient();
      var response = await client.get('http://127.0.0.1:8181/redirect-to-test');
      final body = await response.readAsString();
      expect(response.statusCode, 200);
      expect(response.contentLength, greaterThan(0));
      expect(body, equals('ok'));
      client.close();
    });

    test('fails for redirect loops', () async {
      var client = new http.NodeClient();
      var error;
      try {
        await client.get('http://127.0.0.1:8181/redirect-loop');
      } catch (err) {
        error = err;
      }
      expect(error, isNotNull);
      http.ClientException exception = error;
      expect(exception.message, 'Redirect loop detected.');
      client.close();
    });
  });
}
