import 'package:flutter_test/flutter_test.dart';
import 'package:kasher_app/models/formats.dart';
void main() {
  test('money and quantity are parsed without floating point rounding', () {
    expect(parseMoney('12.50'),1250);
    expect(parseMoney('0.05'),5);
    expect(parseQty('0.350'),350);
    expect(parseQty('10'),10000);
    expect(()=>parseMoney('3.333'),throwsFormatException);
  });
}
