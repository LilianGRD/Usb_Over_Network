/// High-level USB device management built on top of [LibusbBindings].
///
/// Provides:
/// - [UsbDeviceInfo] — immutable data about a USB device
/// - [EndpointInfo] — describes a single USB endpoint (IN/OUT, bulk/interrupt)
/// - [UsbManager] — enumerate, open, claim, read/write, close USB devices
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'libusb_ffi.dart';

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// Information about a USB device discovered on the bus.
class UsbDeviceInfo {
  final int vendorId;
  final int productId;
  final String manufacturer;
  final String product;
  final int deviceClass;
  final int deviceSubClass;
  final int deviceProtocol;
  final int index; // internal index in the device list

  /// Pointer to the libusb_device (kept for opening later)
  final Pointer<LibusbDevice> _devicePtr;

  UsbDeviceInfo({
    required this.vendorId,
    required this.productId,
    required this.manufacturer,
    required this.product,
    required this.deviceClass,
    required this.deviceSubClass,
    required this.deviceProtocol,
    required this.index,
    required Pointer<LibusbDevice> devicePtr,
  }) : _devicePtr = devicePtr;

  /// Formatted VID:PID string like "05ac:828f"
  String get vidPid =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')}';

  /// Human-readable class name
  String get className => _classCodeName(deviceClass);

  @override
  String toString() {
    var name =
        manufacturer.isNotEmpty || product.isNotEmpty
            ? '$manufacturer - $product'
            : 'Unknown Device';
    return '$name (VID: ${vendorId.toRadixString(16).padLeft(4, '0')}, '
        'PID: ${productId.toRadixString(16).padLeft(4, '0')}, '
        'Class: $className)';
  }
}

/// Information about a USB endpoint.
class EndpointInfo {
  final int address;
  final int attributes;
  final int maxPacketSize;
  final int interval;

  EndpointInfo({
    required this.address,
    required this.attributes,
    required this.maxPacketSize,
    required this.interval,
  });

  /// True if this is an IN endpoint (device → host).
  bool get isIn => (address & libusbEndpointDirMask) == libusbEndpointIn;

  /// True if this is an OUT endpoint (host → device).
  bool get isOut => !isIn;

  /// Transfer type (bulk, interrupt, control, isochronous).
  int get transferType => attributes & libusbTransferTypeMask;

  String get transferTypeName {
    switch (transferType) {
      case libusbTransferTypeBulk:
        return 'Bulk';
      case libusbTransferTypeInterrupt:
        return 'Interrupt';
      case libusbTransferTypeControl:
        return 'Control';
      case libusbTransferTypeIsochronous:
        return 'Isochronous';
      default:
        return 'Unknown';
    }
  }

  String get directionName => isIn ? 'IN' : 'OUT';

  @override
  String toString() =>
      'EP 0x${address.toRadixString(16).padLeft(2, '0')} '
      '$directionName $transferTypeName (max: $maxPacketSize bytes)';
}

// ---------------------------------------------------------------------------
// UsbManager — main interface
// ---------------------------------------------------------------------------

/// Manages the libusb lifecycle and provides high-level USB operations.
class UsbManager {
  final LibusbBindings _lib;
  Pointer<LibusbContext>? _ctx;
  Pointer<LibusbDeviceHandle>? _handle;
  int _claimedInterface = -1;

  // Keep the device list pointer alive so device pointers remain valid
  Pointer<Pointer<LibusbDevice>>? _deviceListPtr;

  UsbManager() : _lib = LibusbBindings.load();

  /// Initialize the libusb context. Must be called before any other method.
  void init() {
    var ctxPtr = calloc<Pointer<LibusbContext>>();
    var rc = _lib.init(ctxPtr);
    if (rc != libusbSuccess) {
      calloc.free(ctxPtr);
      throw UsbException('libusb_init failed', rc, _lib);
    }
    _ctx = ctxPtr.value;
    calloc.free(ctxPtr);
  }

  /// Cleanup: release interface, close device, free list, exit libusb.
  void dispose() {
    if (_handle != null) {
      if (_claimedInterface >= 0) {
        _lib.releaseInterface(_handle!, _claimedInterface);
        _claimedInterface = -1;
      }
      _lib.close(_handle!);
      _handle = null;
    }
    if (_deviceListPtr != null) {
      _lib.freeDeviceList(_deviceListPtr!, 1);
      _deviceListPtr = null;
    }
    if (_ctx != null) {
      _lib.exit(_ctx!);
      _ctx = null;
    }
  }

