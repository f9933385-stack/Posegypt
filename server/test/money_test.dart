import 'package:test/test.dart';
import 'package:kasher_server/src/money.dart';
void main() {
  test('currency precision and weight', () {
    expect(lineAmount(1250,350),438); // EGP 12.50 * 0.350 = EGP 4.38
    expect(taxAmount(10000,1400),1400);
    expect(prorate(1000,95,100),950);
  });
  test('invalid quantities rejected', () {
    expect(()=>lineAmount(100,0),throwsArgumentError);
    expect(()=>prorate(100,20,0),throwsArgumentError);
  });
}
