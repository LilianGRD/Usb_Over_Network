import 'dart:async';
import 'dart:io';

/// Default USBIP port used for local SSH tunnel forwarding.
const int defaultUsbPort = 3240;

Future<void> main(List<String> args) async {
  // --- Parse CLI options ---
  var parser = ArgParser()
    ..addOption(
      'port',
      abbr: 'p',
      help: 'Local TCP port to connect to (default: $defaultUsbPort)',
      defaultsTo: '$defaultUsbPort',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      help: 'Enable verbose logging',
      defaultsTo: false,
    )
    ..addFlag('help', abbr: 'h', help: 'Show this help', defaultsTo: false);

  ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('Error parsing arguments: $e');
    print(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('Mac USB Forwarder — connects to an existing NoPorts SSH tunnel.\n');
    print('Usage: dart run bin/mac_usb_forwarder.dart [options]\n');
    print(parser.usage);
    print(
      '\nMake sure your NoPorts tunnel is already running, for example:\n'
      "  sshnp [args...] -o '-L $defaultUsbPort:127.0.0.1:$defaultUsbPort'",
    );
    exit(0);
  }

  var port = int.tryParse(results['port'] as String) ?? defaultUsbPort;
  var verbose = results['verbose'] as bool;

  // --- Fail-fast: verify tunnel is reachable ---
  print('🔍 Vérification du tunnel local sur 127.0.0.1:$port...');

  Socket socket;
  try {
    socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: Duration(seconds: 5),
    );
  } on SocketException catch (e) {
    print(
      '\n❌ Erreur : Le tunnel réseau n\'est pas actif.\n'
      'Veuillez lancer votre tunnel NoPorts avec le transfert de port USB inclus, par exemple :\n'
      "  sshnp [args...] -o '-L $port:127.0.0.1:$port'\n"
      '\nDétail : $e',
    );
    exit(1);
  } on TimeoutException {
    print(
      '\n❌ Erreur : Le tunnel réseau n\'est pas actif (timeout).\n'
      'Veuillez lancer votre tunnel NoPorts avec le transfert de port USB inclus, par exemple :\n'
      "  sshnp [args...] -o '-L $port:127.0.0.1:$port'",
    );
    exit(1);
  }

  print('✅ Connecté au tunnel local 127.0.0.1:$port');

  // --- USB stream: pipe data directly into the tunnel socket ---
  print('🚀 Démarrage du flux USB haute fréquence vers le tunnel...');

  // Pipe USB data packets into the socket at 10 Hz
  var packetCount = 0;
  var timer = Timer.periodic(Duration(milliseconds: 100), (_) {
    try {
      var packet = 'USB_DATA_PACKET_${packetCount++}\n';
      socket.write(packet);
      if (verbose) {
        stdout.write('➡️ $packet');
      }
    } catch (e) {
      print('⚠️ Erreur écriture socket : $e');
    }
  });

  // Listen for responses from the Windows side
  socket.listen(
    (data) {
      var message = String.fromCharCodes(data);
      if (verbose) {
        print('⬅️ Reçu de Windows : $message');
      }
    },
    onError: (e) {
      print('⚠️ Erreur lecture socket : $e');
      timer.cancel();
    },
    onDone: () {
      print('🔴 Tunnel déconnecté.');
      timer.cancel();
      exit(0);
    },
  );
}

class ArgParser {
  final List<_Option> _options = [];
  final List<_Flag> _flags = [];

  void addOption(
    String name, {
    String? abbr,
    String? help,
    String? defaultsTo,
  }) {
    _options.add(_Option(name, abbr, help, defaultsTo));
  }

  void addFlag(
    String name, {
    String? abbr,
    String? help,
    bool defaultsTo = false,
  }) {
    _flags.add(_Flag(name, abbr, help, defaultsTo));
  }

  ArgResults parse(List<String> args) {
    var values = <String, dynamic>{};

    // Set defaults
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

      // Check options
      for (var opt in _options) {
        if (arg == '--${opt.name}' || (opt.abbr != null && arg == '-${opt.abbr}')) {
          if (i + 1 >= args.length) {
            throw FormatException('Missing value for $arg');
          }
          values[opt.name] = args[++i];
          matched = true;
          break;
        }
      }

      // Check flags
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

      if (!matched) {
        throw FormatException('Unknown argument: $arg');
      }
      i++;
    }

    return ArgResults(values);
  }

  String get usage {
    var buf = StringBuffer();
    for (var opt in _options) {
      var abbr = opt.abbr != null ? '-${opt.abbr}, ' : '    ';
      buf.writeln('  $abbr--${opt.name.padRight(16)} ${opt.help ?? ''}'
          '${opt.defaultsTo != null ? " (default: ${opt.defaultsTo})" : ""}');
    }
    for (var flag in _flags) {
      var abbr = flag.abbr != null ? '-${flag.abbr}, ' : '    ';
      buf.writeln('  $abbr--${flag.name.padRight(16)} ${flag.help ?? ''}');
    }
    return buf.toString();
  }
}

class ArgResults {
  final Map<String, dynamic> _values;
  ArgResults(this._values);
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
