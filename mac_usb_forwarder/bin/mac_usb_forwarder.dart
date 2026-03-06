/// Mac USB Forwarder — Interactive CLI for USB device forwarding over TCP.
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
      // List devices
      var devices = usb.listDevices();
      printDeviceList(devices);

      if (devices.isEmpty) {
        usb.dispose();
        exit(1);
      }

      // Prompt user
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

      // Try to open and claim
      try {
        usb.openDevice(device);
        printStatus('✅ Périphérique ouvert et interface réclamée.');

        // Discover endpoints
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

    // --- Find the best IN endpoint for reading ---
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
    printStatus('📥 Utilisation de l\'endpoint : $readEp');

    // --- Find optional OUT endpoint for writing back ---
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
    printStatus(
      '\n🚀 Démarrage du transfert USB → TCP...\n'
      '   ${selectedDevice.manufacturer} ${selectedDevice.product} → 127.0.0.1:$port\n'
      '   Ctrl+C pour arrêter.\n',
    );

    // --- USB → TCP forwarding loop ---
    var packetCount = 0;
    var errorCount = 0;
    const maxConsecutiveErrors = 10;

    late Timer timer;
    timer = Timer.periodic(Duration(milliseconds: 10), (_) {
      try {
        var data = usb.readEndpoint(
          readEp.address,
          maxLength: readEp.maxPacketSize,
          timeoutMs: 100,
        );

        if (data.isNotEmpty) {
          packetCount++;
          socket.add(data);
          errorCount = 0; // Reset on success

          if (verbose) {
            var hex =
                data
                    .take(16)
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(' ');
            print(
              '➡️ [#$packetCount] ${data.length} bytes: $hex'
              '${data.length > 16 ? '...' : ''}',
            );
          }
        }
      } on UsbException catch (e) {
        errorCount++;
        if (e.isNoDevice) {
          print('\n🔴 Périphérique USB déconnecté.');
          timer.cancel();
          socket.close();
          usb.dispose();
          exit(0);
        }
        if (errorCount >= maxConsecutiveErrors) {
          print('\n🔴 Trop d\'erreurs consécutives sur le bus USB: $e');
          timer.cancel();
          socket.close();
          usb.dispose();
          exit(1);
        }
        if (verbose) {
          print('⚠️ USB read error: $e');
        }
      } catch (e) {
        errorCount++;
        if (verbose) {
          print('⚠️ Error: $e');
        }
        if (errorCount >= maxConsecutiveErrors) {
          print('\n🔴 Trop d\'erreurs consécutives: $e');
          timer.cancel();
          socket.close();
          usb.dispose();
          exit(1);
        }
      }
    });

    // --- TCP → USB (optional write-back) ---
    socket.listen(
      (data) {
        if (writeEp != null) {
          try {
            usb.writeEndpoint(writeEp.address, Uint8List.fromList(data));
            if (verbose) {
              print('⬅️ TCP→USB: ${data.length} bytes');
            }
          } on UsbException catch (e) {
            if (verbose) {
              print('⚠️ USB write error: $e');
            }
          }
        } else if (verbose) {
          print(
            '⬅️ Reçu du tunnel: ${data.length} bytes (pas d\'endpoint OUT)',
          );
        }
      },
      onError: (e) {
        print('⚠️ Erreur lecture tunnel : $e');
        timer.cancel();
      },
      onDone: () {
        print('\n🔴 Tunnel déconnecté.');
        timer.cancel();
        usb.closeDevice();
        usb.dispose();
        exit(0);
      },
    );
  } catch (e, stack) {
    print('❌ Erreur fatale : $e');
    if (verbose) print(stack);
    usb.dispose();
    exit(1);
  }
}

void _printHelp() {
  print('Mac USB Forwarder — Capture et transfert de périphériques USB.\n');
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
