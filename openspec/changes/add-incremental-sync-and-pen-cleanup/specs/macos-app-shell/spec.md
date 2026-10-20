# Spec Delta

## ADDED Requirements

### Requirement: Default cleanup and retention choice are visible

The app SHALL show before transfer that a safe, completed sync normally removes
its verified data from the pen, and SHALL offer retention for that sync. It
SHALL report after a sync whether the pen's copy was retained, reclaimed,
cleanup was skipped with a reason, or a deletion request remains outstanding.

#### Scenario: Default cleanup is presented

- **WHEN** a sync is about to start and the user has made no choice
- **THEN** the app states that verified data will normally be removed after successful import and export and offers retention

#### Scenario: Retention is chosen

- **WHEN** the user chooses retention
- **THEN** the sync requests no deletion and the app shows that the pen's strokes will be kept

#### Scenario: Completed sync reports the pen's copy

- **WHEN** a sync completes and the pen confirms removal of the verified scope
- **THEN** the app reports that the stored pages were reclaimed from the pen and remain available in the library

#### Scenario: Cleanup is skipped

- **WHEN** a transfer, import, export, or evidence gate prevents cleanup
- **THEN** the app reports that the pen retained its data and names the blocking condition

#### Scenario: Unconfirmed deletion is reported as outstanding

- **WHEN** a sync completes but its deletion request was not confirmed
- **THEN** the app reports the request as outstanding rather than as reclamation
