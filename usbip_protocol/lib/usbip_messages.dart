/// USB/IP protocol v1.1.1 message serialization and deserialization.
///
/// All messages use big-endian (network) byte order.
/// Based on https://docs.kernel.org/usb/usbip_protocol.html
library;

import 'dart:typed_data';

import 'usbip_constants.dart';

export 'usbip_constants.dart';

// ---------------------------------------------------------------------------
// Device info — used in DEVLIST and IMPORT replies
// ---------------------------------------------------------------------------

/// USB device information block sent in OP_REP_DEVLIST and OP_REP_IMPORT.
class UsbipDevice {
  String path;
  String busid;
  int busnum;
  int devnum;
  int speed;
  int idVendor;
  int idProduct;
  int bcdDevice;
  int bDeviceClass;
  int bDeviceSubClass;
  int bDeviceProtocol;
  int bConfigurationValue;
  int bNumConfigurations;
  int bNumInterfaces;
  List<UsbipInterface> interfaces;

  UsbipDevice({
    this.path = '/sys/devices/usb/1-1',
    this.busid = '1-1',
    this.busnum = 1,
    this.devnum = 1,
    this.speed = usbSpeedHigh,
    this.idVendor = 0,
    this.idProduct = 0,
    this.bcdDevice = 0,
    this.bDeviceClass = 0,
    this.bDeviceSubClass = 0,
    this.bDeviceProtocol = 0,
    this.bConfigurationValue = 1,
    this.bNumConfigurations = 1,
    this.bNumInterfaces = 1,
    List<UsbipInterface>? interfaces,
  }) : interfaces = interfaces ?? [UsbipInterface()];

  /// Serialize this device info into the wire format (312 bytes + 4*numInterfaces).
  Uint8List serialize() {
    var totalSize = deviceInfoSize + bNumInterfaces * interfaceInfoSize;
    var data = ByteData(totalSize);
    var offset = 0;

    // path (256 bytes, zero-padded)
    var pathBytes = Uint8List(pathSize);
    var pathStr = path.codeUnits;
    for (var i = 0; i < pathStr.length && i < pathSize - 1; i++) {
      pathBytes[i] = pathStr[i];
    }
    var result = Uint8List(totalSize);
    result.setRange(0, pathSize, pathBytes);
    offset += pathSize;

    // busid (32 bytes, zero-padded)
    var busidBytes = Uint8List(busidSize);
    var busidStr = busid.codeUnits;
    for (var i = 0; i < busidStr.length && i < busidSize - 1; i++) {
      busidBytes[i] = busidStr[i];
    }
    result.setRange(offset, offset + busidSize, busidBytes);
    offset += busidSize;

    // Numeric fields — use ByteData for big-endian
    data = ByteData.sublistView(result);
    data.setUint32(offset, busnum, Endian.big);
    offset += 4;
    data.setUint32(offset, devnum, Endian.big);
    offset += 4;
    data.setUint32(offset, speed, Endian.big);
    offset += 4;
    data.setUint16(offset, idVendor, Endian.big);
    offset += 2;
    data.setUint16(offset, idProduct, Endian.big);
    offset += 2;
    data.setUint16(offset, bcdDevice, Endian.big);
    offset += 2;
    data.setUint8(offset++, bDeviceClass);
    data.setUint8(offset++, bDeviceSubClass);
    data.setUint8(offset++, bDeviceProtocol);
    data.setUint8(offset++, bConfigurationValue);
    data.setUint8(offset++, bNumConfigurations);
    data.setUint8(offset++, bNumInterfaces);

    // Interface descriptors (4 bytes each)
    for (var iface in interfaces) {
      data.setUint8(offset++, iface.bInterfaceClass);
      data.setUint8(offset++, iface.bInterfaceSubClass);
      data.setUint8(offset++, iface.bInterfaceProtocol);
      data.setUint8(offset++, 0); // padding
    }

    return result;
  }

