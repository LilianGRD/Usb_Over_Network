/// Interactive CLI helpers for the USB forwarder.
///
/// Separates display/input logic from the USB and networking code.
library;

import 'dart:io';

import 'usb_device.dart';

/// Print the list of detected USB devices with numbered indices.
void printDeviceList(List<UsbDeviceInfo> devices) {
  if (devices.isEmpty) {
    print('\n⚠️  Aucun périphérique USB détecté.');
    print('    Vérifiez que vos périphériques sont bien branchés.\n');
    return;
  }

  print('\n🔌 Périphériques USB détectés :\n');
  print('${'─' * 72}');
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i];
    var name =
        d.manufacturer.isNotEmpty || d.product.isNotEmpty
            ? '${d.manufacturer}${d.manufacturer.isNotEmpty && d.product.isNotEmpty ? ' - ' : ''}${d.product}'
            : 'Périphérique inconnu';
    var vid = d.vendorId.toRadixString(16).padLeft(4, '0');
    var pid = d.productId.toRadixString(16).padLeft(4, '0');
    print('  [${i + 1}] $name');
    print('      VID: $vid  PID: $pid  Classe: ${d.className}');
  }
  print('${'─' * 72}\n');
}

/// Prompt the user to select a device by number.
/// Returns the 0-based index, or -1 if the user wants to quit.
int promptDeviceSelection(int deviceCount) {
  while (true) {
    stdout.write('Entrez le numéro du périphérique à partager (q pour quitter) : ');
    var input = stdin.readLineSync()?.trim();

    if (input == null || input.toLowerCase() == 'q') {
      return -1;
    }

    var num = int.tryParse(input);
    if (num == null || num < 1 || num > deviceCount) {
      print('❌ Choix invalide. Entrez un nombre entre 1 et $deviceCount.\n');
      continue;
    }

    return num - 1;
  }
}

/// Print endpoint details for the selected device.
void printEndpoints(List<EndpointInfo> endpoints) {
  if (endpoints.isEmpty) {
    print('  ⚠️  Aucun endpoint trouvé pour ce périphérique.');
    return;
  }

  print('  📡 Endpoints disponibles :');
  for (var ep in endpoints) {
    print('     $ep');
  }
  print('');
}

/// Print a formatted error message.
void printError(String message) {
  print('\n❌ Erreur : $message\n');
}

/// Print a formatted status message.
void printStatus(String message) {
  print(message);
}

/// Print the access denied help message and ask to retry.
/// Returns true if the user wants to choose another device.
bool promptRetryAfterAccessDenied(String deviceName) {
  print('\n⛔ Accès refusé au périphérique "$deviceName".');
  print('   macOS protège certains périphériques (HID, clavier, trackpad).');
  print('   Choisissez un autre périphérique ou lancez avec sudo (non recommandé).\n');
  stdout.write('Voulez-vous choisir un autre périphérique ? (o/n) : ');
  var input = stdin.readLineSync()?.trim().toLowerCase();
  return input == 'o' || input == 'oui' || input == 'y' || input == 'yes';
}
