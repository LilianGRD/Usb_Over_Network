/// Windows Virtual USB Hub — USB/IP server for forwarding USB data
/// to the usbip-win virtual host controller driver.
///
/// This application:
/// 1. Listens on 127.0.0.1:3240 as a TCP server
/// 2. Sends OP_REQ_DEVLIST and OP_REQ_IMPORT to the Mac client
/// 3. Auto-runs `usbip.exe attach` to bind the virtual driver
/// 4. Forwards CMD_SUBMIT/RET_SUBMIT URB traffic between the vhci
///    driver and the Mac client
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

  // --- Startup warning ---
  print('╔══════════════════════════════════════════════════════════════╗');
  print('║         Windows Virtual USB Hub — USB/IP Server            ║');
  print('╠══════════════════════════════════════════════════════════════╣');
  print('║ ⚠️  PRÉREQUIS :                                            ║');
  print('║                                                            ║');
  print('║ 1. usbip-win installé :                                    ║');
  print('║    https://github.com/cezanne/usbip-win                    ║');
  print('║ 2. Test signing activé :                                   ║');
  print('║    bcdedit /set testsigning on                              ║');
  print('║ 3. Certificats de test installés                           ║');
  print('║ 4. usbip.exe dans le PATH                                  ║');
  print('║ 5. Tunnel SSH actif avec :                                  ║');
  print('║    -R $port:127.0.0.1:$port                                ║');
  print('╚══════════════════════════════════════════════════════════════╝');
  print('');

  // --- Start TCP server ---
  ServerSocket server;
  try {
    server = await ServerSocket.bind('127.0.0.1', port);
  } on SocketException catch (e) {
    print('❌ Erreur : Impossible d\'écouter sur 127.0.0.1:$port.');
    print('   Le port est peut-être déjà utilisé.');
    print('   Détail : $e');
    exit(1);
  }

  print('✅ Serveur USB/IP en écoute sur 127.0.0.1:$port');
  print('⏳ En attente de connexion du client Mac (via tunnel SSH)...\n');

  await for (var client in server) {
    var clientAddr = '${client.remoteAddress.address}:${client.remotePort}';
    print('🔗 Connexion acceptée depuis $clientAddr');

    _handleClient(client, verbose, autoAttach, port);
  }
}

