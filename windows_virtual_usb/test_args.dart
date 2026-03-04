import 'package:args/args.dart';
void main(List<String> args) {
  var parser = ArgParser()
      ..addOption('atsign', abbr: 'a', mandatory: true)
      ..addOption('mac-atsign', abbr: 'm', mandatory: true)
      ..addOption('namespace', abbr: 'n');
  var results = parser.parse(args);
  print(results['mac-atsign']);
}
