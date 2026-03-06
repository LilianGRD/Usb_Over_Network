/// Low-level dart:ffi bindings to libusb-1.0.
///
/// This file provides:
/// - C struct definitions matching libusb's memory layout
/// - Function typedefs (native and Dart)
/// - A [LibusbBindings] class that loads the dylib and exposes Dart functions
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Endpoint direction masks
const int libusbEndpointIn = 0x80;
const int libusbEndpointOut = 0x00;
const int libusbEndpointDirMask = 0x80;

/// Transfer type masks (bmAttributes & 0x03)
const int libusbTransferTypeControl = 0;
const int libusbTransferTypeIsochronous = 1;
const int libusbTransferTypeBulk = 2;
const int libusbTransferTypeInterrupt = 3;
const int libusbTransferTypeMask = 0x03;

/// Error codes
const int libusbSuccess = 0;
const int libusbErrorIo = -1;
const int libusbErrorInvalidParam = -2;
const int libusbErrorAccess = -3;
const int libusbErrorNoDevice = -4;
const int libusbErrorNotFound = -5;
const int libusbErrorBusy = -6;
const int libusbErrorTimeout = -7;
const int libusbErrorOverflow = -8;
const int libusbErrorPipe = -9;
const int libusbErrorInterrupted = -10;
const int libusbErrorNoMem = -11;
const int libusbErrorNotSupported = -12;
const int libusbErrorOther = -99;

/// Device class codes
const int libusbClassHid = 0x03;
const int libusbClassMassStorage = 0x08;
const int libusbClassHub = 0x09;
const int libusbClassVendorSpec = 0xFF;

// ---------------------------------------------------------------------------
// Struct definitions (matching C memory layout)
// ---------------------------------------------------------------------------

/// struct libusb_device_descriptor (18 bytes packed)
final class LibusbDeviceDescriptor extends Struct {
  @Uint8()
  external int bLength;

  @Uint8()
  external int bDescriptorType;

  @Uint16()
  external int bcdUSB;

  @Uint8()
  external int bDeviceClass;

  @Uint8()
  external int bDeviceSubClass;

  @Uint8()
  external int bDeviceProtocol;

  @Uint8()
  external int bMaxPacketSize0;

  @Uint16()
  external int idVendor;

  @Uint16()
  external int idProduct;

  @Uint16()
  external int bcdDevice;

  @Uint8()
  external int iManufacturer;

  @Uint8()
  external int iProduct;

  @Uint8()
  external int iSerialNumber;

  @Uint8()
  external int bNumConfigurations;
}

/// struct libusb_endpoint_descriptor
final class LibusbEndpointDescriptor extends Struct {
  @Uint8()
  external int bLength;

  @Uint8()
  external int bDescriptorType;

  @Uint8()
  external int bEndpointAddress;

  @Uint8()
  external int bmAttributes;

  @Uint16()
  external int wMaxPacketSize;

  @Uint8()
  external int bInterval;

  @Uint8()
  external int bRefresh;

  @Uint8()
  external int bSynchAddress;

  /// const unsigned char *extra
  external Pointer<Uint8> extra;

  /// int extra_length
  @Int32()
  external int extraLength;
}

/// struct libusb_interface_descriptor
final class LibusbInterfaceDescriptor extends Struct {
  @Uint8()
  external int bLength;

  @Uint8()
  external int bDescriptorType;

  @Uint8()
  external int bInterfaceNumber;

  @Uint8()
  external int bAlternateSetting;

  @Uint8()
  external int bNumEndpoints;

  @Uint8()
  external int bInterfaceClass;

  @Uint8()
  external int bInterfaceSubClass;

  @Uint8()
  external int bInterfaceProtocol;

  @Uint8()
  external int iInterface;

  /// const struct libusb_endpoint_descriptor *endpoint
  external Pointer<LibusbEndpointDescriptor> endpoint;

  /// const unsigned char *extra
  external Pointer<Uint8> extra;

