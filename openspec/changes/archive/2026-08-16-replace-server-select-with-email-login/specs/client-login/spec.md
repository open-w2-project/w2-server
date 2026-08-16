## Purpose

Defines how a player gets from launching the client to an authenticated session: what the login
screen asks for, what it rejects before touching the network, and which server it talks to. It also
records what the login flow deliberately no longer offers — server groups, channels, and any
client-side capacity limit.

## ADDED Requirements

### Requirement: Login screen is the first interactive screen

The client SHALL present the login screen as soon as the pre-game scene becomes current. It SHALL
NOT present a server-group list, a channel list, or any intermediate selection step before the
login fields.

#### Scenario: Client reaches the pre-game scene

- **WHEN** the client finishes startup and enters the pre-game scene
- **THEN** the email field, the password field and the login button are visible and interactive
- **AND** no server or channel selection controls are shown

#### Scenario: Player returns from character selection

- **WHEN** the player backs out of character selection to the pre-game scene
- **THEN** the login screen is shown directly, with no selection step in between

### Requirement: Identity is an email address

The login screen SHALL accept an email address as the account identity. The field SHALL accept at
least 63 characters. The client SHALL reject, without contacting the server, an entry that is
shorter than 6 characters, longer than 63 characters, or does not contain an `@` with at least one
character before it and a `.` at least one character after it.

#### Scenario: Well-formed email

- **WHEN** the player enters `player@example.com` and a valid password, and confirms
- **THEN** the client attempts to connect and sends a login request

#### Scenario: Missing at-sign

- **WHEN** the player enters `player.example.com` and confirms
- **THEN** the client shows a validation message and sends nothing

#### Scenario: Long address

- **WHEN** the player enters a 63-character email address
- **THEN** the field accepts every character and the client sends the address in full

#### Scenario: Over-long address

- **WHEN** the player enters an address longer than 63 characters
- **THEN** the client shows a validation message and sends nothing

### Requirement: Password constraints

The password field SHALL accept at least 63 characters and SHALL be masked on screen. The client
SHALL reject, without contacting the server, a password shorter than 4 characters or longer than 63
characters.

#### Scenario: Short password

- **WHEN** the player enters a 3-character password and confirms
- **THEN** the client shows a validation message and sends nothing

#### Scenario: Long password

- **WHEN** the player enters a 40-character password
- **THEN** the field accepts it and the client sends it in full

### Requirement: Fixed connection target

The client SHALL connect to a single server endpoint fixed when the client is built. The endpoint
SHALL be expressible as either a hostname or a dotted-quad IPv4 address, and SHALL default to
`localhost`. The client SHALL NOT read the endpoint from any data file, configuration file, or
network response.

#### Scenario: Default build

- **WHEN** a client is built without overriding the endpoint and the player confirms login
- **THEN** the client resolves `localhost` and connects to it

#### Scenario: Hostname endpoint

- **WHEN** a client is built with a hostname endpoint and the player confirms login
- **THEN** the client resolves that hostname to an address and connects to it

#### Scenario: No data files present

- **WHEN** the client starts in a directory containing no `serverlist.bin`, `sn.bin` or `sn2.bin`
- **THEN** startup completes normally and login is available

#### Scenario: Stale data files present

- **WHEN** the client starts in a directory that still contains `serverlist.bin`, `sn.bin` and
  `sn2.bin` from a previous install
- **THEN** the files are ignored and have no effect on the endpoint or the screen

### Requirement: No client-side capacity limit

The client SHALL NOT refuse a login attempt on the basis of a reported user count, and SHALL NOT
display population figures, a busy indicator, or a "full" marker. Capacity is decided by the server.

#### Scenario: Server is at capacity

- **WHEN** the server is at or over its intended population and the player confirms login
- **THEN** the client sends the login request and surfaces whatever the server answers
- **AND** the client itself blocks nothing

### Requirement: Repeated attempts are rate limited

The client SHALL ignore a login confirmation that arrives within 1500 milliseconds of the previous
one, and SHALL disable the login button while a login request is outstanding.

#### Scenario: Rapid double click

- **WHEN** the player confirms login twice within 1500 milliseconds
- **THEN** exactly one login request is sent

### Requirement: Login rejection returns control to the player

On a rejected login the client SHALL display a message, re-enable the login button and the password
field, and remain on the login screen with the entered email preserved.

#### Scenario: Server rejects the credentials

- **WHEN** the server answers a login request with a rejection
- **THEN** a message is shown, the login button is usable again, and the email field still holds what
  the player typed

### Requirement: Disconnection on the login screen does not rebuild the screen

When the connection is lost or a malformed message arrives while the login screen is current, the
client SHALL display a message and stay on the login screen without tearing it down and recreating
it.

#### Scenario: Connection refused

- **WHEN** the server is unreachable and the player confirms login
- **THEN** a message is shown and the login screen remains, with its fields intact

### Requirement: No channel switching in game

The client SHALL NOT offer any in-game control for moving between channels or servers, and SHALL NOT
initiate a mid-session reconnection to a different endpoint.

#### Scenario: Player opens the in-game system menu

- **WHEN** the player opens the in-game system menu
- **THEN** no server or channel selection entry is present
