/// Mac USB Forwarder — Interactive CLI for USB device forwarding over TCP.
///
/// Captures a real USB device via libusb, encapsulates data in USB/IP
/// protocol frames (CMD_SUBMIT), and sends them through a TCP tunnel.
///
/// Usage:
///   dart run bin/mac_usb_forwarder.dart [options]
///
/// Prerequisites:
///   - libusb installed: brew install libusb
///   - SSH tunnel running: sshnp [args...] -o '-L 3240:127.0.0.1:3240'
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mac_usb_forwarder/cli.dart';
import 'package:mac_usb_forwarder/libusb_ffi.dart';
import 'package:mac_usb_forwarder/usb_device.dart';
import 'package:usbip_protocol/usbip_protocol.dart';

/// Default USBIP port for local SSH tunnel forwarding.
const int defaultUsbPort = 3240;

Future<void> main(List<String> args) async {
  // --- Parse CLI options ---
  var port = defaultUsbPort;
  var verbose = false;

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

  // --- Initialize libusb ---
  printStatus('🔧 Initialisation de libusb...');
  var usb = UsbManager();
  try {
    usb.init();
  } catch (e) {
    printError(
      'Impossible d\'initialiser libusb.\n'
      '   Installez-le avec : brew install libusb\n'
      '   Détail : $e',
    );
    exit(1);
  }

  try {
    // --- Device selection loop ---
    UsbDeviceInfo? selectedDevice;
    List<EndpointInfo> endpoints = [];

    while (selectedDevice == null) {
      var devices = usb.listDevices();
      printDeviceList(devices);

      if (devices.isEmpty) {
        usb.dispose();
        exit(1);
      }

      var selection = promptDeviceSelection(devices.length);
      if (selection < 0) {
        printStatus('👋 Au revoir.');
        usb.dispose();
        exit(0);
      }

      var device = devices[selection];
      printStatus(
        '\n📌 Sélectionné : ${device.manufacturer} ${device.product} (${device.vidPid})',
      );

      try {
        usb.openDevice(device);
        printStatus('✅ Périphérique ouvert et interface réclamée.');

        endpoints = usb.getEndpoints(device);
        printEndpoints(endpoints);

        if (endpoints.isEmpty) {
          printError('Aucun endpoint disponible sur ce périphérique.');
          usb.closeDevice();
          if (!promptRetryAfterAccessDenied(device.toString())) {
            usb.dispose();
            exit(1);
          }
          continue;
        }

        selectedDevice = device;
      } on UsbException catch (e) {
        if (e.isAccessDenied) {
          if (promptRetryAfterAccessDenied(device.toString())) {
            continue;
          } else {
            usb.dispose();
            exit(1);
          }
        } else {
          printError('$e');
          if (promptRetryAfterAccessDenied(device.toString())) {
            continue;
          } else {
            usb.dispose();
            exit(1);
          }
        }
      }
    }

    // --- Find IN/OUT endpoints ---
    var inEndpoint = endpoints
        .where((ep) => ep.isIn)
        .where(
          (ep) =>
              ep.transferType == libusbTransferTypeBulk ||
              ep.transferType == libusbTransferTypeInterrupt,
        )
        .toList();

    if (inEndpoint.isEmpty) {
      printError(
        'Aucun endpoint IN (Bulk ou Interrupt) trouvé.\n'
        '   Ce périphérique ne supporte pas la lecture de données directe.',
      );
      usb.dispose();
      exit(1);
    }

    var readEp = inEndpoint.first;
    printStatus('📥 Endpoint de lecture : $readEp');

    EndpointInfo? writeEp;
    var outEndpoints = endpoints
        .where((ep) => ep.isOut)
        .where(
          (ep) =>
              ep.transferType == libusbTransferTypeBulk ||
              ep.transferType == libusbTransferTypeInterrupt,
        )
        .toList();
    if (outEndpoints.isNotEmpty) {
      writeEp = outEndpoints.first;
      printStatus('📤 Endpoint d\'écriture : $writeEp');
    }

    // --- Build USB/IP device descriptor from selected device ---
    var usbipDev = UsbipDevice(
      path: '/sys/devices/usb/1-1',
      busid: '1-1',
      busnum: 1,
      devnum: 1,
      speed: usbSpeedHigh,
      idVendor: selectedDevice.vendorId,
      idProduct: selectedDevice.productId,
      bDeviceClass: selectedDevice.deviceClass,
      bDeviceSubClass: selectedDevice.deviceSubClass,
      bDeviceProtocol: selectedDevice.deviceProtocol,
      bConfigurationValue: 1,
      bNumConfigurations: 1,
      bNumInterfaces: 1,
      interfaces: [UsbipInterface()],
    );

    // --- Connect to TCP tunnel ---
    printStatus('\n🔍 Connexion au tunnel local sur 127.0.0.1:$port...');

    Socket socket;
    try {
      socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: Duration(seconds: 5),
      );
    } on SocketException catch (e) {
      printError(
        'Impossible de se connecter au port USB local.\n'
        '   Vérifiez que votre tunnel SSH est bien lancé avec l\'option :\n'
        '   -L $port:127.0.0.1:$port\n'
        '\n   Détail : $e',
      );
      usb.dispose();
      exit(1);
    } on TimeoutException {
      printError(
        'Timeout lors de la connexion au tunnel.\n'
        '   Vérifiez que votre tunnel SSH est bien lancé avec l\'option :\n'
        '   -L $port:127.0.0.1:$port',
      );
      usb.dispose();
      exit(1);
    }

    printStatus('✅ Connecté au tunnel local 127.0.0.1:$port');

    // --- Wait for USB/IP handshake from Windows server ---
    printStatus('⏳ En attente du handshake USB/IP...');

    var streamReader = UsbipStreamReader();
    var handshakeCompleter = Completer<bool>();
    var handshakeDone = false;

    // Listen for incoming data and handle handshake + URB responses
    var socketSub = socket.listen(
      (data) {
        streamReader.addData(data);

        if (!handshakeDone) {
          _handleHandshake(streamReader, socket, usbipDev, verbose);
          // After IMPORT reply is sent, handshake is complete
          // We detect this by the server sending CMD_SUBMIT requests
          // Actually in our architecture, the Mac is the "server" exporting the device
          // and Windows is the "client" that imports it
          // So we need to handle OP_REQ_DEVLIST and OP_REQ_IMPORT

          // Check if we've handled all handshake messages
          // The handshake is done when we receive and process the IMPORT request
          if (!handshakeCompleter.isCompleted) {
            // Try to see if we have CMD_SUBMIT headers (URB phase)
            var peek = streamReader.peek(4);
            if (peek != null) {
              var cmd = ByteData.sublistView(peek).getUint32(0, Endian.big);
              if (cmd == usbipCmdSubmit || cmd == usbipCmdUnlink) {
                handshakeDone = true;
                handshakeCompleter.complete(true);
              }
            }
          }
        }
      },
      onError: (e) {
        print('⚠️ Erreur socket : $e');
        if (!handshakeCompleter.isCompleted) {
          handshakeCompleter.complete(false);
        }
      },
      onDone: () {
        print('\n🔴 Tunnel déconnecté.');
        if (!handshakeCompleter.isCompleted) {
          handshakeCompleter.complete(false);
        }
      },
    );

    // Wait for handshake (max 30 seconds)
    var handshakeOk = await handshakeCompleter.future.timeout(
      Duration(seconds: 30),
      onTimeout: () => false,
    );

    if (!handshakeOk) {
      printError('Handshake USB/IP échoué ou timeout.');
      socket.destroy();
      usb.dispose();
      exit(1);
    }

    printStatus(
      '\n🚀 Transfert USB/IP actif !\n'
      '   ${selectedDevice.manufacturer} ${selectedDevice.product} → 127.0.0.1:$port\n'
      '   Ctrl+C pour arrêter.\n',
    );

    // --- URB forwarding loop ---
    // Now we process CMD_SUBMIT from the Windows vhci driver
    // and respond with RET_SUBMIT containing USB data

    late Timer timer;
    var errorCount = 0;
    const maxConsecutiveErrors = 10;

    timer = Timer.periodic(Duration(milliseconds: 5), (_) {
      // Process any pending CMD_SUBMIT requests from the vhci driver
      while (streamReader.available >= usbipHeaderSize) {
        var headerBytes = streamReader.peek(usbipHeaderSize);
        if (headerBytes == null) break;

        var headerData = ByteData.sublistView(headerBytes);
        var cmd = headerData.getUint32(0, Endian.big);

        if (cmd == usbipCmdSubmit) {
          var direction = headerData.getUint32(12, Endian.big);
          var transferBufferLength = headerData.getUint32(0x18, Endian.big);

          // For OUT: header + transfer_buffer
          var totalLen = usbipHeaderSize +
              (direction == usbipDirOut ? transferBufferLength : 0);

          if (streamReader.available < totalLen) break;
          var msgBytes = streamReader.tryRead(totalLen)!;
          var submit = CmdSubmit.deserialize(msgBytes);

          if (verbose) {
            print(
              '⬅️ CMD_SUBMIT seq=${submit.header.seqnum} '
              'ep=${submit.header.ep} dir=${submit.header.direction == usbipDirIn ? "IN" : "OUT"} '
              'len=${submit.transferBufferLength}',
            );
          }

          // Handle the URB
          _handleCmdSubmit(submit, usb, readEp, writeEp, socket, verbose);
          errorCount = 0;
        } else if (cmd == usbipCmdUnlink) {
          if (streamReader.available < usbipHeaderSize) break;
          var msgBytes = streamReader.tryRead(usbipHeaderSize)!;
          var unlinkData = ByteData.sublistView(msgBytes);
          var reqSeqnum = unlinkData.getUint32(4, Endian.big);
          var unlinkSeqnum = unlinkData.getUint32(0x14, Endian.big);

          if (verbose) {
            print('⬅️ CMD_UNLINK seq=$reqSeqnum unlink=$unlinkSeqnum');
          }

          // Reply with RET_UNLINK
          var reply = serializeRetUnlink(reqSeqnum, econnreset);
          socket.add(reply);
        } else {
          // Unknown command — skip 4 bytes and try again
          if (verbose) {
            print('⚠️ Unknown command: 0x${cmd.toRadixString(16)}');
          }
          streamReader.tryRead(4);
        }
      }

      // Also do a proactive USB read and store data for IN responses
      try {
        var data = usb.readEndpoint(
          readEp.address,
          maxLength: readEp.maxPacketSize,
          timeoutMs: 1,
        );
        if (data.isNotEmpty && verbose) {
          print('📦 USB buffer: ${data.length} bytes ready');
        }
      } on UsbException catch (e) {
        if (e.isNoDevice) {
          print('\n🔴 Périphérique USB déconnecté.');
          timer.cancel();
          socket.close();
          usb.dispose();
          exit(0);
        }
        errorCount++;
        if (errorCount >= maxConsecutiveErrors) {
          print('\n🔴 Trop d\'erreurs USB consécutives: $e');
          timer.cancel();
          socket.close();
          usb.dispose();
          exit(1);
        }
      }
    });

    // Keep alive
    await socketSub.asFuture();
    timer.cancel();
    usb.closeDevice();
    usb.dispose();
  } catch (e, stack) {
    print('❌ Erreur fatale : $e');
    if (verbose) print(stack);
    usb.dispose();
    exit(1);
  }
}

