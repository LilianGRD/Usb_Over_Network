import 'dart:io';
import 'package:args/args.dart';
import 'package:at_client/at_client.dart';
import 'package:at_cli_commons/at_cli_commons.dart';
import 'package:noports_core/sshnpd.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  try {
    var parser = ArgParser()
      ..addOption('atsign', abbr: 'a', help: 'The atSign of the Windows host')
      ..addOption(
        'mac-atsign',
        abbr: 'm',
        help: 'The atSign of the Mac USB Forwarder',
      )
      ..addOption(
        'namespace',
        abbr: 'n',
        defaultsTo: 'usbovernetwork',
        help: 'The namespace of the application',
      )
      ..addFlag('verbose', abbr: 'v', help: 'Enable verbose logging')
      ..addFlag('help', abbr: 'h', help: 'Show usage help', negatable: false);

    var results = parser.parse(args);

    if (results['help']) {
      print(parser.usage);
      exit(0);
    }

    var atSign = results['atsign'] as String?;
    var macAtSign = results['mac-atsign'] as String?;
    var namespace = results['namespace'] as String;
    var isVerbose = results['verbose'] as bool;

    if (atSign == null || macAtSign == null) {
      print('Error: Both --atsign and --mac-atsign are required.');
      if (Platform.isWindows) {
        print(
          '💡 Hint: If using PowerShell, you MUST wrap your atSigns in quotes (e.g., "@alice"). PowerShell treats unquoted @ as an array operator.',
        );
      }
      print(parser.usage);
      exit(1);
    }

    var sessionId = Uuid().v4();
    var storageDir = Directory.systemTemp
        .createTempSync('win_usb_$sessionId')
        .path;

    AtClientPreference prefs = AtClientPreference()
      ..hiveStoragePath = storageDir
      ..commitLogPath = storageDir
      ..isLocalStoreRequired = true
      ..rootDomain = 'root.atsign.org';

    print('Starting Windows Virtual USB Hub for AtSign: $atSign...');

    List<String> cliArgs = List.from(args);
    if (!cliArgs.contains('-n') && !cliArgs.contains('--namespace')) {
      cliArgs.addAll(['-n', namespace]);
    }

    CLIBase cliBase = await CLIBase.fromCommandLineArgs(cliArgs);
    var atClient = cliBase.atClient;
    print('✅ Authenticated successfully as ${atClient.getCurrentAtSign()}');

    print('🎧 Starting SSHNPD daemon on Windows side for rendezvous...');
    List<String> daemonArgs = [
      '-a', atSign,
      '-m', macAtSign, // Manager atSign that can request tunnels
      '-d', 'usbh', // Device name matches the Npt client request
    ];

    var sshnpd = await Sshnpd.fromCommandLineArgs(
      daemonArgs,
      atClient: atClient,
      version: '1.0.0',
    );
    await sshnpd.init();
    await sshnpd
        .run(); // Starts listening to notification requests from Mac Npt client

    print('✅ Daemon running to handle NAT-punching NPT rendezvous requests...');

    print('🚀 Setting up Local Virtual Hub listener on port 4000...');
    var hubSocket = await ServerSocket.bind('127.0.0.1', 4000);
    print(
      '✅ Hub Listening on ${hubSocket.address.address}:${hubSocket.port} for proxy traffic',
    );

    hubSocket.listen((client) {
      print(
        '🔗 TCP connection established from Virtual Port (via Rendezvous tunnel)...',
      );
      client.listen(
        (data) {
          var packetInfo = String.fromCharCodes(data).trim();
          print('⬇️ Packet RX: $packetInfo');
          // Simulated Injection into Hub Driver
        },
        onDone: () {
          print('🔴 Virtual Port connection closed.');
        },
        onError: (e) {
          print('❌ Error on connection: $e');
        },
      );
    });
  } catch (e, stacktrace) {
    print('Failed to start Windows Virtual USB Hub: $e');
    print(stacktrace);
    exit(1);
  }
}