  /// Deserialize a device info block from [bytes] starting at [start].
  ///
  /// When [hasInterfaces] is `true` (the default, used for OP_REP_DEVLIST),
  /// the interface descriptors that follow the 312-byte device block are read.
  /// Set [hasInterfaces] to `false` for OP_REP_IMPORT, which does NOT include
  /// interface descriptors after the device block per the USB/IP spec.
  ///
  /// Returns the device and the number of bytes consumed.
  static (UsbipDevice, int) deserialize(
    Uint8List bytes, [
    int start = 0,
    bool hasInterfaces = true,
  ]) {
    var data = ByteData.sublistView(bytes);
    var offset = start;

    var path = _readZeroString(bytes, offset, pathSize);
    offset += pathSize;
    var busid = _readZeroString(bytes, offset, busidSize);
    offset += busidSize;

    var dev = UsbipDevice(
      path: path,
      busid: busid,
      busnum: data.getUint32(offset, Endian.big),
      devnum: data.getUint32(offset + 4, Endian.big),
      speed: data.getUint32(offset + 8, Endian.big),
      idVendor: data.getUint16(offset + 12, Endian.big),
      idProduct: data.getUint16(offset + 14, Endian.big),
      bcdDevice: data.getUint16(offset + 16, Endian.big),
      bDeviceClass: data.getUint8(offset + 18),
      bDeviceSubClass: data.getUint8(offset + 19),
      bDeviceProtocol: data.getUint8(offset + 20),
      bConfigurationValue: data.getUint8(offset + 21),
      bNumConfigurations: data.getUint8(offset + 22),
      bNumInterfaces: data.getUint8(offset + 23),
      interfaces: [],
    );
    offset += 24; // 6*4 + 3*2 + 6*1 = 24 bytes of numeric fields

    // Interface descriptors are only present in OP_REP_DEVLIST,
    // NOT in OP_REP_IMPORT (per USB/IP protocol spec).
    if (hasInterfaces) {
      for (var i = 0; i < dev.bNumInterfaces; i++) {
        dev.interfaces.add(UsbipInterface(
          bInterfaceClass: data.getUint8(offset),
          bInterfaceSubClass: data.getUint8(offset + 1),
          bInterfaceProtocol: data.getUint8(offset + 2),
        ));
        offset += interfaceInfoSize;
      }
    }

    return (dev, offset - start);
  }
}

/// USB interface info block (4 bytes each in DEVLIST).
class UsbipInterface {
  final int bInterfaceClass;
  final int bInterfaceSubClass;
  final int bInterfaceProtocol;

  UsbipInterface({
    this.bInterfaceClass = 0,
    this.bInterfaceSubClass = 0,
    this.bInterfaceProtocol = 0,
  });
}

// ---------------------------------------------------------------------------
// Op common header (8 bytes)
// ---------------------------------------------------------------------------

/// Write the op_common header (version + command + status) at [offset] in [data].
void writeOpCommon(ByteData data, int offset, int command, int status) {
  data.setUint16(offset, usbipVersion, Endian.big);
  data.setUint16(offset + 2, command, Endian.big);
  data.setUint32(offset + 4, status, Endian.big);
}

/// Read the op_common header fields: (version, command, status).
(int, int, int) readOpCommon(ByteData data, [int offset = 0]) {
  return (
    data.getUint16(offset, Endian.big),
    data.getUint16(offset + 2, Endian.big),
    data.getUint32(offset + 4, Endian.big),
  );
}

// ---------------------------------------------------------------------------
// OP_REQ_DEVLIST / OP_REP_DEVLIST
// ---------------------------------------------------------------------------

/// Serialize an OP_REQ_DEVLIST request (8 bytes).
Uint8List serializeReqDevlist() {
  var bytes = Uint8List(opCommonSize);
  var data = ByteData.sublistView(bytes);
  writeOpCommon(data, 0, opReqDevlist, 0);
  return bytes;
}