  /// Enumerate all USB devices on the bus.
  /// Returns a list of [UsbDeviceInfo] with VID, PID, and manufacturer/product names.
  List<UsbDeviceInfo> listDevices() {
    _ensureInit();

    // Free any previous device list
    if (_deviceListPtr != null) {
      _lib.freeDeviceList(_deviceListPtr!, 1);
      _deviceListPtr = null;
    }

    var listPtrPtr = calloc<Pointer<Pointer<LibusbDevice>>>();
    var count = _lib.getDeviceList(_ctx!, listPtrPtr);
    if (count < 0) {
      calloc.free(listPtrPtr);
      throw UsbException('libusb_get_device_list failed', count, _lib);
    }

    _deviceListPtr = listPtrPtr.value;
    calloc.free(listPtrPtr);

    var devices = <UsbDeviceInfo>[];
    var descPtr = calloc<LibusbDeviceDescriptor>();

    for (var i = 0; i < count; i++) {
      var dev = (_deviceListPtr! + i).value;
      var rc = _lib.getDeviceDescriptor(dev, descPtr);
      if (rc != libusbSuccess) continue;

      var desc = descPtr.ref;

      // Skip hubs
      if (desc.bDeviceClass == libusbClassHub) continue;

      // Try to open the device briefly to read string descriptors
      var manufacturer = '';
      var product = '';

      var handlePtr = calloc<Pointer<LibusbDeviceHandle>>();
      var openRc = _lib.open(dev, handlePtr);
      if (openRc == libusbSuccess) {
        var handle = handlePtr.value;
        manufacturer = _readStringDescriptor(handle, desc.iManufacturer);
        product = _readStringDescriptor(handle, desc.iProduct);
        _lib.close(handle);
      }
      calloc.free(handlePtr);

      devices.add(UsbDeviceInfo(
        vendorId: desc.idVendor,
        productId: desc.idProduct,
        manufacturer: manufacturer,
        product: product,
        deviceClass: desc.bDeviceClass,
        deviceSubClass: desc.bDeviceSubClass,
        deviceProtocol: desc.bDeviceProtocol,
        index: i,
        devicePtr: dev,
      ));
    }

    calloc.free(descPtr);
    return devices;
  }

  /// Open a device and claim its first interface.
  /// Throws [UsbException] on failure (including access denied on macOS).
  void openDevice(UsbDeviceInfo device, {int interfaceNumber = 0}) {
    _ensureInit();

    // Close any previously opened device
    if (_handle != null) {
      closeDevice();
    }

    var handlePtr = calloc<Pointer<LibusbDeviceHandle>>();
    var rc = _lib.open(device._devicePtr, handlePtr);
    if (rc != libusbSuccess) {
      calloc.free(handlePtr);
      throw UsbException('Cannot open device ${device.vidPid}', rc, _lib);
    }
    _handle = handlePtr.value;
    calloc.free(handlePtr);

    // Try to auto-detach the kernel driver (macOS may have one attached)
    _lib.setAutoDetachKernelDriver(_handle!, 1);

    // Claim the interface
    rc = _lib.claimInterface(_handle!, interfaceNumber);
    if (rc != libusbSuccess) {
      _lib.close(_handle!);
      _handle = null;
      throw UsbException(
        'Cannot claim interface $interfaceNumber on ${device.vidPid}',
        rc,
        _lib,
      );
    }
    _claimedInterface = interfaceNumber;
  }

  /// Get the endpoints for the active configuration of the currently opened device.
  List<EndpointInfo> getEndpoints(UsbDeviceInfo device) {
    _ensureInit();

    var configPtrPtr = calloc<Pointer<LibusbConfigDescriptor>>();
    var rc = _lib.getActiveConfigDescriptor(device._devicePtr, configPtrPtr);
    if (rc != libusbSuccess) {
      calloc.free(configPtrPtr);
      throw UsbException('Cannot get config descriptor', rc, _lib);
    }

    var config = configPtrPtr.value.ref;
    var endpoints = <EndpointInfo>[];

    for (var i = 0; i < config.bNumInterfaces; i++) {
      var iface = (config.interfaces + i).ref;
      if (iface.numAltsetting <= 0) continue;

      var alt = iface.altsetting.ref; // Use first alt setting
      for (var e = 0; e < alt.bNumEndpoints; e++) {
        var ep = (alt.endpoint + e).ref;
        endpoints.add(EndpointInfo(
          address: ep.bEndpointAddress,
          attributes: ep.bmAttributes,
          maxPacketSize: ep.wMaxPacketSize,
          interval: ep.bInterval,
        ));
      }
    }

    _lib.freeConfigDescriptor(configPtrPtr.value);
    calloc.free(configPtrPtr);
    return endpoints;
  }

