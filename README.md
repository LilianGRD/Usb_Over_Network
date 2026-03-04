# Usb Over Network

This project enables forwarding USB data from a Mac (which lacks drivers) over an atPlatform encrypted socket tunnel to a Windows virtual USB hub (which contains the drivers and operates the device).

## System Architecture

The overarching system comprises the following node abstractions and agents:

- **AtMega 128 board**: The IoT device we are connecting to, typically an autonomous device or an instrument representing a shared key under a person's atSign.
- **Mac laptop**: Host process machine lacking specific USB drivers.
- **Mac USB Forwarder**: A Dart process (interacting via tools like `libusb` or `usbip`) that reads standard USB data and shuttles them as end-to-end encrypted streams.
- **atPlatform / atDirectory**: The intermediate encrypted rendezvous point and socket tunnel provider.
- **Windows virtual USB hub**: A Dart process that receives securely routed data from the `atPlatform` and injects it into a locally hosted virtual driver pool, effectively simulating a direct physical USB attachment.
- **Windows distant machine**: Host process containing drivers that reads the injected USB data.
- **AVR Compiler/Flasher**: Tools like standard IDEs or avrdude writing data that goes back through the pipeline as async operations over the `atPlatform`, or directly locally if executed there.

## Details & Mappings

### Node & atSign Mapping
- **Mac Laptop / USB Forwarder**: Uses an atSign configured to run a continuous data publisher over notifications and standard atClient operations.
- **Windows Distant Machine / Hub**: Uses an atSign configured to run an atPlatform consumer/subscriber.

**Namespace**: `usbovernetwork`

### Data Flow Diagram

1. **AtMega 128 board** `<-- Physical USB stream -->` **Mac laptop**
2. **Mac laptop (Host Process)** `<-- Host Process async -->` **Mac usb forwarder**
3. **Mac usb forwarder** `====== atPlatform Socket Tunnel stream ======>` **atPlatform/ atDirectory**
4. **atPlatform/ atDirectory** `====== atPlatform Socket Tunnel stream ======>` **Windows virtual USB hub**
5. **Windows virtual USB hub** `<-- Host Process async -->` **Windows distant machine**
6. **Windows distant machine** `<-- Host Process async -->` **AVR Compiler/Flasher**
7. **AVR Compiler/Flasher** `<-- async -->` **Windows virtual USB hub** *(Sends output back for forwarding)*

### Notification Key Tables

We use the generic pub/sub model provided by atPlatform `notificationService`.

| Flow | Key Pattern | Type | Decrypt | Purpose |
| ---- | ----------- | ---- | ------- | ------- |
| **Stream USB (Mac -> Win)** | `stream.usb.*.usbovernetwork` | Stream / Notify | `true` | Constantly pushes raw USB buffers and events to the Windows client. |
| **Flashing (Win -> Mac)** | `flash.usb.*.usbovernetwork` | Async | `true` | Avrdude/IDE flash instructions pushed back to the mac. |

### Configuration
Requires standard `atKeys` files to authenticate the underlying client SDKs. Dart agent instances will provision unique Hive storage directories for ephemeral sessions to prevent mutex locks over local db.

For direct TCP connectivity for USB (e.g. tunneling USB IP proxy sockets directly), `noports_core` architecture is recommended due to low-latency stream management.