  /// int extra_length
  @Int32()
  external int extraLength;
}

/// struct libusb_interface
final class LibusbInterface extends Struct {
  /// const struct libusb_interface_descriptor *altsetting
  external Pointer<LibusbInterfaceDescriptor> altsetting;

  /// int num_altsetting
  @Int32()
  external int numAltsetting;
}

/// struct libusb_config_descriptor
final class LibusbConfigDescriptor extends Struct {
  @Uint8()
  external int bLength;

  @Uint8()
  external int bDescriptorType;

  @Uint16()
  external int wTotalLength;

  @Uint8()
  external int bNumInterfaces;

  @Uint8()
  external int bConfigurationValue;

  @Uint8()
  external int iConfiguration;

  @Uint8()
  external int bmAttributes;

  @Uint8()
  external int maxPower;

  /// const struct libusb_interface *interface
  external Pointer<LibusbInterface> interfaces;

  /// const unsigned char *extra
  external Pointer<Uint8> extra;

  /// int extra_length
  @Int32()
  external int extraLength;
}

// ---------------------------------------------------------------------------
// Opaque types — libusb_device and libusb_device_handle are opaque pointers
// ---------------------------------------------------------------------------

final class LibusbDevice extends Opaque {}

final class LibusbDeviceHandle extends Opaque {}

final class LibusbContext extends Opaque {}

// ---------------------------------------------------------------------------
// Native function typedefs
// ---------------------------------------------------------------------------

// libusb_init(libusb_context **ctx) -> int
typedef LibusbInitNative = Int32 Function(Pointer<Pointer<LibusbContext>>);
typedef LibusbInitDart = int Function(Pointer<Pointer<LibusbContext>>);

// libusb_exit(libusb_context *ctx) -> void
typedef LibusbExitNative = Void Function(Pointer<LibusbContext>);
typedef LibusbExitDart = void Function(Pointer<LibusbContext>);

// libusb_get_device_list(ctx, ***list) -> ssize_t
typedef LibusbGetDeviceListNative = IntPtr Function(
  Pointer<LibusbContext>,
  Pointer<Pointer<Pointer<LibusbDevice>>>,
);
typedef LibusbGetDeviceListDart = int Function(
  Pointer<LibusbContext>,
  Pointer<Pointer<Pointer<LibusbDevice>>>,
);

// libusb_free_device_list(**list, unref) -> void
typedef LibusbFreeDeviceListNative = Void Function(
  Pointer<Pointer<LibusbDevice>>,
  Int32,
);
typedef LibusbFreeDeviceListDart = void Function(
  Pointer<Pointer<LibusbDevice>>,
  int,
);

// libusb_get_device_descriptor(dev, *desc) -> int
typedef LibusbGetDeviceDescriptorNative = Int32 Function(
  Pointer<LibusbDevice>,
  Pointer<LibusbDeviceDescriptor>,
);
typedef LibusbGetDeviceDescriptorDart = int Function(
  Pointer<LibusbDevice>,
  Pointer<LibusbDeviceDescriptor>,
);

// libusb_open(dev, **handle) -> int
typedef LibusbOpenNative = Int32 Function(
  Pointer<LibusbDevice>,
  Pointer<Pointer<LibusbDeviceHandle>>,
);
typedef LibusbOpenDart = int Function(
  Pointer<LibusbDevice>,
  Pointer<Pointer<LibusbDeviceHandle>>,
);

// libusb_close(handle) -> void
typedef LibusbCloseNative = Void Function(Pointer<LibusbDeviceHandle>);
typedef LibusbCloseDart = void Function(Pointer<LibusbDeviceHandle>);

// libusb_get_string_descriptor_ascii(handle, index, *data, length) -> int
typedef LibusbGetStringDescriptorAsciiNative = Int32 Function(
  Pointer<LibusbDeviceHandle>,
  Uint8,
  Pointer<Uint8>,
  Int32,
);
typedef LibusbGetStringDescriptorAsciiDart = int Function(
  Pointer<LibusbDeviceHandle>,
  int,
  Pointer<Uint8>,
  int,
);