/// Serialize an OP_REP_DEVLIST reply with the given devices.
Uint8List serializeRepDevlist(List<UsbipDevice> devices) {
  // Calculate total size
  var devicesData = <Uint8List>[];
  for (var dev in devices) {
    devicesData.add(dev.serialize());
  }
  var devicesSize = devicesData.fold<int>(0, (sum, d) => sum + d.length);
  var totalSize = opCommonSize + 4 + devicesSize; // header + ndev + devices

  var bytes = Uint8List(totalSize);
  var data = ByteData.sublistView(bytes);
  writeOpCommon(data, 0, opRepDevlist, statusOk);
  data.setUint32(opCommonSize, devices.length, Endian.big);

  var offset = opCommonSize + 4;
  for (var devData in devicesData) {
    bytes.setRange(offset, offset + devData.length, devData);
    offset += devData.length;
  }

  return bytes;
}

// ---------------------------------------------------------------------------
// OP_REQ_IMPORT / OP_REP_IMPORT
// ---------------------------------------------------------------------------

/// Serialize an OP_REQ_IMPORT request for the given busid.
Uint8List serializeReqImport(String busid) {
  var bytes = Uint8List(opCommonSize + busidSize);
  var data = ByteData.sublistView(bytes);
  writeOpCommon(data, 0, opReqImport, 0);
  var busidStr = busid.codeUnits;
  for (var i = 0; i < busidStr.length && i < busidSize - 1; i++) {
    bytes[opCommonSize + i] = busidStr[i];
  }
  return bytes;
}

/// Parse the busid from an OP_REQ_IMPORT message.
String parseReqImportBusid(Uint8List bytes) {
  return _readZeroString(bytes, opCommonSize, busidSize);
}

/// Serialize an OP_REP_IMPORT reply (success with device, or error).
Uint8List serializeRepImport(UsbipDevice? device) {
  if (device == null) {
    // Error reply: just the header with status=1
    var bytes = Uint8List(opCommonSize);
    var data = ByteData.sublistView(bytes);
    writeOpCommon(data, 0, opRepImport, statusError);
    return bytes;
  }

  // Success: header + device info (without interface list)
  var devSize = deviceInfoSize; // No interface info in IMPORT reply
  var bytes = Uint8List(opCommonSize + devSize);
  var data = ByteData.sublistView(bytes);
  writeOpCommon(data, 0, opRepImport, statusOk);

  // Write device info (serialize full device, take only 312 bytes)
  var devBytes = device.serialize();
  bytes.setRange(opCommonSize, opCommonSize + devSize, devBytes);

  return bytes;
}

// ---------------------------------------------------------------------------
// usbip_header_basic (20 bytes)
// ---------------------------------------------------------------------------

/// The 20-byte basic header common to all URB commands.
class UsbipHeaderBasic {
  int command;
  int seqnum;
  int devid;
  int direction;
  int ep;

  UsbipHeaderBasic({
    required this.command,
    required this.seqnum,
    this.devid = 0x00010001, // default: bus 1, dev 1
    this.direction = usbipDirOut,
    this.ep = 0,
  });

  void writeTo(ByteData data, int offset) {
    data.setUint32(offset, command, Endian.big);
    data.setUint32(offset + 4, seqnum, Endian.big);
    data.setUint32(offset + 8, devid, Endian.big);
    data.setUint32(offset + 12, direction, Endian.big);
    data.setUint32(offset + 16, ep, Endian.big);
  }

  static UsbipHeaderBasic readFrom(ByteData data, [int offset = 0]) {
    return UsbipHeaderBasic(
      command: data.getUint32(offset, Endian.big),
      seqnum: data.getUint32(offset + 4, Endian.big),
      devid: data.getUint32(offset + 8, Endian.big),
      direction: data.getUint32(offset + 12, Endian.big),
      ep: data.getUint32(offset + 16, Endian.big),
    );
  }
}

// ---------------------------------------------------------------------------
// CMD_SUBMIT (client → server)
// ---------------------------------------------------------------------------

/// USBIP_CMD_SUBMIT: submit a URB.
/// Header is 48 bytes, followed by optional transfer_buffer for OUT transfers.
class CmdSubmit {
  final UsbipHeaderBasic header;
  final int transferFlags;
  final int transferBufferLength;
  final int startFrame;
  final int numberOfPackets;
  final int interval;
  final Uint8List setup; // 8 bytes
  final Uint8List transferBuffer; // only for OUT direction

