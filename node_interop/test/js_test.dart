// Copyright (c) 2018, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

@TestOn('node')

import 'package:node_interop/js.dart';
import 'package:test/test.dart';

void main() {
  group('js', () {
    test('undefined', () {
      var value = returnsUndefined();
      expect(value, undefined);
    });
  });
}

returnsUndefined() {
  return;
}