/// Handle USB/IP handshake messages (OP_REQ_DEVLIST, OP_REQ_IMPORT).
void _handleHandshake(
  UsbipStreamReader reader,
  Socket socket,
  UsbipDevice device,
  bool verbose,
) {
  while (reader.available >= opCommonSize) {
    var headerBytes = reader.peek(opCommonSize);
    if (headerBytes == null) return;

    var headerData = ByteData.sublistView(headerBytes);
    var (_, command, _) = readOpCommon(headerData);

    if (command == opReqDevlist) {
      // Consume the header
      reader.tryRead(opCommonSize);
      if (verbose) print('⬅️ OP_REQ_DEVLIST reçu');

      // Reply with our device
      var reply = serializeRepDevlist([device]);
      socket.add(reply);
      if (verbose) print('➡️ OP_REP_DEVLIST envoyé (${device.idVendor.toRadixString(16)}:${device.idProduct.toRadixString(16)})');
    } else if (command == opReqImport) {
      // Need 8 + 32 bytes
      if (reader.available < opCommonSize + busidSize) return;
      var importBytes = reader.tryRead(opCommonSize + busidSize)!;
      var busid = parseReqImportBusid(importBytes);
      if (verbose) print('⬅️ OP_REQ_IMPORT reçu (busid: $busid)');

      // Reply with success
      var reply = serializeRepImport(device);
      socket.add(reply);
      if (verbose) print('➡️ OP_REP_IMPORT envoyé (success)');
    } else {
      // Not a handshake command — stop processing handshake
      return;
    }
  }
}

