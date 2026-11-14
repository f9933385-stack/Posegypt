import 'package:test/test.dart';
import 'package:kasher_server/src/barcode.dart';
void main() {
  test('EAN13 check digit is calculated, never hardcoded', () {
    expect(ean13('210014500750'), '2100145007501');
    expect(validEan13('2100145007501'),isTrue);
    expect(validEan13('2100145007508'),isFalse);
  });
  test('scale layout is configurable', () {
    final decoded=decodeScaleLabel('2100145007501');
    expect(decoded.plu,'00145');
    expect(decoded.weightField,750);
    expect(()=>decodeScaleLabel('2100145007508'),throwsFormatException);
  });
}
