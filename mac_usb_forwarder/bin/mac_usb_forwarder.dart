import 'dart:io';
import 'package:args/args.dart';
import 'package:at_client/at_client.dart';
import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:noports_core/npt.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  try {
    var parser = ArgParser()
      ..addOption('atsign',
          abbr: 'a', mandatory: true, help: 'The atSign of the Mac host')
      ..addOption('shared-with',
          abbr: 's',
          mandatory: true,
          help: 'The atSign of the Windows virtual hub')
      ..addOption('rendezvous',
          abbr: 'r',
          help: 'The rendezvous atSign (defaults to shared-with)')
      ..addOption('namespace',
          abbr: 'n',
          defaultsTo: 'usbovernetwork',
          help: 'The namespace of the application')
      ..addFlag('verbose', abbr: 'v', help: 'Enable verbose logging')
      ..addFlag('help', abbr: 'h', help: 'Show usage help', negatable: false);

    var results = parser.parse(args);

    if (results['help']) {
      print(parser.usage);
      exit(0);
    }

    var atSign = results['atsign'];
    var sharedWith = results['shared-with'];
    var rvAtSign = results['rendezvous'] ?? sharedWith;
    var namespace = results['namespace'];
    var isVerbose = results['verbose'];

    var sessionId = Uuid().v4();
    var storageDir = Directory.systemTemp.createTempSync('mac_usb_$sessionId').path;

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

    print('🔌 Initializing NPT rendezvous TCP tunnel to $sharedWith (via $rvAtSign)...');
    
    var nptParams = NptParams(
      clientAtSign: atSign,
      sshnpdAtSign: sharedWith,
      srvdAtSign: rvAtSign,
      remoteHost: '127.0.0.1',
      remotePort: 4000,
      localPort: 4001,
      device: 'usbh',
      inline: true,
      timeout: Duration(days: 365), 
    );

    var npt = Npt.create(params: nptParams, atClient: atClient);
    
    print('⏳ Waiting for atPlatform rendezvous tunnel...');
    await npt.runInline(); 
    
    print('🔌 Connecting to local TCP loopback over E2E Tunnel...');
    // We wait briefly for the socket connector to bind locally
    await Future.delayed(Duration(seconds: 2));
    
    var socket = await Socket.connect('127.0.0.1', 4001);
    
    print('�� Starting High-Frequency USB Stream passing to Windows NAT...');
    // Simulate high frequency USB polling stream directly over the socket instead of notifications
    Stream.periodic(Duration(milliseconds: 100), (count) => 'USB_DATA_PACKET_$count\n')
        .listen((data) {
      try {
        socket.write(data);
      } catch (e) {
        print('Connection lost or error writing to socket: $e');
      }
    });
    
    socket.listen((data) {
        print('⬅️ Received from Windows over TCP: ${String.fromCharCodes(data)}');
    }, onDone: () {
        print('🔴 Virtual USB Hub socket disconnected.');
    });

  } catch (e, stacktrace) {
    print('Failed to start Mac USB Forwarder: $e');
    print(stacktrace);
    exit(1);
  }
}