/// Handle a CMD_SUBMIT URB by reading/writing USB data through libusb.
void _handleCmdSubmit(
  CmdSubmit submit,
  UsbManager usb,
  EndpointInfo readEp,
  EndpointInfo? writeEp,
  Socket socket,
  bool verbose,
) {
  var header = submit.header;

  if (header.direction == usbipDirIn) {
    // IN transfer: read from USB device
    Uint8List usbData;
    int status = 0;

    try {
      usbData = usb.readEndpoint(
        readEp.address,
        maxLength: submit.transferBufferLength > 0
            ? submit.transferBufferLength
            : readEp.maxPacketSize,
        timeoutMs: 100,
      );
    } on UsbException catch (e) {
      usbData = Uint8List(0);
      status = -1; // Generic error
      if (verbose) print('⚠️ USB read error for URB seq=${header.seqnum}: $e');
    }

    // Build RET_SUBMIT response
    var retHeader = UsbipHeaderBasic(
      command: usbipRetSubmit,
      seqnum: header.seqnum,
      devid: 0,
      direction: usbipDirIn,
      ep: header.ep,
    );

    var ret = RetSubmit(
      header: retHeader,
      status: status,
      actualLength: usbData.length,
      transferBuffer: usbData,
    );

    socket.add(ret.serialize());

    if (verbose && usbData.isNotEmpty) {
      var hex = usbData
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      print(
        '➡️ RET_SUBMIT seq=${header.seqnum} ${usbData.length} bytes: $hex'
        '${usbData.length > 16 ? '...' : ''}',
      );
    }
  } else {
    // OUT transfer: write to USB device
    int status = 0;
    int actualLength = 0;

    if (writeEp != null && submit.transferBuffer.isNotEmpty) {
      try {
        actualLength = usb.writeEndpoint(
          writeEp.address,
          submit.transferBuffer,
          timeoutMs: 100,
        );
      } on UsbException catch (e) {
        status = -1;
        if (verbose) print('⚠️ USB write error for URB seq=${header.seqnum}: $e');
      }
    } else {
      actualLength = submit.transferBufferLength;
    }

    // Build RET_SUBMIT response
    var retHeader = UsbipHeaderBasic(
      command: usbipRetSubmit,
      seqnum: header.seqnum,
      devid: 0,
      direction: usbipDirOut,
      ep: header.ep,
    );

    var ret = RetSubmit(
      header: retHeader,
      status: status,
      actualLength: actualLength,
    );

    socket.add(ret.serialize());

    if (verbose) {
      print('➡️ RET_SUBMIT seq=${header.seqnum} OUT status=$status');
    }
  }
}

void _printHelp() {
  print('Mac USB Forwarder — Capture et transfert USB/IP.\n');
  print('Usage: dart run bin/mac_usb_forwarder.dart [options]\n');
  print('Options:');
  print('  -p, --port <port>   Port TCP local (défaut: $defaultUsbPort)');
  print('  -v, --verbose       Activer les logs détaillés');
  print('  -h, --help          Afficher cette aide\n');
  print('Prérequis:');
  print('  1. libusb installé : brew install libusb');
  print(
    '  2. Tunnel SSH actif : sshnp [args...] -o \'-L $defaultUsbPort:127.0.0.1:$defaultUsbPort\'',
  );
}
