/// Windows Virtual USB Hub — USB/IP server for forwarding USB data
/// to the usbip-win virtual host controller driver.
///
/// This application:
/// 1. Listens on 127.0.0.1:3240 as a TCP server
/// 2. Accepts the Mac client (via SSH tunnel) and performs client handshake
/// 3. Auto-runs `usbip.exe attach` to bind the virtual driver
/// 4. Accepts the usbip.exe connection and performs server handshake
/// 5. Bridges both sockets for bidirectional URB forwarding
///
/// Prerequisites:
///   - usbip-win installed (https://github.com/cezanne/usbip-win)
///   - Test signing enabled: bcdedit /set testsigning on
///   - usbip.exe in PATH
///   - SSH tunnel running with -R 3240:127.0.0.1:3240
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:usbip_protocol/usbip_protocol.dart';

/// Default USBIP port.
const int defaultUsbPort = 3240;

Future<void> main(List<String> args) async {
  // --- Parse CLI options ---
  var port = defaultUsbPort;
  var verbose = false;
  var autoAttach = true;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '-p':
      case '--port':
        if (i + 1 < args.length) {
          port = int.tryParse(args[++i]) ?? defaultUsbPort;
        }
      case '-v':
      case '--verbose':
        verbose = true;
      case '--no-attach':
        autoAttach = false;
      case '-h':
      case '--help':
        _printHelp();
        exit(0);
      default:
        print('Unknown option: ${args[i]}');
        _printHelp();
        exit(1);
    }
  }

  // --- Startup banner ---
  print('╔══════════════════════════════════════════════════════════════╗');
  print('║         Windows Virtual USB Hub — USB/IP Server            ║');
  print('╠══════════════════════════════════════════════════════════════╣');
  print('║ ⚠️  PREREQUISITES:                                         ║');
  print('║                                                            ║');
  print('║ 1. usbip-win installed:                                    ║');
  print('║    https://github.com/cezanne/usbip-win                    ║');
  print('║ 2. Test signing enabled:                                   ║');
  print('║    bcdedit /set testsigning on                              ║');
  print('║ 3. Test certificates installed                             ║');
  print('║ 4. usbip.exe in PATH                                      ║');
  print('║ 5. SSH tunnel active with:                                  ║');
  print('║    -R $port:127.0.0.1:$port                                ║');
  print('╚══════════════════════════════════════════════════════════════╝');
  print('');

  // --- Start TCP server ---
  ServerSocket server;
  try {
    server = await ServerSocket.bind('127.0.0.1', port);
  } on SocketException catch (e) {
    print('❌ Error: Cannot listen on 127.0.0.1:$port.');
    print('   The port may already be in use.');
    print('   Detail: $e');
    exit(1);
  }

  print('✅ USB/IP server listening on 127.0.0.1:$port');

  // =========================================================================
  // STATE 1: Wait for Mac connection & client handshake
  // =========================================================================
  print('⏳ State 1: Waiting for Mac client connection (via SSH tunnel)...\n');

  Socket macSocket;
  try {
    macSocket = await server.first.timeout(Duration(minutes: 5));
  } on TimeoutException {
    print('❌ Timeout: No Mac client connected within 5 minutes.');
    await server.close();
    exit(1);
  }

  var macAddr = '${macSocket.remoteAddress.address}:${macSocket.remotePort}';
  print('🔗 Connection 1 accepted from $macAddr (Mac client)');
  print('📡 State 1: USB/IP client handshake...');

  // Use StreamIterator to read from macSocket — avoids multiple .listen() calls
  var macIterator = StreamIterator(macSocket);
  var macReader = UsbipStreamReader();

  // Step 1a: Send OP_REQ_DEVLIST
  var devlistReq = serializeReqDevlist();
  macSocket.add(devlistReq);
  if (verbose) print('➡️  OP_REQ_DEVLIST sent');

  // Step 1b: Read OP_REP_DEVLIST
  var device = await _readDevlistReply(macIterator, macReader, verbose);
  if (device == null) {
    print('❌ Handshake failed at OP_REP_DEVLIST. Closing.');
    macSocket.destroy();
    await server.close();
    exit(1);
  }

  // Step 1c: Send OP_REQ_IMPORT
  var importReq = serializeReqImport(device.busid);
  macSocket.add(importReq);
  if (verbose) print('➡️  OP_REQ_IMPORT sent (busid: ${device.busid})');

  // Step 1d: Read OP_REP_IMPORT
  var importedDevice = await _readImportReply(macIterator, macReader, verbose);
  if (importedDevice == null) {
    print('❌ Handshake failed at OP_REP_IMPORT. Closing.');
    macSocket.destroy();
    await server.close();
    exit(1);
  }

  print(
    '✅ Mac handshake complete!\n'
    '   Device: VID:${importedDevice.idVendor.toRadixString(16).padLeft(4, '0')} '
    'PID:${importedDevice.idProduct.toRadixString(16).padLeft(4, '0')}\n',
  );

  // =========================================================================
  // STATE 2: Launch usbip.exe attach (non-blocking)
  // =========================================================================
  if (autoAttach) {
    print('🔧 State 2: Launching usbip.exe attach...');
    print(
      '   Command: usbip.exe attach -r 127.0.0.1 -b ${importedDevice.busid}',
    );

    // Launch asynchronously — don't await yet, usbip.exe needs to connect back
    var usbipFuture = Process.run(
      'usbip.exe',
      ['attach', '-r', '127.0.0.1', '-b', importedDevice.busid],
    ).then((result) {
      if (result.exitCode == 0) {
        print('✅ usbip.exe attach succeeded!');
        if (verbose && (result.stdout as String).isNotEmpty) {
          print('   stdout: ${result.stdout}');
        }
      } else {
        print('⚠️  usbip.exe attach exit code: ${result.exitCode}');
        if ((result.stderr as String).isNotEmpty) {
          print('   stderr: ${result.stderr}');
        }
      }
    }).catchError((e) {
      print('⚠️  usbip.exe not found in PATH.');
      print('   Error: $e');
      print('   Make sure usbip-win is installed.');
    });

    // =========================================================================
    // STATE 3: Wait for usbip.exe connection
    // =========================================================================
    print('⏳ State 3: Waiting for usbip.exe to connect...\n');

    Socket usbipSocket;
    try {
      usbipSocket = await server.first.timeout(Duration(seconds: 30));
    } on TimeoutException {
      print('❌ Timeout: usbip.exe did not connect within 30 seconds.');
      macSocket.destroy();
      await server.close();
      exit(1);
    }

    var usbipAddr =
        '${usbipSocket.remoteAddress.address}:${usbipSocket.remotePort}';
    print('🔗 Connection 2 accepted from $usbipAddr (usbip.exe)');

    // =========================================================================
    // STATE 4: Server-side handshake with usbip.exe
    // =========================================================================
    print('📡 State 4: Handling OP_REQ_IMPORT from usbip.exe...');

    var usbipIterator = StreamIterator(usbipSocket);
    var usbipReader = UsbipStreamReader();

    // Read OP_REQ_IMPORT from usbip.exe
    var reqImportSize = opCommonSize + busidSize; // 8 + 32 = 40 bytes
    if (!await _fillReader(usbipIterator, usbipReader, reqImportSize)) {
      print('❌ usbip.exe disconnected before sending OP_REQ_IMPORT.');
      macSocket.destroy();
      usbipSocket.destroy();
      await server.close();
      exit(1);
    }

    var reqBytes = usbipReader.tryRead(reqImportSize)!;
    var reqData = ByteData.sublistView(reqBytes);
    var (_, reqCmd, _) = readOpCommon(reqData);

    if (reqCmd != opReqImport) {
      print(
        '❌ Expected OP_REQ_IMPORT (0x8003) but got 0x${reqCmd.toRadixString(16)}',
      );
      macSocket.destroy();
      usbipSocket.destroy();
      await server.close();
      exit(1);
    }

    var requestedBusid = parseReqImportBusid(reqBytes);
    if (verbose) print('⬅️  OP_REQ_IMPORT received (busid: $requestedBusid)');

    // Respond with OP_REP_IMPORT using device info from State 1
    var repImport = serializeRepImport(importedDevice);
    usbipSocket.add(repImport);
    if (verbose) print('➡️  OP_REP_IMPORT sent to usbip.exe');

    print('✅ usbip.exe handshake complete!\n');

    // Wait for usbip.exe process to finish (it should have returned by now)
    await usbipFuture;

    // =========================================================================
    // STATE 5: Bridge — bidirectional URB forwarding
    // =========================================================================
    print('🚀 State 5: URB bridge active!');
    print('   macSocket ↔ usbipSocket');
    print('   Press Ctrl+C to stop.\n');

    // Drain any leftover data from the StreamIterators into the readers,
    // then set up bridging. Since StreamIterator has already consumed the
    // stream subscription, we need to create broadcast controllers to
    // forward remaining + new data.

    // Forward any leftover buffered data
    _forwardLeftover(macReader, usbipSocket, 'Mac→usbip', verbose);
    _forwardLeftover(usbipReader, macSocket, 'usbip→Mac', verbose);

    // Bridge the streams: forward all future data between the two sockets.
    // Since the StreamIterators have consumed the stream subscription,
    // we continue reading via the iterators and writing to the other socket.
    var macToUsbip = _bridgeIterator(
      macIterator,
      usbipSocket,
      'Mac→usbip',
      verbose,
    );
    var usbipToMac = _bridgeIterator(
      usbipIterator,
      macSocket,
      'usbip→Mac',
      verbose,
    );

    // Wait for either direction to finish (one socket closes)
    try {
      await Future.any([macToUsbip, usbipToMac]);
    } catch (e) {
      print('⚠️  Bridge error: $e');
    }

    print('\n🔴 Bridge closed. Cleaning up...');
    macSocket.destroy();
    usbipSocket.destroy();
  } else {
    print('ℹ️  Auto-attach disabled (--no-attach).');
    print('   Manual forwarding mode — logging incoming Mac data.\n');

    // Simple logging mode when auto-attach is disabled
    var packetCount = 0;
    await for (var data in _iteratorToStream(macIterator, macReader)) {
      packetCount++;
      if (verbose) {
        _logPacket(data, packetCount);
      }
    }
    print('\n🔴 Mac client disconnected. ($packetCount packets)');
  }

  await server.close();
  print('✅ Server shut down.');
}

