import 'package:noports_core/sshnp.dart';
import 'package:noports_core/sshnp_foundation.dart';
import 'package:at_client/at_client.dart';

void main() async {
  var params = SshnpParams(
    clientAtSign: '@demo1',
    sshnpdAtSign: '@demo2',
    srvdAtSign: '@rv_eu',
    device: 'test',
    only443: true,
    relayAuthMode: RelayAuthMode.escr,
    idleTimeout: 60,
    localSshOptions: ['-L 3240:127.0.0.1:3240'],
    verbose: true,
  );
  print('compiles successfully');
}