// libusb_get_active_config_descriptor(dev, **config) -> int
typedef LibusbGetActiveConfigDescriptorNative = Int32 Function(
  Pointer<LibusbDevice>,
  Pointer<Pointer<LibusbConfigDescriptor>>,
);
typedef LibusbGetActiveConfigDescriptorDart = int Function(
  Pointer<LibusbDevice>,
  Pointer<Pointer<LibusbConfigDescriptor>>,
);

// libusb_free_config_descriptor(*config) -> void
typedef LibusbFreeConfigDescriptorNative = Void Function(
  Pointer<LibusbConfigDescriptor>,
);
typedef LibusbFreeConfigDescriptorDart = void Function(
  Pointer<LibusbConfigDescriptor>,
);

// libusb_claim_interface(handle, interface_number) -> int
typedef LibusbClaimInterfaceNative = Int32 Function(
  Pointer<LibusbDeviceHandle>,
  Int32,
);
typedef LibusbClaimInterfaceDart = int Function(
  Pointer<LibusbDeviceHandle>,
  int,
);

// libusb_release_interface(handle, interface_number) -> int
typedef LibusbReleaseInterfaceNative = Int32 Function(
  Pointer<LibusbDeviceHandle>,
  Int32,
);
typedef LibusbReleaseInterfaceDart = int Function(
  Pointer<LibusbDeviceHandle>,
  int,
);

// libusb_set_auto_detach_kernel_driver(handle, enable) -> int
typedef LibusbSetAutoDetachKernelDriverNative = Int32 Function(
  Pointer<LibusbDeviceHandle>,
  Int32,
);
typedef LibusbSetAutoDetachKernelDriverDart = int Function(
  Pointer<LibusbDeviceHandle>,
  int,
);

// libusb_bulk_transfer(handle, endpoint, *data, length, *transferred, timeout) -> int
typedef LibusbBulkTransferNative = Int32 Function(
  Pointer<LibusbDeviceHandle>,
  Uint8,
  Pointer<Uint8>,
  Int32,
  Pointer<Int32>,
  Uint32,
);
typedef LibusbBulkTransferDart = int Function(
  Pointer<LibusbDeviceHandle>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  int,
);

// libusb_interrupt_transfer — same signature as bulk
typedef LibusbInterruptTransferNative = Int32 Function(
  Pointer<LibusbDeviceHandle>,
  Uint8,
  Pointer<Uint8>,
  Int32,
  Pointer<Int32>,
  Uint32,
);
typedef LibusbInterruptTransferDart = int Function(
  Pointer<LibusbDeviceHandle>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  int,
);

// libusb_strerror(errcode) -> const char*
typedef LibusbStrerrorNative = Pointer<Utf8> Function(Int32);
typedef LibusbStrerrorDart = Pointer<Utf8> Function(int);

// ---------------------------------------------------------------------------
// Bindings class — loads the dylib and provides typed Dart functions
// ---------------------------------------------------------------------------

class LibusbBindings {
  final DynamicLibrary _lib;

  late final LibusbInitDart init;
  late final LibusbExitDart exit;
  late final LibusbGetDeviceListDart getDeviceList;
  late final LibusbFreeDeviceListDart freeDeviceList;
  late final LibusbGetDeviceDescriptorDart getDeviceDescriptor;
  late final LibusbOpenDart open;
  late final LibusbCloseDart close;
  late final LibusbGetStringDescriptorAsciiDart getStringDescriptorAscii;
  late final LibusbGetActiveConfigDescriptorDart getActiveConfigDescriptor;
  late final LibusbFreeConfigDescriptorDart freeConfigDescriptor;
  late final LibusbClaimInterfaceDart claimInterface;
  late final LibusbReleaseInterfaceDart releaseInterface;
  late final LibusbSetAutoDetachKernelDriverDart setAutoDetachKernelDriver;
  late final LibusbBulkTransferDart bulkTransfer;
  late final LibusbInterruptTransferDart interruptTransfer;
  late final LibusbStrerrorDart strerror;

