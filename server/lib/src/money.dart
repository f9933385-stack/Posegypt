/// All financial amounts are integers in EGP piasters. Never use floating point
/// to store cash. All quantities are integer thousandths of a base unit.
int prorate(int amount, int numerator, int denominator) {
  if (denominator <= 0 || numerator < 0 || numerator > denominator) {
    throw ArgumentError('Invalid proration');
  }
  return (amount * numerator + denominator ~/ 2) ~/ denominator;
}

int lineAmount(int priceMinor,int quantityMilli) {
  if (priceMinor<0 || quantityMilli<=0) throw ArgumentError('Invalid line');
  return (priceMinor * quantityMilli + 500) ~/ 1000;
}

int taxAmount(int taxableMinor,int taxBasisPoints) {
  if (taxableMinor < 0 || taxBasisPoints < 0 || taxBasisPoints > 10000) throw ArgumentError('Invalid tax');
  return (taxableMinor * taxBasisPoints + 5000) ~/ 10000;
}

int strictInt(Object? input, String label, {int min=0}) {
  if (input is! int || input < min) throw FormatException('$label must be integer >= $min');
  return input;
}

String nonEmpty(Object? v,String label) {
  if (v is! String || v.trim().isEmpty || v.length>250) throw FormatException('Invalid $label');
  return v.trim();
}
