import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Narrow ESC/POS raster sender for LAN printers supporting GS v 0.
/// Certain modern devices require GS ( L instead; test hardware model first.
/// Raw TCP 9100 is unencrypted: use only an isolated, trusted printer VLAN.
class LanEscPosPrinter {
  static const port=9100;
  static const maxImageHeight=10000;

  static String validateHost(String raw) {
    final host=raw.trim();
    if(host.isEmpty || host.length>15 ||
        !RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) {
      throw const FormatException('أدخل عنوان IPv4 محليًا للطابعة، بدون اسم أو رابط');
    }
    final parts=host.split('.').map(int.parse).toList();
    if(parts.any((x)=>x>255)) {
      throw const FormatException('عنوان IP غير صالح للطابعة');
    }
    final privateRange=parts[0]==10 ||
        (parts[0]==172 && parts[1]>=16 && parts[1]<=31) ||
        (parts[0]==192 && parts[1]==168);
    final testLoopback=parts[0]==127 && parts[1]==0 &&
        parts[2]==0 && parts[3]==1;
    if(!privateRange && !testLoopback) {
      throw const FormatException('الطباعة مباشرة متاحة فقط لشبكة LAN خاصة');
    }
    if((parts[3]==0 || parts[3]==255) && !testLoopback) {
      throw const FormatException('اختر عنوان جهاز طابعة صالح');
    }
    return parts.join('.');
  }

  /// Encode raw RGBA8888 bytes to 1-bit GS v 0 bands.
  /// One dot equals one pixel. High bit is the leftmost dot in each byte.
  /// Alpha is composited on white before thresholding the luminance.
  static Uint8List encodeRaster(Uint8List rgba,{
    required int imageWidth,
    required int imageHeight,
    int paperDots=576,
    int bandHeight=128,
    int threshold=180,
    bool cut=false,
  }) {
    if((paperDots!=384 && paperDots!=576) ||
        imageWidth<=0 || imageWidth>paperDots ||
        imageHeight<=0 || imageHeight>maxImageHeight ||
        bandHeight<1 || bandHeight>512 ||
        threshold<1 || threshold>254 ||
        rgba.length!=imageWidth*imageHeight*4) {
      throw const FormatException('أبعاد أو محتوى صورة الإيصال غير صالح');
    }
    final rowBytes=paperDots~/8;
    final out=BytesBuilder(copy:false);
    out.add(const [0x1b,0x40,0x1b,0x61,0x01]);
    final byteBuffer=Uint8List(rowBytes*bandHeight);
    for(var start=0;start<imageHeight;start+=bandHeight) {
      final rows=(imageHeight-start<bandHeight)
        ?imageHeight-start:bandHeight;
      byteBuffer.fillRange(0,rows*rowBytes,0);
      for(var y=0;y<rows;y++) {
        final offset=(start+y)*imageWidth*4;
        final rowStart=y*rowBytes;
        for(var x=0;x<imageWidth;x++) {
          final pixel=offset+x*4;
          final alpha=rgba[pixel+3];
          final red=(rgba[pixel]*alpha+255*(255-alpha))~/255;
          final green=(rgba[pixel+1]*alpha+255*(255-alpha))~/255;
          final blue=(rgba[pixel+2]*alpha+255*(255-alpha))~/255;
          final luminance=(red*299+green*587+blue*114)~/1000;
          if(luminance<threshold) {
            byteBuffer[rowStart+(x~/8)]|=0x80>>(x%8);
          }
        }
      }
      out.add([0x1d,0x76,0x30,0x00,
        rowBytes&0xff,(rowBytes>>8)&0xff,
        rows&0xff,(rows>>8)&0xff]);
      out.add(Uint8List.sublistView(byteBuffer,0,rows*rowBytes));
    }
    out.add(const [0x1b,0x64,0x03]);
    if(cut)out.add(const [0x1d,0x56,0x00]);
    return out.takeBytes();
  }

  /// TCP flush confirms OS socket acceptance, NOT that paper printed.
  /// Never auto-retry ambiguous errors: operator checks paper before reprint.
  static Future<void> send({
    required String host,
    required Uint8List rasterBytes,
    Duration connectTimeout=const Duration(seconds:4),
    Duration writeTimeout=const Duration(seconds:12),
  }) async {
    final ipv4=validateHost(host);
    if(rasterBytes.isEmpty || rasterBytes.length>1024*1024) {
      throw const FormatException('حجم أمر الطباعة يتجاوز الحد الآمن');
    }
    Socket? socket;
    try {
      socket=await Socket.connect(InternetAddress(ipv4),port,
        timeout:connectTimeout);
      socket.add(rasterBytes);
      await socket.flush().timeout(writeTimeout);
      await socket.close().timeout(const Duration(seconds:3));
    } on TimeoutException {
      throw const SocketException('انتهت مهلة إرسال الإيصال إلى الطابعة');
    } finally {
      socket?.destroy();
    }
  }
}
