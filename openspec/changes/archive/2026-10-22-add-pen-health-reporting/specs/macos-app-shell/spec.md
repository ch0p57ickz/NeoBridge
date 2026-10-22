# Spec Delta

## ADDED Requirements

### Requirement: Pen battery and storage presentation

After a successful A1 read, the app SHALL show battery percentage, charging state, and percentage of pen storage used in Connection Details. It SHALL clear the previous measurement when a new read begins and SHALL not show an unmeasured value as current.

#### Scenario: Successful state query

- **WHEN** the pen reports 94% battery, not charging, and 10% storage used
- **THEN** Connection Details shows those measurements with their correct labels

#### Scenario: Read begins again

- **WHEN** a new read begins after an earlier completed read
- **THEN** the earlier battery and storage measurements are no longer shown as current
