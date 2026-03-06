/// USB/IP protocol v1.1.1 constants.
///
/// All values from the official kernel.org specification:
/// https://docs.kernel.org/usb/usbip_protocol.html
library;

// ---------------------------------------------------------------------------
// Protocol version
// ---------------------------------------------------------------------------

/// USB/IP protocol version 1.1.1 as 16-bit value.
const int usbipVersion = 0x0111;

// ---------------------------------------------------------------------------
// Op-code commands (16-bit, in the op_common header)
// ---------------------------------------------------------------------------

/// Request: list exported USB devices.
const int opReqDevlist = 0x8005;

/// Reply: list of exported USB devices.
const int opRepDevlist = 0x0005;

/// Request: import (attach) a remote USB device.
const int opReqImport = 0x8003;

/// Reply: import result.
const int opRepImport = 0x0003;

// ---------------------------------------------------------------------------
// URB command codes (32-bit, in usbip_header_basic)
// ---------------------------------------------------------------------------

/// Submit an URB (client → server).
const int usbipCmdSubmit = 0x00000001;

/// Unlink a previously submitted URB (client → server).
const int usbipCmdUnlink = 0x00000002;

/// Reply for submitted URB (server → client).
const int usbipRetSubmit = 0x00000003;

/// Reply for URB unlink (server → client).
const int usbipRetUnlink = 0x00000004;

// ---------------------------------------------------------------------------
// Direction (32-bit)
// ---------------------------------------------------------------------------

/// Host → Device (OUT).
const int usbipDirOut = 0;

/// Device → Host (IN).
const int usbipDirIn = 1;

// ---------------------------------------------------------------------------
// Header sizes
// ---------------------------------------------------------------------------

/// Size of the op_common header (version + command + status).
const int opCommonSize = 8;

/// Size of usbip_header_basic (command + seqnum + devid + direction + ep).
const int headerBasicSize = 20;

/// Total size of a CMD_SUBMIT or RET_SUBMIT header (before transfer_buffer).
const int usbipHeaderSize = 48; // 0x30

/// Size of a device info block in OP_REP_DEVLIST / OP_REP_IMPORT.
/// path(256) + busid(32) + busnum(4) + devnum(4) + speed(4) +
/// idVendor(2) + idProduct(2) + bcdDevice(2) + bDeviceClass(1) +
/// bDeviceSubClass(1) + bDeviceProtocol(1) + bConfigurationValue(1) +
/// bNumConfigurations(1) + bNumInterfaces(1)
const int deviceInfoSize = 312; // 0x138

/// Size of an interface info block (4 bytes: class + subclass + protocol + pad).
const int interfaceInfoSize = 4;

/// Size of a busid field.
const int busidSize = 32;

/// Size of a path field.
const int pathSize = 256;

// ---------------------------------------------------------------------------
// USB speed codes
// ---------------------------------------------------------------------------

const int usbSpeedLow = 1;
const int usbSpeedFull = 2;
const int usbSpeedHigh = 3;
const int usbSpeedSuper = 5;

// ---------------------------------------------------------------------------
// Status codes
// ---------------------------------------------------------------------------

/// Success.
const int statusOk = 0;

/// Error.
const int statusError = 1;

/// ECONNRESET (used in UNLINK responses).
const int econnreset = -104; // Linux errno for ECONNRESET