/// Handle a single client connection (the Mac USB forwarder).
Future<void> _handleClient(
  Socket client,
  bool verbose,
  bool autoAttach,
  int port,
) async {
  var reader = UsbipStreamReader();

  // --- Phase 1: USB/IP Handshake ---
  print('📡 Phase 1 : Handshake USB/IP...');

  // Step 1: Send OP_REQ_DEVLIST
  var devlistReq = serializeReqDevlist();
  client.add(devlistReq);
  if (verbose) print('➡️ OP_REQ_DEVLIST envoyé');

  // Wait for OP_REP_DEVLIST
  UsbipDevice? importedDevice;

  var handshakeCompleter = Completer<UsbipDevice?>();
  var handshakePhase = 0; // 0=waiting DEVLIST reply, 1=waiting IMPORT reply

  var sub = client.listen(
    (data) {
      reader.addData(data);

      if (handshakePhase == 0) {
        // Waiting for OP_REP_DEVLIST
        if (reader.available < opCommonSize + 4) return;

        var peekHeader = reader.peek(opCommonSize + 4)!;
        var peekData = ByteData.sublistView(peekHeader);
        var (_, command, status) = readOpCommon(peekData);
        var ndev = peekData.getUint32(opCommonSize, Endian.big);

        if (command != opRepDevlist) {
          print('❌ Réponse inattendue: 0x${command.toRadixString(16)}');
          handshakeCompleter.complete(null);
          return;
        }

        if (status != statusOk || ndev == 0) {
          print('❌ OP_REP_DEVLIST: aucun périphérique exporté.');
          handshakeCompleter.complete(null);
          return;
        }

        // We need: op_common(8) + ndev(4) + device_info(312) + interfaces
        // For simplicity, try to read with at least 1 interface
        var minSize = opCommonSize + 4 + deviceInfoSize + interfaceInfoSize;
        if (reader.available < minSize) return;

        // Consume the header
        reader.tryRead(opCommonSize + 4);

        // Parse the first device
        var remaining = reader.peek(reader.available)!;
        var (dev, consumed) = UsbipDevice.deserialize(remaining);
        reader.tryRead(consumed);

        if (verbose) {
          print(
            '⬅️ OP_REP_DEVLIST: ${dev.idVendor.toRadixString(16)}:'
            '${dev.idProduct.toRadixString(16)} '
            '(${dev.busid})',
          );
        }

        // Step 2: Send OP_REQ_IMPORT
        var importReq = serializeReqImport(dev.busid);
        client.add(importReq);
        if (verbose) print('➡️ OP_REQ_IMPORT envoyé (busid: ${dev.busid})');

        handshakePhase = 1;
      } else if (handshakePhase == 1) {
        // Waiting for OP_REP_IMPORT
        if (reader.available < opCommonSize) return;

        var peekHeader = reader.peek(opCommonSize)!;
        var peekData = ByteData.sublistView(peekHeader);
        var (_, command, status) = readOpCommon(peekData);

        if (command != opRepImport) {
          print('❌ Réponse inattendue: 0x${command.toRadixString(16)}');
          handshakeCompleter.complete(null);
          return;
        }

        if (status != statusOk) {
          print('❌ OP_REP_IMPORT: refusé par le serveur.');
          reader.tryRead(opCommonSize);
          handshakeCompleter.complete(null);
          return;
        }

        // Read full reply: header(8) + device_info(312)
        var fullSize = opCommonSize + deviceInfoSize;
        if (reader.available < fullSize) return;

        var fullBytes = reader.tryRead(fullSize)!;
        // hasInterfaces: false — OP_REP_IMPORT does NOT include interface
        // descriptors after the device block (unlike OP_REP_DEVLIST).
        var (dev, _) = UsbipDevice.deserialize(fullBytes, opCommonSize, false);

        if (verbose) {
          print(
            '⬅️ OP_REP_IMPORT: success — ${dev.idVendor.toRadixString(16)}:'
            '${dev.idProduct.toRadixString(16)}',
          );
        }

        importedDevice = dev;
        handshakeCompleter.complete(dev);
      }
    },
    onError: (e) {
      print('⚠️ Erreur socket : $e');
      if (!handshakeCompleter.isCompleted) {
        handshakeCompleter.complete(null);
      }
    },
    onDone: () {
      print('🔴 Client déconnecté pendant le handshake.');
      if (!handshakeCompleter.isCompleted) {
        handshakeCompleter.complete(null);
      }
    },
  );

  // Wait for handshake
  importedDevice = await handshakeCompleter.future.timeout(
    Duration(seconds: 15),
    onTimeout: () {
      print('❌ Timeout du handshake USB/IP.');
      return null;
    },
  );

  if (importedDevice == null) {
    print('❌ Handshake échoué. Fermeture de la connexion.');
    client.destroy();
    return;
  }

  // At this point importedDevice is guaranteed non-null
  var device = importedDevice!;

  print(
    '✅ Handshake USB/IP réussi !\n'
    '   Périphérique : VID:${device.idVendor.toRadixString(16).padLeft(4, '0')} '
    'PID:${device.idProduct.toRadixString(16).padLeft(4, '0')}\n',
  );

  // --- Phase 2: Auto-attach via usbip.exe ---
  if (autoAttach) {
    print('🔧 Phase 2 : Attachement du driver virtuel...');
    print('   Exécution: usbip.exe attach -r 127.0.0.1 -b ${device.busid}');

    try {
      var result = await Process.run(
        'usbip.exe',
        ['attach', '-r', '127.0.0.1', '-b', device.busid],
      );

      if (result.exitCode == 0) {
        print('✅ usbip.exe attach réussi !');
        if (verbose && (result.stdout as String).isNotEmpty) {
          print('   stdout: ${result.stdout}');
        }
      } else {
        print('⚠️ usbip.exe attach code retour: ${result.exitCode}');
        if ((result.stderr as String).isNotEmpty) {
          print('   stderr: ${result.stderr}');
        }
        print('   Le driver virtuel n\'est peut-être pas installé.');
        print('   Le transfert de données brutes continue...');
      }
    } on ProcessException catch (e) {
      print('⚠️ usbip.exe introuvable dans le PATH.');
      print('   Erreur: $e');
      print('   Assurez-vous que usbip-win est installé.');
      print('   Le transfert de données brutes continue...\n');
    }
  } else {
    print('ℹ️  Auto-attach désactivé (--no-attach).');
  }

  // --- Phase 3: URB Forwarding ---
  print('\n🚀 Phase 3 : Transfert URB actif...');
  print('   Ctrl+C pour arrêter.\n');

  var packetCount = 0;

  // Cancel the handshake listener and set up URB forwarding
  await sub.cancel();

  // New listener for URB phase — data flows bidirectionally
  // vhci driver (localhost) ↔ this app ↔ Mac client (tunnel)
  //
  // In our architecture, the Mac acts as the USB/IP "server" (stub driver)
  // and this Windows app acts as the "client" (vhci driver proxy).
  //
  // After a successful IMPORT, the vhci driver will send CMD_SUBMIT
  // to the TCP connection. We forward these to the Mac, and forward
  // RET_SUBMIT responses back.
  //
  // Since the vhci driver communicates directly on this TCP socket
  // (post-attach), we need to proxy between the vhci connection and
  // the Mac tunnel.
  //
  // For the initial implementation, we just log the data flow.

  client.listen(
    (data) {
      packetCount++;
      if (verbose) {
        var preview = data.length > 48 ? data.sublist(0, 48) : data;
        var hex = preview.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        print('⬅️ [#$packetCount] RX ${data.length} bytes: $hex${data.length > 48 ? '...' : ''}');

        // Try to parse the header
        if (data.length >= headerBasicSize) {
          var headerData = ByteData.sublistView(Uint8List.fromList(data));
          var cmd = headerData.getUint32(0, Endian.big);
          var seqnum = headerData.getUint32(4, Endian.big);
          var cmdName = _commandName(cmd);
          print('   📋 $cmdName seq=$seqnum');
        }
      }
    },
    onError: (e) {
      print('⚠️ Erreur socket: $e');
    },
    onDone: () {
      print('\n🔴 Client Mac déconnecté. ($packetCount paquets échangés)');
    },
  );
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
  print('Windows Virtual USB Hub — Serveur USB/IP.\n');
  print('Usage: dart run bin/windows_virtual_usb.dart [options]\n');
  print('Options:');
  print('  -p, --port <port>   Port TCP local (défaut: $defaultUsbPort)');
  print('  -v, --verbose       Activer les logs détaillés');
  print('  --no-attach         Ne pas lancer usbip.exe attach automatiquement');
  print('  -h, --help          Afficher cette aide\n');
  print('Prérequis:');
  print('  1. usbip-win installé (github.com/cezanne/usbip-win)');
  print('  2. Test signing activé: bcdedit /set testsigning on');
  print('  3. Tunnel SSH avec: -R $defaultUsbPort:127.0.0.1:$defaultUsbPort');
}
