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

- **WHEN** a scan finishes without a device advertising `Neosmartpen_A1` while the adapter is still ready
- **THEN** the app reports that no pen was found and stops scanning

#### Scenario: Several matching pens

- **WHEN** more than one pen advertises `Neosmartpen_A1`
- **THEN** the app asks the user to choose one for this connection without showing or storing its Bluetooth address

### Requirement: Scan window

The scan window SHALL outlast the silence before a pen advertises, including the
delay after the pen is switched on, and SHALL end soon after the first match once a
second pen has had its chance to appear. The physical A1 advertises in bursts and can
stay silent for several seconds after power-on, so a short fixed window reports
"no pen found" while the pen is in range.

#### Scenario: A pen that advertises late in the window

- **WHEN** the only matching pen's first advertisement arrives after the scan has been running for a while
- **THEN** the app still selects it, so long as it arrives within the scan window

#### Scenario: A pen that has just been switched on

- **WHEN** a read starts while the pen is still powering on and not yet advertising
- **THEN** the app keeps scanning until the pen appears, rather than reporting that no pen was found

#### Scenario: One pen settles the scan early

- **WHEN** one pen has advertised and no second pen appears within the confirmation delay
- **THEN** the app connects to that pen without waiting out the whole window

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

### Requirement: Connection lifetime

An attempt SHALL release the pen when it ends, whether it succeeded or failed,
because a connected pen stops advertising: an attempt that kept the link would
make the app's own next read report that no pen was found, and would keep the pen
from its other owners. Releasing the link SHALL send no deletion request, so the
strokes stay on the pen.

#### Scenario: Completed read releases the pen

- **WHEN** a read completes
- **THEN** the app disconnects from the pen, and a following read finds it advertising again

#### Scenario: Failed read releases the pen

- **WHEN** a read fails after the connection was established
- **THEN** the app disconnects from the pen before it reports the failure

### Requirement: Bluetooth permission handling

The app SHALL declare a Bluetooth usage description and SHALL report a
descriptive error naming the adapter state whenever the adapter is not ready to
scan: access not granted, Bluetooth switched off, or no Bluetooth LE adapter. A
not-ready adapter SHALL be reported instead of a missing pen, both before a scan
and when it stops being ready during a scan or a connection setup. An unresolved
adapter state SHALL be waited for, within a bounded window, before it is
reported.

#### Scenario: Permission denied

- **WHEN** Bluetooth access is denied
- **THEN** the app reports that permission is required and does not scan

#### Scenario: Permission granted

- **WHEN** Bluetooth access is granted
- **THEN** the app can begin scanning for the pen

#### Scenario: Adapter not ready before a scan

- **WHEN** the adapter is powered off or unsupported
- **THEN** the app reports the adapter state and does not scan

#### Scenario: Bluetooth state has not resolved when a read starts

- **WHEN** a read starts before CoreBluetooth has reported the adapter state
- **THEN** the app waits, within a bounded window, for the state to resolve and scans once it is ready

#### Scenario: Bluetooth state never resolves

- **WHEN** the adapter state is still unknown after the bounded window
- **THEN** the app reports the adapter state and does not scan

#### Scenario: Adapter stops being ready mid-scan

- **WHEN** Bluetooth is switched off while a scan is running
- **THEN** the app reports the adapter state rather than reporting that no pen was found

#### Scenario: Adapter stops being ready during the connection setup

- **WHEN** Bluetooth is switched off after a pen was found but before the channel is ready
- **THEN** the app reports the adapter state and does not begin the handshake

### Requirement: Bounded Bluetooth setup

The Bluetooth setup phase SHALL be bounded. CoreBluetooth has no timeout of its
own, so a scan, a connection, a discovery, or a notification subscription that
never completes SHALL fail the attempt rather than wait indefinitely.

#### Scenario: Adapter never answers

- **WHEN** a CoreBluetooth callback the setup phase waits for never arrives
- **THEN** the attempt fails with a timeout instead of waiting indefinitely
