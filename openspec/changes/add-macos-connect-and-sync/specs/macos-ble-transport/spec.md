# Spec Delta

## Purpose

Defines how the macOS app finds, connects to, and exchanges bytes with a Neo
Smartpen A1 over CoreBluetooth, satisfying the portable `PenTransport`
contract.

## ADDED Requirements

### Requirement: Discovery by advertised name

The app SHALL discover the pen by its advertised name `Neosmartpen_A1` and SHALL
NOT identify it by a cached Bluetooth address, because the pen advertises a
random static address that changes across power cycles.

If several pens advertise the matching name, the app SHALL require an explicit
selection for the current connection rather than silently choosing one.

#### Scenario: Pen found after a power cycle

- **WHEN** a scan runs and a device advertising `Neosmartpen_A1` is in range
- **THEN** the app selects that pen regardless of its current address

#### Scenario: No matching pen

- **WHEN** a scan finishes without a device advertising `Neosmartpen_A1`
- **THEN** the app reports that no pen was found and stops scanning

#### Scenario: Several matching pens

- **WHEN** more than one pen advertises `Neosmartpen_A1`
- **THEN** the app asks the user to choose one for this connection without showing or storing its Bluetooth address

### Requirement: Connection and channel discovery

On connecting, the app SHALL use the pen's write characteristic for outbound
frames and its notify characteristic for inbound frames, and SHALL deliver
inbound bytes in arrival order even when one frame is split across several
notifications. Characteristic UUIDs and write mode SHALL come from official
SDK evidence or an A1 GATT capture before production use; the app SHALL fail
discovery if a required channel is absent or notifications cannot be enabled.

#### Scenario: Frame split across notifications

- **WHEN** the pen delivers one frame in more than one notification
- **THEN** the transport emits the chunks in order so the decoder can reassemble the frame

#### Scenario: Connection failure

- **WHEN** the connection attempt or characteristic discovery fails
- **THEN** the app reports a descriptive error and does not begin the handshake

#### Scenario: Notification setup fails

- **WHEN** the expected notify characteristic exists but notifications cannot be enabled
- **THEN** the app fails before sending the version request

### Requirement: Disconnect and interruption signaling

The transport SHALL finish its inbound stream when the pen disconnects normally
and SHALL throw when the connection is interrupted, so the session can tell
completion from failure. A stream that finishes before the session has received
an end-position packet remains an incomplete transfer regardless of the
transport's disconnect classification.

#### Scenario: Normal disconnect

- **WHEN** the pen disconnects after a transfer completes
- **THEN** the inbound stream finishes without error

#### Scenario: Interrupted connection

- **WHEN** the connection drops mid-transfer
- **THEN** the inbound stream throws and the session reports a failure

### Requirement: Bluetooth permission handling

The app SHALL declare a Bluetooth usage description and SHALL report a
descriptive error when the user has not granted Bluetooth access.

#### Scenario: Permission denied

- **WHEN** Bluetooth access is denied
- **THEN** the app reports that permission is required and does not scan

#### Scenario: Permission granted

- **WHEN** Bluetooth access is granted
- **THEN** the app can begin scanning for the pen
