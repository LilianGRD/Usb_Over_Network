import 'dart:async';
import 'dart:io';

/// Default USBIP port for USB data stream over the SSH tunnel.
const int defaultUsbPort = 3240;

/// Windows Virtual USB Hub — TCP Server
///
/// Listens on 127.0.0.1:3240 for incoming connections from the Mac client
/// (arriving via the pre-existing SSH tunnel). Received USB data packets
/// are forwarded to the local USBIP virtual driver.
///
/// The SSH tunnel must already be running with:
///   sshnpd [args...] (or equivalent)
/// and the remote client must have:
///   -L 3240:127.0.0.1:3240
Future<void> main(List<String> args) async {
  // --- Parse CLI options ---
  var parser = _ArgParser()
    ..addOption(
      'port',
      abbr: 'p',
      help: 'Local TCP port to listen on (default: $defaultUsbPort)',
      defaultsTo: '$defaultUsbPort',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      help: 'Enable verbose logging',
      defaultsTo: false,
    )
    ..addFlag('help', abbr: 'h', help: 'Show this help', defaultsTo: false);

  _ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('Error parsing arguments: $e');
    print(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('Windows Virtual USB Hub — TCP server for USB data stream.\n');
    print('Usage: dart run bin/windows_virtual_usb.dart [options]\n');
    print(parser.usage);
    print(
      '\nMake sure your SSH tunnel is already running.\n'
      'This server listens on 127.0.0.1:$defaultUsbPort and expects\n'
      'the Mac client to connect via the tunnel.',
    );
    exit(0);
  }

  var port = int.tryParse(results['port'] as String) ?? defaultUsbPort;
  var verbose = results['verbose'] as bool;

  // --- Start TCP server ---
  print('🚀 Démarrage du Windows Virtual USB Hub...');

  ServerSocket server;
  try {
    server = await ServerSocket.bind('127.0.0.1', port);
  } on SocketException catch (e) {
    print(
      '\n❌ Erreur : Impossible d\'écouter sur 127.0.0.1:$port.\n'
      'Le port est peut-être déjà utilisé.\n'
      '\nDétail : $e',
    );
    exit(1);
  }

  print('✅ Serveur TCP en écoute sur 127.0.0.1:$port');
  print('⏳ En attente de connexion du client Mac (via tunnel SSH)...');

  server.listen((Socket client) {
    var clientAddr = '${client.remoteAddress.address}:${client.remotePort}';
    print('🔗 Connexion acceptée depuis $clientAddr');

    var packetCount = 0;

    client.listen(
      (data) {
        packetCount++;
        var payload = String.fromCharCodes(data).trim();

        if (verbose) {
          print('⬇️ [#$packetCount] RX: $payload');
        }

        // TODO: Injecter les données dans le driver USBIP virtuel Windows
        // usbipDriver.write(data);

        // Echo acknowledgement back to Mac client
        try {
          client.write('ACK_$packetCount\n');
        } catch (e) {
          print('⚠️ Erreur envoi ACK : $e');
        }
      },
      onError: (e) {
        print('❌ Erreur sur la connexion $clientAddr : $e');
      },
      onDone: () {
        print('🔴 Client $clientAddr déconnecté. ($packetCount paquets reçus)');
        client.close();
      },
    );
  });
}

// ---------------------------------------------------------------------------
// Minimal arg parser (zero dependencies)
// ---------------------------------------------------------------------------

class _ArgParser {
  final List<_Option> _options = [];
  final List<_Flag> _flags = [];

  void addOption(String name, {String? abbr, String? help, String? defaultsTo}) {
    _options.add(_Option(name, abbr, help, defaultsTo));
  }

  void addFlag(String name, {String? abbr, String? help, bool defaultsTo = false}) {
    _flags.add(_Flag(name, abbr, help, defaultsTo));
  }

  _ArgResults parse(List<String> args) {
    var values = <String, dynamic>{};
    for (var opt in _options) {
      values[opt.name] = opt.defaultsTo;
    }
    for (var flag in _flags) {
      values[flag.name] = flag.defaultsTo;
    }

    var i = 0;
    while (i < args.length) {
      var arg = args[i];
      var matched = false;

      for (var opt in _options) {
        if (arg == '--${opt.name}' || (opt.abbr != null && arg == '-${opt.abbr}')) {
          if (i + 1 >= args.length) throw FormatException('Missing value for $arg');
          values[opt.name] = args[++i];
          matched = true;
          break;
        }
      }

      if (!matched) {
        for (var flag in _flags) {
          if (arg == '--${flag.name}' || (flag.abbr != null && arg == '-${flag.abbr}')) {
            values[flag.name] = true;
            matched = true;
            break;
          }
          if (arg == '--no-${flag.name}') {
            values[flag.name] = false;
            matched = true;
            break;
          }
        }
      }

      if (!matched) throw FormatException('Unknown argument: $arg');
      i++;
    }
    return _ArgResults(values);
  }

  String get usage {
    var buf = StringBuffer();
    for (var opt in _options) {
      var a = opt.abbr != null ? '-${opt.abbr}, ' : '    ';
      buf.writeln('  $a--${opt.name.padRight(16)} ${opt.help ?? ""}'
          '${opt.defaultsTo != null ? " (default: ${opt.defaultsTo})" : ""}');
    }
    for (var flag in _flags) {
      var a = flag.abbr != null ? '-${flag.abbr}, ' : '    ';
      buf.writeln('  $a--${flag.name.padRight(16)} ${flag.help ?? ""}');
    }
    return buf.toString();
  }
}

class _ArgResults {
  final Map<String, dynamic> _values;
  _ArgResults(this._values);
  dynamic operator [](String key) => _values[key];
}

class _Option {
  final String name;
  final String? abbr;
  final String? help;
  final String? defaultsTo;
  _Option(this.name, this.abbr, this.help, this.defaultsTo);
}

class _Flag {
  final String name;
  final String? abbr;
  final String? help;
  final bool defaultsTo;
  _Flag(this.name, this.abbr, this.help, this.defaultsTo);
}
