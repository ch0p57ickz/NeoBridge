# Spec Delta

## ADDED Requirements

### Requirement: Cleanup is the visible default when safe

The system SHALL intend cleanup for each sync by default and SHALL show that
intent before transfer. A user MAY choose retention for that sync. Cleanup SHALL
run only when the evidence gate and verified import and export conditions pass;
otherwise the system SHALL retain pen data and report the reason. A retention
choice SHALL NOT carry into a later sync without a new choice.

#### Scenario: No choice means cleanup when safe

- **WHEN** a sync runs without a cleanup choice being made
- **THEN** cleanup is intended, and deletion is requested only after all safety conditions pass

#### Scenario: A choice does not persist silently

- **WHEN** a sync ran in retaining mode and a later sync runs
- **THEN** the later sync presents default cleanup before its transfers are stored

#### Scenario: Retention stays reachable

- **WHEN** the user chooses retention for a sync
- **THEN** that sync requests no deletion and the pen's strokes are retained

#### Scenario: Cleanup is unavailable

- **WHEN** the evidence gate is closed or a requested export fails
- **THEN** the pen's copy is retained and the user sees why cleanup was skipped

### Requirement: A deletion request is journaled until the pen confirms it

The system SHALL durably record the exact deletion scope before sending it,
mark it requested before bytes can reach the pen, and mark it confirmed only
when an evidence-backed matching pen response proves removal of that scope.
A request whose effect is unknown SHALL remain outstanding. The system SHALL
NOT resend it automatically; it MAY resolve it after a fresh read proves an
unambiguous outcome for the recorded scope.

#### Scenario: Interrupted between recording and sending

- **WHEN** the system records a deletion request and stops before the pen receives it
- **THEN** the request is reported as outstanding and the library's stored strokes remain available

#### Scenario: Pen confirms the request

- **WHEN** the pen returns a matching response whose meaning was physically verified as removal of the recorded scope
- **THEN** the request is recorded as confirmed for that scope

#### Scenario: No acknowledgement arrives

- **WHEN** a deletion command is sent and no acknowledgement arrives before its timeout
- **THEN** the request remains outstanding and the library's stored strokes remain available

#### Scenario: An unconfirmed request is not repeated blindly

- **WHEN** a request is outstanding and a new sync begins
- **THEN** the system does not send a second deletion command for pages it has not confirmed

#### Scenario: Fresh read resolves an outstanding request

- **WHEN** a fresh read and the proven command scope show unambiguously whether the recorded data remains on the pen
- **THEN** the system records the observed outcome and avoids deleting any newly written or unverified data
