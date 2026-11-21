import 'package:flutter_test/flutter_test.dart';
import 'package:robovolunteers/core/utils/sku_utils.dart';
import 'package:robovolunteers/core/utils/url_utils.dart';

void main() {
  group('SKU Utils Tests', () {
    test('isValidSku correctly identifies official VEX event SKUs', () {
      expect(isValidSku('RE-V5RC-26-9102'), isTrue);
      expect(isValidSku('RE-VIQRC-26-8821'), isTrue);
      expect(isValidSku('RE-VEXU-26-5512'), isTrue);
      expect(isValidSku('VE-V5-26-1001'), isTrue);
      expect(isValidSku('INVALID-SKU'), isFalse);
      expect(isValidSku(''), isFalse);
    });

    test('getSkuProgram extracts correct program names', () {
      expect(getSkuProgram('RE-V5RC-26-9102'), equals('V5RC'));
      expect(getSkuProgram('RE-VIQRC-26-8821'), equals('VIQRC'));
      expect(getSkuProgram('RE-VEXU-26-5512'), equals('VEX U'));
      expect(getSkuProgram('RE-VAIRC-26-1001'), equals('VEX AI'));
    });

    test('UrlUtils formats official VEX Events URLs correctly', () {
      final url = UrlUtils.getVexEventsUrl('RE-V5RC-26-9102');
      expect(url, equals('https://events.vex.com/events/RE-V5RC-26-9102'));
    });
  });
}