// ---------------------------------------------------------------------------
// Handshake helpers — read from StreamIterator + UsbipStreamReader
// ---------------------------------------------------------------------------

/// Fill the [reader] buffer until it has at least [needed] bytes,
/// reading chunks from [iterator]. Returns false if the stream ends early.
Future<bool> _fillReader(
  StreamIterator<Uint8List> iterator,
  UsbipStreamReader reader,
  int needed,
) async {
  while (reader.available < needed) {
    if (!await iterator.moveNext()) return false;
    reader.addData(iterator.current);
  }
  return true;
}

/// Read and parse OP_REP_DEVLIST from the Mac client.
Future<UsbipDevice?> _readDevlistReply(
  StreamIterator<Uint8List> iterator,
  UsbipStreamReader reader,
  bool verbose,
) async {
  // Need at least: op_common(8) + ndev(4) = 12 bytes for the header
  if (!await _fillReader(iterator, reader, opCommonSize + 4)) {
    print('❌ Mac disconnected before OP_REP_DEVLIST.');
    return null;
  }

  var peekHeader = reader.peek(opCommonSize + 4)!;
  var peekData = ByteData.sublistView(peekHeader);
  var (_, command, status) = readOpCommon(peekData);
  var ndev = peekData.getUint32(opCommonSize, Endian.big);

  if (command != opRepDevlist) {
    print('❌ Unexpected response: 0x${command.toRadixString(16)}');
    return null;
  }

  if (status != statusOk || ndev == 0) {
    print('❌ OP_REP_DEVLIST: no devices exported.');
    return null;
  }

  // Need: header(12) + device_info(312) + at least 1 interface(4)
  var minSize = opCommonSize + 4 + deviceInfoSize + interfaceInfoSize;
  if (!await _fillReader(iterator, reader, minSize)) {
    print('❌ Mac disconnected during OP_REP_DEVLIST device data.');
    return null;
  }

  // Consume the header
  reader.tryRead(opCommonSize + 4);

  // Parse the first device
  var remaining = reader.peek(reader.available)!;
  var (dev, consumed) = UsbipDevice.deserialize(remaining);
  reader.tryRead(consumed);

  if (verbose) {
    print(
      '⬅️  OP_REP_DEVLIST: ${dev.idVendor.toRadixString(16)}:'
      '${dev.idProduct.toRadixString(16)} '
      '(${dev.busid})',
    );
  }

  return dev;
}

