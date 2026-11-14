import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasher_app/services/lan_escpos_printer.dart';

void setPixel(Uint8List rgba,int width,int x,int y,{
  required int red,required int green,required int blue,int alpha=255
}) {
  final offset=(y*width+x)*4;
  rgba[offset]=red;rgba[offset+1]=green;
  rgba[offset+2]=blue;rgba[offset+3]=alpha;
}

void main(){
  test('ESC/POS raster respects MSB-first dot order and exact header',(){
    final rgba=Uint8List(384*4);
    rgba.fillRange(0,rgba.length,255);
    for(final x in [0,7,8,383]){
      setPixel(rgba,384,x,0,red:0,green:0,blue:0);
    }
    final packet=LanEscPosPrinter.encodeRaster(rgba,
      imageWidth:384,imageHeight:1,paperDots:384);
    expect(packet.sublist(0,5),[0x1b,0x40,0x1b,0x61,0x01]);
    expect(packet.sublist(5,13),[0x1d,0x76,0x30,0x00,48,0,1,0]);
    expect(packet.length,5+8+48+3);
    expect(packet[13],0x81);
    expect(packet[14],0x80);
    expect(packet[13+47],0x01);
    expect(packet.sublist(packet.length-3),[0x1b,0x64,0x03]);
  });

  test('semi-transparent pixels composite on white; no unintended cut',(){
    final rgba=Uint8List.fromList([
      0,0,0,0, // black but transparent -> white
      0,0,0,255, // black opaque -> print
      255,255,255,255, // white -> skip
      0,0,0,100, // light composited -> skip
    ]);
    final packet=LanEscPosPrinter.encodeRaster(rgba,
      imageWidth:4,imageHeight:1,paperDots:576,cut:true);
    expect(packet.sublist(5,13),[0x1d,0x76,0x30,0x00,72,0,1,0]);
    expect(packet[13],0x40);
    expect(packet.sublist(packet.length-3),[0x1d,0x56,0]);
  });

  test('raster splits long receipts into bounded 128-row printer commands',(){
    final pixels=Uint8List(384*260*4);
    pixels.fillRange(0,pixels.length,255);
    final packet=LanEscPosPrinter.encodeRaster(pixels,
      imageWidth:384,imageHeight:260,paperDots:384,bandHeight:128);
    final one=48*128+8;
    expect(packet.length,5+one+one+(48*4+8)+3);
    expect(packet.sublist(5,13),[0x1d,0x76,0x30,0,48,0,128,0]);
    expect(packet.sublist(5+one,13+one),
      [0x1d,0x76,0x30,0,48,0,128,0]);
    expect(packet.sublist(5+one*2,13+one*2),
      [0x1d,0x76,0x30,0,48,0,4,0]);
  });

  test('printer network only permits private IPv4 and exact local test host',(){
    expect(LanEscPosPrinter.validateHost(' 192.168.1.22 '),'192.168.1.22');
    expect(LanEscPosPrinter.validateHost('172.16.0.4'),'172.16.0.4');
    expect(LanEscPosPrinter.validateHost('172.31.255.254'),'172.31.255.254');
    expect(LanEscPosPrinter.validateHost('10.23.1.8'),'10.23.1.8');
    expect(LanEscPosPrinter.validateHost('127.0.0.1'),'127.0.0.1');
    for(final bad in [
      '', 'printer.local','https://192.168.1.10','8.8.8.8',
      '1.1.1.1','172.15.0.1','172.32.1.2','169.254.1.1',
      '192.168.0.0','192.168.1.255','192.168.1.400',
      '224.0.0.1','::1','192.168.1.8:9100','0.0.0.0','127.0.0.2'
    ]){
      expect(()=>LanEscPosPrinter.validateHost(bad),throwsFormatException,
        reason:'not private printer host: '+bad);
    }
  });

  test('malformed raster dimensions and buffer lengths fail before print',(){
    final rgba=Uint8List(32);
    expect(()=>LanEscPosPrinter.encodeRaster(rgba,
      imageWidth:8,imageHeight:1,paperDots:512),throwsFormatException);
    expect(()=>LanEscPosPrinter.encodeRaster(rgba,
      imageWidth:385,imageHeight:1,paperDots:384),throwsFormatException);
    expect(()=>LanEscPosPrinter.encodeRaster(rgba,
      imageWidth:8,imageHeight:10001,paperDots:384),throwsFormatException);
    expect(()=>LanEscPosPrinter.encodeRaster(rgba,
      imageWidth:8,imageHeight:1,paperDots:384,bandHeight:0),
      throwsFormatException);
    expect(()=>LanEscPosPrinter.encodeRaster(Uint8List(31),
      imageWidth:8,imageHeight:1,paperDots:384),throwsFormatException);
  });

  test('TCP spool integration against a temporary loopback fake printer',() async {
    final fake=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);
    try {
      final collected=fake.first.then((printer) async {
        final output=<int>[];
        await for(final data in printer){output.addAll(data);}
        return output;
      });
      final socket=await Socket.connect(InternetAddress.loopbackIPv4,fake.port);
      final payload=Uint8List.fromList([0x1b,0x40,0x1d,0x76,0x30,0x00,
        0x30,0,1,0,0x80,0x1b,0x64,3]);
      await LanEscPosPrinter.writeToSocket(socket,payload);
      expect(await collected,payload);
    }finally{
      await fake.close();
    }
  });
}