  CmdSubmit({
    required this.header,
    this.transferFlags = 0,
    required this.transferBufferLength,
    this.startFrame = 0,
    this.numberOfPackets = 0xFFFFFFFF, // not ISO
    this.interval = 0,
    Uint8List? setup,
    Uint8List? transferBuffer,
  })  : setup = setup ?? Uint8List(8),
        transferBuffer = transferBuffer ?? Uint8List(0);

  /// Serialize to wire format.
  Uint8List serialize() {
    var bufLen =
        header.direction == usbipDirOut ? transferBuffer.length : 0;
    var bytes = Uint8List(usbipHeaderSize + bufLen);
    var data = ByteData.sublistView(bytes);

    header.writeTo(data, 0);
    data.setUint32(0x14, transferFlags, Endian.big);
    data.setUint32(0x18, transferBufferLength, Endian.big);
    data.setUint32(0x1C, startFrame, Endian.big);
    data.setUint32(0x20, numberOfPackets, Endian.big);
    data.setUint32(0x24, interval, Endian.big);

    // setup bytes (8 bytes at offset 0x28)
    for (var i = 0; i < 8 && i < setup.length; i++) {
      bytes[0x28 + i] = setup[i];
    }

    // transfer buffer (only for OUT)
    if (bufLen > 0) {
      bytes.setRange(usbipHeaderSize, usbipHeaderSize + bufLen, transferBuffer);
    }

    return bytes;
  }

  /// Deserialize from wire format.
  static CmdSubmit deserialize(Uint8List bytes) {
    var data = ByteData.sublistView(bytes);
    var basic = UsbipHeaderBasic.readFrom(data);

    var transferBufferLength = data.getUint32(0x18, Endian.big);

    var setup = Uint8List(8);
    for (var i = 0; i < 8; i++) {
      setup[i] = bytes[0x28 + i];
    }

    Uint8List transferBuffer;
    if (basic.direction == usbipDirOut && bytes.length > usbipHeaderSize) {
      var bufLen = bytes.length - usbipHeaderSize;
      transferBuffer = Uint8List.fromList(
        bytes.sublist(usbipHeaderSize, usbipHeaderSize + bufLen),
      );
    } else {
      transferBuffer = Uint8List(0);
    }

    return CmdSubmit(
      header: basic,
      transferFlags: data.getUint32(0x14, Endian.big),
      transferBufferLength: transferBufferLength,
      startFrame: data.getUint32(0x1C, Endian.big),
      numberOfPackets: data.getUint32(0x20, Endian.big),
      interval: data.getUint32(0x24, Endian.big),
      setup: setup,
      transferBuffer: transferBuffer,
    );
  }
}

// ---------------------------------------------------------------------------
// RET_SUBMIT (server → client)
// ---------------------------------------------------------------------------

/// USBIP_RET_SUBMIT: response for a submitted URB.
/// Header is 48 bytes, followed by optional transfer_buffer for IN transfers.
class RetSubmit {
  final UsbipHeaderBasic header;
  final int status;
  final int actualLength;
  final int startFrame;
  final int numberOfPackets;
  final int errorCount;
  final Uint8List transferBuffer; // only for IN direction

  RetSubmit({
    required this.header,
    this.status = 0,
    required this.actualLength,
    this.startFrame = 0,
    this.numberOfPackets = 0xFFFFFFFF,
    this.errorCount = 0,
    Uint8List? transferBuffer,
  }) : transferBuffer = transferBuffer ?? Uint8List(0);