/// Read and parse OP_REP_IMPORT from the Mac client.
Future<UsbipDevice?> _readImportReply(
  StreamIterator<Uint8List> iterator,
  UsbipStreamReader reader,
  bool verbose,
) async {
  // Need: op_common(8) for the header first
  if (!await _fillReader(iterator, reader, opCommonSize)) {
    print('❌ Mac disconnected before OP_REP_IMPORT.');
    return null;
  }

  var peekHeader = reader.peek(opCommonSize)!;
  var peekData = ByteData.sublistView(peekHeader);
  var (_, command, status) = readOpCommon(peekData);

  if (command != opRepImport) {
    print('❌ Unexpected response: 0x${command.toRadixString(16)}');
    return null;
  }

  if (status != statusOk) {
    print('❌ OP_REP_IMPORT: refused by server.');
    reader.tryRead(opCommonSize);
    return null;
  }

  // Need full reply: header(8) + device_info(312)
  var fullSize = opCommonSize + deviceInfoSize;
  if (!await _fillReader(iterator, reader, fullSize)) {
    print('❌ Mac disconnected during OP_REP_IMPORT device data.');
    return null;
  }

  var fullBytes = reader.tryRead(fullSize)!;
  // hasInterfaces: false — OP_REP_IMPORT does NOT include interface
  // descriptors after the device block (unlike OP_REP_DEVLIST).
  var (dev, _) = UsbipDevice.deserialize(fullBytes, opCommonSize, false);

  if (verbose) {
    print(
      '⬅️  OP_REP_IMPORT: success — ${dev.idVendor.toRadixString(16)}:'
      '${dev.idProduct.toRadixString(16)}',
    );
  }

  return dev;
}

