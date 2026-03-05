import 'dart:io';
import 'package:args/args.dart';
import 'package:at_client/at_client.dart';
import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:noports_core/sshnp.dart';
import 'package:noports_core/sshnp_foundation.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  try {
    var parser = CLIBase.createArgsParser(namespace: 'usbovernetwork')
      ..addOption(
        'shared-with',
        abbr: 'w',
        help: 'The atSign of the Windows virtual hub',
      )
      ..addOption(
        'rendezvous',
        help: 'The rendezvous atSign (defaults to @rv_eu)',
      );

    ArgResults results;
    try {
      results = parser.parse(args);
    } catch (e) {
      print('Error parsing arguments: $e');
      if (Platform.isWindows && e.toString().contains('atsign')) {
        print(
          '\n💡 Hint: If using PowerShell, you MUST wrap your atSigns in quotes (e.g., "@alice"). PowerShell treats unquoted @ as an array operator.\n',
        );
      }
      print(parser.usage);
      exit(1);
    }

    if (results['help']) {
      print(parser.usage);
      exit(0);
    }

    var atSign = results['atsign'] as String?;
    var sharedWith = results['shared-with'] as String?;
    var rvAtSign = results['rendezvous'] as String? ?? '@rv_eu';
    var namespace = results['namespace'] as String;
    var isVerbose = results['verbose'] as bool? ?? true;

    if (atSign == null || sharedWith == null) {
      print('Error: Both --atsign and --shared-with are required.');
      if (Platform.isWindows) {
        print(
          '\n💡 Hint: If using PowerShell, you MUST wrap your atSigns in quotes (e.g., "@alice"). PowerShell treats unquoted @ as an array operator.\n',
        );
      }
      print(parser.usage);
      exit(1);
    }
    var sessionId = Uuid().v4();
    var storageDir = Directory.systemTemp
        .createTempSync('mac_usb_$sessionId')
        .path;

    AtClientPreference prefs = AtClientPreference()
      ..hiveStoragePath = storageDir
      ..commitLogPath = storageDir
      ..isLocalStoreRequired = true
      ..rootDomain = 'root.atsign.org';

    print('Starting Mac USB Forwarder for AtSign: $atSign...');

    CLIBase cliBase = await CLIBase.fromCommandLineArgs(
      args,
      parser: parser,
      namespace: namespace,
    );
    var atClient = cliBase.atClient;
    print('✅ Authenticated successfully as ${atClient.getCurrentAtSign()}');

    // --- Starlink CGNAT-hardened SshnpParams ---
    // Forces port 443 (only443) to bypass CGNAT restrictions,
    // uses ESCR relay auth mode, increases idleTimeout to 60s
    // to compensate for satellite jitter, and sets up SSH local
    // port forwarding for USBIP traffic on port 3240.
    print(
      '🔌 Initializing SSH tunnel to $sharedWith (via $rvAtSign) with Starlink CGNAT config...',
    );

    var params = SshnpParams(
      clientAtSign: atSign!,
      sshnpdAtSign: sharedWith!,
      srvdAtSign: rvAtSign,
      device: 'usbh',
      only443: true,
      relayAuthMode: RelayAuthMode.escr,
      idleTimeout: 60,
      localSshOptions: ['-L 3240:127.0.0.1:3240'],
      verbose: isVerbose,
    );

    var sshnp = Sshnp.openssh(atClient: atClient, params: params);

    print('⏳ Waiting for SSH tunnel establishment via atPlatform rendezvous...');
    var result = await sshnp.run();

    if (result is SshnpSuccess) {
      print('✅ SSH tunnel established successfully!');
      print('   Local forwarding: localhost:3240 → device:3240 (USBIP)');
    } else if (result is SshnpError) {
      print('❌ SSH tunnel failed: ${result.message}');
      exit(1);
    }

    print('🔌 Connecting to local TCP loopback over SSH tunnel...');
    // Wait briefly for the SSH port forwarding to bind locally
    await Future.delayed(Duration(seconds: 2));

    var socket = await Socket.connect('127.0.0.1', 3240);

    print('🚀 Starting High-Frequency USB Stream passing to Windows NAT...');
    // Simulate high frequency USB polling stream directly over the socket instead of notifications
    Stream.periodic(
      Duration(milliseconds: 100),
      (count) => 'USB_DATA_PACKET_$count\n',
    ).listen((data) {
      try {
        socket.write(data);
      } catch (e) {
        print('Connection lost or error writing to socket: $e');
      }
    });

    socket.listen(
      (data) {
        print(
          '⬅️ Received from Windows over TCP: ${String.fromCharCodes(data)}',
        );
      },
      onDone: () {
        print('🔴 Virtual USB Hub socket disconnected.');
      },
    );
  } catch (e, stacktrace) {
    print('Failed to start Mac USB Forwarder: $e');
    print(stacktrace);
    exit(1);
  }
}