  LibusbBindings._(this._lib) {
    init = _lib
        .lookupFunction<LibusbInitNative, LibusbInitDart>('libusb_init');
    exit = _lib
        .lookupFunction<LibusbExitNative, LibusbExitDart>('libusb_exit');
    getDeviceList = _lib
        .lookupFunction<LibusbGetDeviceListNative, LibusbGetDeviceListDart>(
          'libusb_get_device_list',
        );
    freeDeviceList = _lib
        .lookupFunction<LibusbFreeDeviceListNative, LibusbFreeDeviceListDart>(
          'libusb_free_device_list',
        );
    getDeviceDescriptor = _lib
        .lookupFunction<
          LibusbGetDeviceDescriptorNative,
          LibusbGetDeviceDescriptorDart
        >('libusb_get_device_descriptor');
    open = _lib
        .lookupFunction<LibusbOpenNative, LibusbOpenDart>('libusb_open');
    close = _lib
        .lookupFunction<LibusbCloseNative, LibusbCloseDart>('libusb_close');
    getStringDescriptorAscii = _lib
        .lookupFunction<
          LibusbGetStringDescriptorAsciiNative,
          LibusbGetStringDescriptorAsciiDart
        >('libusb_get_string_descriptor_ascii');
    getActiveConfigDescriptor = _lib
        .lookupFunction<
          LibusbGetActiveConfigDescriptorNative,
          LibusbGetActiveConfigDescriptorDart
        >('libusb_get_active_config_descriptor');
    freeConfigDescriptor = _lib
        .lookupFunction<
          LibusbFreeConfigDescriptorNative,
          LibusbFreeConfigDescriptorDart
        >('libusb_free_config_descriptor');
    claimInterface = _lib
        .lookupFunction<LibusbClaimInterfaceNative, LibusbClaimInterfaceDart>(
          'libusb_claim_interface',
        );
    releaseInterface = _lib
        .lookupFunction<
          LibusbReleaseInterfaceNative,
          LibusbReleaseInterfaceDart
        >('libusb_release_interface');
    setAutoDetachKernelDriver = _lib
        .lookupFunction<
          LibusbSetAutoDetachKernelDriverNative,
          LibusbSetAutoDetachKernelDriverDart
        >('libusb_set_auto_detach_kernel_driver');
    bulkTransfer = _lib
        .lookupFunction<LibusbBulkTransferNative, LibusbBulkTransferDart>(
          'libusb_bulk_transfer',
        );
    interruptTransfer = _lib
        .lookupFunction<
          LibusbInterruptTransferNative,
          LibusbInterruptTransferDart
        >('libusb_interrupt_transfer');
    strerror = _lib
        .lookupFunction<LibusbStrerrorNative, LibusbStrerrorDart>(
          'libusb_strerror',
        );
  }

  /// Load libusb from the system.
  /// Tries Homebrew paths (Apple Silicon first, then Intel).
  factory LibusbBindings.load() {
    const paths = [
      '/opt/homebrew/lib/libusb-1.0.dylib', // Apple Silicon
      '/usr/local/lib/libusb-1.0.dylib', // Intel Mac
      'libusb-1.0.dylib', // system path fallback
    ];

    for (var path in paths) {
      try {
        return LibusbBindings._(DynamicLibrary.open(path));
      } catch (_) {
        continue;
      }
    }

    throw UnsupportedError(
      'Could not load libusb-1.0.dylib. '
      'Install it with: brew install libusb',
    );
  }

  /// Get a human-readable error string for a libusb error code.
  String errorString(int code) {
    var ptr = strerror(code);
    return ptr.toDartString();
  }
}