  /// Read data from an IN endpoint using bulk or interrupt transfer.
  /// Returns the bytes read, or empty [Uint8List] on timeout.
  /// Throws [UsbException] on errors other than timeout.
  Uint8List readEndpoint(
    int endpointAddress, {
    int maxLength = 1024,
    int timeoutMs = 1000,
  }) {
    _ensureHandle();

    var buffer = calloc<Uint8>(maxLength);
    var transferred = calloc<Int32>();

    // Determine transfer type based on endpoint address
    var rc = _lib.bulkTransfer(
      _handle!,
      endpointAddress,
      buffer,
      maxLength,
      transferred,
      timeoutMs,
    );

    if (rc == libusbErrorTimeout) {
      calloc.free(buffer);
      calloc.free(transferred);
      return Uint8List(0);
    }

    if (rc != libusbSuccess) {
      calloc.free(buffer);
      calloc.free(transferred);
      throw UsbException('Read failed on EP 0x${endpointAddress.toRadixString(16)}', rc, _lib);
    }

    var count = transferred.value;
    var result = Uint8List(count);
    for (var i = 0; i < count; i++) {
      result[i] = (buffer + i).value;
    }

    calloc.free(buffer);
    calloc.free(transferred);
    return result;
  }

  /// Write data to an OUT endpoint using bulk transfer.
  /// Returns the number of bytes transferred.
  int writeEndpoint(
    int endpointAddress,
    Uint8List data, {
    int timeoutMs = 1000,
  }) {
    _ensureHandle();

    var buffer = calloc<Uint8>(data.length);
    for (var i = 0; i < data.length; i++) {
      (buffer + i).value = data[i];
    }

    var transferred = calloc<Int32>();
    var rc = _lib.bulkTransfer(
      _handle!,
      endpointAddress,
      buffer,
      data.length,
      transferred,
      timeoutMs,
    );

    var count = transferred.value;
    calloc.free(buffer);
    calloc.free(transferred);

    if (rc != libusbSuccess && rc != libusbErrorTimeout) {
      throw UsbException('Write failed on EP 0x${endpointAddress.toRadixString(16)}', rc, _lib);
    }
    return count;
  }

  /// Close the currently opened device and release the interface.
  void closeDevice() {
    if (_handle != null) {
      if (_claimedInterface >= 0) {
        _lib.releaseInterface(_handle!, _claimedInterface);
        _claimedInterface = -1;
      }
      _lib.close(_handle!);
      _handle = null;
    }
  }

  // --- Private helpers ---

  void _ensureInit() {
    if (_ctx == null) {
      throw StateError('UsbManager not initialized. Call init() first.');
    }
  }

  void _ensureHandle() {
    _ensureInit();
    if (_handle == null) {
      throw StateError('No device opened. Call openDevice() first.');
    }
  }

  String _readStringDescriptor(Pointer<LibusbDeviceHandle> handle, int index) {
    if (index == 0) return '';
    var buf = calloc<Uint8>(256);
    var rc = _lib.getStringDescriptorAscii(handle, index, buf, 256);
    if (rc <= 0) {
      calloc.free(buf);
      return '';
    }
    var result = StringBuffer();
    for (var i = 0; i < rc; i++) {
      result.writeCharCode((buf + i).value);
    }
    calloc.free(buf);
    return result.toString();
  }
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

/// Exception thrown for libusb errors.
class UsbException implements Exception {
  final String message;
  final int errorCode;
  final String errorName;

  UsbException(this.message, this.errorCode, LibusbBindings lib)
      : errorName = lib.errorString(errorCode);

  /// True if this is an access denied error (common on macOS for HID devices).
  bool get isAccessDenied => errorCode == libusbErrorAccess;

  /// True if the device was not found or disconnected.
  bool get isNoDevice => errorCode == libusbErrorNoDevice;

  /// True if the device or interface is busy.
  bool get isBusy => errorCode == libusbErrorBusy;

  @override
  String toString() => '$message: $errorName (code: $errorCode)';
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _classCodeName(int classCode) {
  switch (classCode) {
    case 0x00:
      return 'Per-Interface';
    case 0x01:
      return 'Audio';
    case 0x02:
      return 'Communication';
    case libusbClassHid:
      return 'HID';
    case 0x05:
      return 'Physical';
    case 0x06:
      return 'Image';
    case 0x07:
      return 'Printer';
    case libusbClassMassStorage:
      return 'Mass Storage';
    case libusbClassHub:
      return 'Hub';
    case 0x0a:
      return 'Data';
    case 0x0b:
      return 'Smart Card';
    case 0x0e:
      return 'Video';
    case 0x0f:
      return 'Personal Healthcare';
    case 0xe0:
      return 'Wireless';
    case 0xef:
      return 'Miscellaneous';
    case 0xfe:
      return 'Application';
    case libusbClassVendorSpec:
      return 'Vendor Specific';
    default:
      return 'Unknown (0x${classCode.toRadixString(16)})';
  }
}