  /// Serialize to wire format.
  Uint8List serialize() {
    var bufLen =
        header.direction == usbipDirIn ? transferBuffer.length : 0;
    var bytes = Uint8List(usbipHeaderSize + bufLen);
    var data = ByteData.sublistView(bytes);

    header.writeTo(data, 0);
    data.setInt32(0x14, status, Endian.big);
    data.setUint32(0x18, actualLength, Endian.big);
    data.setUint32(0x1C, startFrame, Endian.big);
    data.setUint32(0x20, numberOfPackets, Endian.big);
    data.setUint32(0x24, errorCount, Endian.big);
    // padding at 0x28 (8 bytes of zeros — already zero-initialized)

    if (bufLen > 0) {
      bytes.setRange(usbipHeaderSize, usbipHeaderSize + bufLen, transferBuffer);
    }

    return bytes;
  }

  /// Deserialize from wire format.
  static RetSubmit deserialize(Uint8List bytes) {
    var data = ByteData.sublistView(bytes);
    var basic = UsbipHeaderBasic.readFrom(data);

    var actualLength = data.getUint32(0x18, Endian.big);

    Uint8List transferBuffer;
    if (basic.direction == usbipDirIn && bytes.length > usbipHeaderSize) {
      var bufLen = bytes.length - usbipHeaderSize;
      transferBuffer = Uint8List.fromList(
        bytes.sublist(usbipHeaderSize, usbipHeaderSize + bufLen),
      );
    } else {
      transferBuffer = Uint8List(0);
    }

    return RetSubmit(
      header: basic,
      status: data.getInt32(0x14, Endian.big),
      actualLength: actualLength,
      startFrame: data.getUint32(0x1C, Endian.big),
      numberOfPackets: data.getUint32(0x20, Endian.big),
      errorCount: data.getUint32(0x24, Endian.big),
      transferBuffer: transferBuffer,
    );
  }
}

// ---------------------------------------------------------------------------
// CMD_UNLINK / RET_UNLINK
// ---------------------------------------------------------------------------

/// Serialize a CMD_UNLINK message (48 bytes).
Uint8List serializeCmdUnlink(int seqnum, int unlinkSeqnum, {int devid = 0x00010001}) {
  var bytes = Uint8List(usbipHeaderSize);
  var data = ByteData.sublistView(bytes);
  var basic = UsbipHeaderBasic(
    command: usbipCmdUnlink,
    seqnum: seqnum,
    devid: devid,
  );
  basic.writeTo(data, 0);
  data.setUint32(0x14, unlinkSeqnum, Endian.big);
  // rest is padding (zeros)
  return bytes;
}

/// Serialize a RET_UNLINK message (48 bytes).
Uint8List serializeRetUnlink(int seqnum, int status) {
  var bytes = Uint8List(usbipHeaderSize);
  var data = ByteData.sublistView(bytes);
  var basic = UsbipHeaderBasic(
    command: usbipRetUnlink,
    seqnum: seqnum,
    devid: 0,
  );
  basic.writeTo(data, 0);
  data.setInt32(0x14, status, Endian.big);
  return bytes;
}

// ---------------------------------------------------------------------------
// Stream helper — read exactly N bytes from a socket
// ---------------------------------------------------------------------------

/// Accumulates data from a socket stream and provides message-level reads.
class UsbipStreamReader {
  final List<int> _buffer = [];

  /// Add incoming data to the internal buffer.
  void addData(List<int> data) {
    _buffer.addAll(data);
  }

  /// Number of bytes currently buffered.
  int get available => _buffer.length;

  /// Try to read exactly [count] bytes. Returns null if not enough data yet.
  Uint8List? tryRead(int count) {
    if (_buffer.length < count) return null;
    var result = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return result;
  }

  /// Peek at [count] bytes without consuming them.
  Uint8List? peek(int count) {
    if (_buffer.length < count) return null;
    return Uint8List.fromList(_buffer.sublist(0, count));
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Read a zero-terminated string from [bytes] starting at [offset] with max [len].
String _readZeroString(Uint8List bytes, int offset, int len) {
  var end = offset + len;
  if (end > bytes.length) end = bytes.length;
  var sb = StringBuffer();
  for (var i = offset; i < end; i++) {
    if (bytes[i] == 0) break;
    sb.writeCharCode(bytes[i]);
  }
  return sb.toString();
}