// ---------------------------------------------------------------------------
// Bridge helpers
// ---------------------------------------------------------------------------

/// Forward any leftover buffered data from a [reader] to a [target] socket.
void _forwardLeftover(
  UsbipStreamReader reader,
  Socket target,
  String label,
  bool verbose,
) {
  if (reader.available > 0) {
    var leftover = reader.tryRead(reader.available)!;
    target.add(leftover);
    if (verbose) {
      print('📦 $label: forwarded ${leftover.length} buffered bytes');
    }
  }
}

/// Read from [iterator] and write to [target] until the stream ends.
Future<void> _bridgeIterator(
  StreamIterator<Uint8List> iterator,
  Socket target,
  String label,
  bool verbose,
) async {
  var totalBytes = 0;
  var packetCount = 0;
  try {
    while (await iterator.moveNext()) {
      var data = iterator.current;
      target.add(data);
      totalBytes += data.length;
      packetCount++;
      if (verbose && packetCount % 100 == 0) {
        print('📊 $label: $packetCount packets, $totalBytes bytes total');
      }
    }
  } catch (e) {
    print('⚠️  $label error: $e');
  }
  print('🔴 $label: stream ended ($packetCount packets, $totalBytes bytes)');
}

/// Convert a StreamIterator + reader leftover back into a Stream for
/// the simple logging mode (no-attach).
Stream<Uint8List> _iteratorToStream(
  StreamIterator<Uint8List> iterator,
  UsbipStreamReader reader,
) async* {
  // Yield leftover buffered data first
  if (reader.available > 0) {
    yield reader.tryRead(reader.available)!;
  }
  // Then yield from the iterator
  while (await iterator.moveNext()) {
    yield iterator.current;
  }
}

/// Log a packet for verbose mode.
void _logPacket(Uint8List data, int packetCount) {
  var preview = data.length > 48 ? data.sublist(0, 48) : data;
  var hex =
      preview.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  print(
    '⬅️  [#$packetCount] RX ${data.length} bytes: $hex'
    '${data.length > 48 ? '...' : ''}',
  );

  if (data.length >= headerBasicSize) {
    var headerData = ByteData.sublistView(Uint8List.fromList(data));
    var cmd = headerData.getUint32(0, Endian.big);
    var seqnum = headerData.getUint32(4, Endian.big);
    var cmdName = _commandName(cmd);
    print('   📋 $cmdName seq=$seqnum');
  }
}

String _commandName(int cmd) {
  switch (cmd) {
    case usbipCmdSubmit:
      return 'CMD_SUBMIT';
    case usbipRetSubmit:
      return 'RET_SUBMIT';
    case usbipCmdUnlink:
      return 'CMD_UNLINK';
    case usbipRetUnlink:
      return 'RET_UNLINK';
    default:
      return 'UNKNOWN(0x${cmd.toRadixString(16)})';
  }
}

void _printHelp() {
  print('Windows Virtual USB Hub — USB/IP Server.\n');
  print('Usage: dart run bin/windows_virtual_usb.dart [options]\n');
  print('Options:');
  print('  -p, --port <port>   Local TCP port (default: $defaultUsbPort)');
  print('  -v, --verbose       Enable detailed logging');
  print('  --no-attach         Do not auto-run usbip.exe attach');
  print('  -h, --help          Show this help\n');
  print('Prerequisites:');
  print('  1. usbip-win installed (github.com/cezanne/usbip-win)');
  print('  2. Test signing enabled: bcdedit /set testsigning on');
  print(
    '  3. SSH tunnel with: -R $defaultUsbPort:127.0.0.1:$defaultUsbPort',
  );
}
