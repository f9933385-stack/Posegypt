/// EAN-13 generation/verification. Internal label layouts and scale protocols
/// are hardware-specific and must be configured/tested per device.
int ean13CheckDigit(String first12) {
  if(!RegExp(r'^\d{12}$').hasMatch(first12)) throw const FormatException('EAN-13 needs 12 digits');
  var sum=0;
  for(var i=0;i<12;i++) {
    sum+=int.parse(first12[i])*(i.isEven?1:3);
  }
  return (10-sum%10)%10;
}
String ean13(String first12)=>'$first12${ean13CheckDigit(first12)}';
bool validEan13(String code)=>RegExp(r'^\d{13}$').hasMatch(code) &&
    ean13CheckDigit(code.substring(0,12))==int.parse(code[12]);

/// A common scale-label layout with 2-digit prefix, 5-digit PLU and 5-digit
/// integer weight field. Unit / decimal divisor MUST match actual scale.
({String plu,int weightField}) decodeScaleLabel(String code,{String prefix='21'}) {
  if(prefix.length!=2 || !validEan13(code) || !code.startsWith(prefix)) {
    throw const FormatException('Invalid or unsupported scale label');
  }
  return (plu:code.substring(2,7),weightField:int.parse(code.substring(7,12)));
}
