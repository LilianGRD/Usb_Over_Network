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

    // --- Start TCP Server ---
    printStatus('\n🔍 Démarrage du serveur USB/IP sur 127.0.0.1:$port...');

    ServerSocket serverSocket;
    try {
      serverSocket = await ServerSocket.bind('127.0.0.1', port);
    } catch (e) {
      printError(
        'Impossible de démarrer le serveur sur le port $port.\n'
        '   Détail : $e',
      );
      usb.dispose();
      exit(1);
    }

    printStatus('✅ Serveur en écoute sur 127.0.0.1:$port');
    printStatus(
      '   Attente de connexion (usbip.exe attach -r 127.0.0.1 -b 1-1)...',
    );

    Socket? activeClient;
    Timer? urbTimer;
    UsbipStreamReader? activeStreamReader;

    await for (var clientSocket in serverSocket) {
      if (verbose) {
        printStatus(
          '\n🔗 Nouvelle connexion de ${clientSocket.remoteAddress.address}:${clientSocket.remotePort}',
        );
      }

      var streamReader = UsbipStreamReader();
      var isUrbMode = false;

      clientSocket.listen(
        (data) {
          streamReader.addData(data);

          if (!isUrbMode) {
            // Handshake phase
            while (streamReader.available >= opCommonSize) {
              var headerBytes = streamReader.peek(opCommonSize)!;
              var headerData = ByteData.sublistView(headerBytes);
              var (_, command, _) = readOpCommon(headerData);

              if (command == opReqDevlist) {
                streamReader.tryRead(opCommonSize);
                if (verbose) print('⬅️ OP_REQ_DEVLIST reçu');
                clientSocket.add(serializeRepDevlist([usbipDev]));
                if (verbose) print('➡️ OP_REP_DEVLIST envoyé');
                // The client native will close the connection after list
                clientSocket.close();
                break;
              } else if (command == opReqImport) {
                if (streamReader.available < opCommonSize + busidSize) return;
                var importBytes = streamReader.tryRead(
                  opCommonSize + busidSize,
                )!;
                var busid = parseReqImportBusid(importBytes);
                if (verbose) print('⬅️ OP_REQ_IMPORT reçu (busid: $busid)');

                isUrbMode = true;

                if (activeClient != null && activeClient != clientSocket) {
                  activeClient?.close();
                }
                activeClient = clientSocket;
                activeStreamReader = streamReader;

                clientSocket.add(serializeRepImport(usbipDev));
                if (verbose) print('➡️ OP_REP_IMPORT envoyé (success)');

                printStatus(
                  '\n🚀 Transfert USB/IP actif !\n'
                  '   ${selectedDevice!.manufacturer} ${selectedDevice.product} → 127.0.0.1:$port\n'
                  '   Ctrl+C pour arrêter le serveur.\n',
                );

                var errorCount = 0;
                const maxConsecutiveErrors = 10;

                urbTimer?.cancel();
                urbTimer = Timer.periodic(Duration(milliseconds: 5), (_) {
                  var activeSocket = activeClient;
                  var reader = activeStreamReader;
                  if (activeSocket == null || reader == null) return;

                  // URB submission parsing
                  while (reader.available >= usbipHeaderSize) {
                    var hBytes = reader.peek(usbipHeaderSize);
                    if (hBytes == null) break;

                    var hData = ByteData.sublistView(hBytes);
                    var cmd = hData.getUint32(0, Endian.big);

                    if (cmd == usbipCmdSubmit) {
                      var direction = hData.getUint32(12, Endian.big);

                      var transferBufferLength = hData.getUint32(
                        0x18,
                        Endian.big,
                      );

                      var totalLen =
                          usbipHeaderSize +
                          (direction == usbipDirOut ? transferBufferLength : 0);

                      if (reader.available < totalLen) break;
                      var msgBytes = reader.tryRead(totalLen)!;
                      var submit = CmdSubmit.deserialize(msgBytes);

                      if (verbose) {
                        print(
                          '⬅️ CMD_SUBMIT seq=${submit.header.seqnum} '
                          'ep=${submit.header.ep} dir=${submit.header.direction == usbipDirIn ? "IN" : "OUT"} '
                          'len=${submit.transferBufferLength}',
                        );
                      }

                      _handleCmdSubmit(
                        submit,
                        usb,
                        readEp,
                        writeEp,
                        activeSocket,
                        verbose,
                      );
                      errorCount = 0;
                    } else if (cmd == usbipCmdUnlink) {
                      if (reader.available < usbipHeaderSize) break;
                      var msgBytes = reader.tryRead(usbipHeaderSize)!;
                      var unlinkData = ByteData.sublistView(msgBytes);
                      var reqSeqnum = unlinkData.getUint32(4, Endian.big);
                      var unlinkSeqnum = unlinkData.getUint32(0x14, Endian.big);

                      if (verbose)
                        print(
                          '⬅️ CMD_UNLINK seq=$reqSeqnum unlink=$unlinkSeqnum',
                        );

                      activeSocket.add(
                        serializeRetUnlink(reqSeqnum, econnreset),
                      );
                    } else {
                      if (verbose)
                        print(
                          '⚠️ Commande inconnue: 0x${cmd.toRadixString(16)}',
                        );
                      reader.tryRead(4);
                    }
                  }
                });
              } else {
                // Unknown command, stop handshake
                break;
              }
            }
          }
        },
        onError: (e) {
          if (verbose) print('⚠️ Erreur socket client : $e');
        },
        onDone: () {
          if (verbose) print('🔴 Client déconnecté.');
          if (clientSocket == activeClient) {
            urbTimer?.cancel();
            urbTimer = null;
            activeClient = null;
            activeStreamReader = null;
            printStatus('\n⏳ Serveur en attente de nouvelle connexion...');
          }
        },
      );
    }
  } catch (e, stack) {
    print('❌ Erreur fatale : $e');
    if (verbose) print(stack);
    usb.dispose();
    exit(1);
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

  // --- Endpoint 0 (Control Transfer) ---
  if (header.ep == 0) {
    if (submit.setup.length < 8) {
      if (verbose) print('⚠️ Missing setup packet for Control Transfer');
      return;
    }

    var setupData = ByteData.sublistView(submit.setup);
    var bmRequestType = setupData.getUint8(0);
    var bRequest = setupData.getUint8(1);
    var wValue = setupData.getUint16(2, Endian.little);
    var wIndex = setupData.getUint16(4, Endian.little);
    var wLength = setupData.getUint16(6, Endian.little);

    if (verbose) {
      print(
        '🔧 Control Transfer: bmRequestType=0x${bmRequestType.toRadixString(16)}, '
        'bRequest=0x${bRequest.toRadixString(16)}, wValue=0x${wValue.toRadixString(16)}, '
        'wLength=$wLength',
      );
    }

    Uint8List resultData;
    int status = 0;

    try {
      resultData = usb.controlTransfer(
        requestType: bmRequestType,
        request: bRequest,
        value: wValue,
        index: wIndex,
        data: header.direction == usbipDirOut ? submit.transferBuffer : null,
        length: wLength,
        timeoutMs: 1000,
      );
    } on UsbException catch (e) {
      resultData = Uint8List(0);
      status = -1;
      if (verbose) print('⚠️ Control Transfer error: $e');
    }

    var retHeader = UsbipHeaderBasic(
      command: usbipRetSubmit,
      seqnum: header.seqnum,
      devid: 0,
      direction: header.direction,
      ep: 0,
    );

    var ret = RetSubmit(
      header: retHeader,
      status: status,
      actualLength: resultData.length,
      transferBuffer: header.direction == usbipDirIn ? resultData : null,
    );

    socket.add(ret.serialize());

    if (verbose) {
      print(
        '➡️ RET_SUBMIT (Control) seq=${header.seqnum} status=$status len=${resultData.length}',
      );
    }

    return;
  }

  // --- Bulk / Interrupt Transfers ---
  if (header.direction == usbipDirIn) {
    // IN transfer: read from USB device
    Uint8List usbData;
    int status = 0;

    var epAddress = header.ep | 0x80;

    try {
      usbData = usb.readEndpoint(
        epAddress,
        maxLength: submit.transferBufferLength > 0
            ? submit.transferBufferLength
            : readEp.maxPacketSize,
        timeoutMs: 100,
      );
    } on UsbException catch (e) {
      usbData = Uint8List(0);
      status = -32; // -EPIPE (STALL)
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

    var epAddress = header.ep; // OUT => no 0x80 bit
    if (submit.transferBuffer.isNotEmpty) {
      try {
        actualLength = usb.writeEndpoint(
          epAddress,
          submit.transferBuffer,
          timeoutMs: 100,
        );
      } on UsbException catch (e) {
        status = -32; // -EPIPE (STALL)
        if (verbose)
          print('⚠️ USB write error for URB seq=${header.seqnum}: $e');
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
