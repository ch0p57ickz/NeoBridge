# Spec Delta

## ADDED Requirements

### Requirement: Accurate save and export labelling
The app SHALL label each read according to its actual storage and export outcome. It SHALL NOT claim a read is saved when storage fails, and SHALL NOT claim an export succeeded when publication fails.

#### Scenario: Completed sync is labelled saved
- **WHEN** a read commits its strokes and publishes requested files
- **THEN** the app states that results were saved and shows the export destination

#### Scenario: Read action is labelled clearly
- **WHEN** the app offers the action that retrieves offline strokes for durable import
- **THEN** it describes the action as saving the pen data

#### Scenario: Export fails after storage commit
- **WHEN** the library commit succeeds but file publication fails
- **THEN** the app distinguishes saved library data from the failed export, identifies each file that was published and each file that failed, and offers a retry

#### Scenario: Read finds no strokes
- **WHEN** a complete read finds no strokes
- **THEN** the app reports that no strokes were found and does not claim that files were exported

## MODIFIED Requirements

### Requirement: Connection and sync presentation

The app SHALL present the current connection state and, after a read, the decoded stroke, dot, and page counts. The app SHALL distinguish scanning, connecting, verifying, syncing, saving, exporting, complete, and failed states. A completed result SHALL identify the notes read and state where the data was saved.

#### Scenario: Show sync results

- **WHEN** a read, save, and requested export complete
- **THEN** the menu-bar item or window shows the reported stroke, dot, and page counts and identifies the saved result

#### Scenario: Show progress during sync

- **WHEN** a transfer or subsequent save or export is in progress
- **THEN** the app indicates the current operation instead of showing stale results

#### Scenario: Failed transfer has partial data

- **WHEN** a transfer fails after some packets arrive
- **THEN** the app presents the failure and does not label partial counts as a completed sync

## REMOVED Requirements

### Requirement: Results are not persisted in this version
**Reason**: Durable storage and export are no longer deferred; reads now commit to the library and publish files, so a requirement stating that results are held only in memory is false.
**Migration**: No user action is required, because memory-only reads had no durable data to migrate. The app now labels each read by its actual storage and export outcome, as specified by "Accurate save and export labelling".
