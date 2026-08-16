## Purpose

The wire contract for authenticating a game session: how a login connection opens, the exact byte
layout of the login request and its accept and reject responses, and the version gate that lets a
server tell client builds apart. This is the capability the Rust server implements against.

## ADDED Requirements

### Requirement: Login connection handshake

The client SHALL open a TCP connection to the configured endpoint on port 8281 and, immediately on
connect, send the 4-byte init code `11 F3 11 1F`. The server SHALL NOT send an init code in reply;
the next bytes the client expects are a normal message header.

#### Scenario: Client connects

- **WHEN** the client connects to the server on port 8281
- **THEN** the first 4 bytes the server receives are `11 F3 11 1F`
- **AND** the client treats the connection as ready without waiting for a reply

#### Scenario: Server echoes the init code

- **WHEN** the server sends the init code back to the client
- **THEN** the client parses those 4 bytes as the start of a message header and the connection fails

### Requirement: Endpoint address may be a hostname

The client SHALL resolve its configured endpoint through DNS when it is not a dotted-quad IPv4
literal, and SHALL connect to the first usable IPv4 address returned.

#### Scenario: Hostname endpoint

- **WHEN** the endpoint is `localhost`
- **THEN** the client resolves it and connects to the resulting address on port 8281

#### Scenario: Literal address endpoint

- **WHEN** the endpoint is `10.0.0.5`
- **THEN** the client connects to that address on port 8281 without a DNS lookup

#### Scenario: Unresolvable endpoint

- **WHEN** the endpoint cannot be resolved
- **THEN** the client reports a connection failure and stays on the login screen

### Requirement: Login request layout

The client SHALL send the login request as opcode `0x20D` with a total size of 164 bytes, laid out
as follows. All integers are little-endian. Character arrays are NUL-padded to their full width, and
unused bytes SHALL be zero.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 12 | standard message header, `Type` = `0x20D`, `ID` = 0 |
| 12 | 64 | password, plain characters |
| 76 | 64 | email address, plain characters |
| 140 | 4 | protocol version |
| 144 | 4 | force flag, always 1 |
| 148 | 16 | machine fingerprint, 4 little-endian 32-bit words |

The request SHALL NOT carry a channel or server identifier, and SHALL NOT carry a handoff token.

#### Scenario: Player logs in

- **WHEN** the player confirms login with email `player@example.com` and password `hunter22`
- **THEN** the server receives a 164-byte `0x20D` message
- **AND** bytes 76..139 hold `player@example.com` followed by NUL padding
- **AND** bytes 12..75 hold `hunter22` followed by NUL padding

#### Scenario: Machine fingerprint unavailable

- **WHEN** the client cannot read a network adapter identifier
- **THEN** the fingerprint field is 16 zero bytes and the request is still sent

### Requirement: Protocol version gate

The client SHALL send protocol version 1759 in every login request. A server MAY reject any request
whose version it does not recognise, and SHALL treat 1758 as a client built before email login.

#### Scenario: Current client

- **WHEN** a client built after this change sends a login request
- **THEN** the version field reads 1759

#### Scenario: Server rejects an old client

- **WHEN** a server receives a login request with version 1758
- **THEN** it may answer with a rejection rather than attempting to parse the body

### Requirement: Login accepted response

The server SHALL answer an accepted login with opcode `0x10A` at a total size of 1976 bytes, laid
out as follows. Padding bytes exist because the character block is 8-byte aligned; they SHALL be
present and SHALL be zero.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 12 | standard message header, `Type` = `0x10A` |
| 12 | 16 | secret code |
| 28 | 4 | padding |
| 32 | 840 | selected-character block |
| 872 | 1024 | cargo, 128 entries of 8 bytes |
| 1896 | 4 | coin |
| 1900 | 64 | email address |
| 1964 | 4 | SSN1 |
| 1968 | 4 | SSN2 |
| 1972 | 4 | tail padding |

On receiving it the client SHALL set its clock from the header timestamp, retain the secret code,
character block and cargo, and advance to character selection.

#### Scenario: Login accepted

- **WHEN** the server answers a valid login with a 1976-byte `0x10A` message
- **THEN** the client advances to the character selection screen

#### Scenario: Wrong size

- **WHEN** the server answers with an `0x10A` message whose declared size does not match its content
- **THEN** the client's framing check fails and the connection is dropped

### Requirement: Opcode 0x10A has exactly one meaning

Opcode `0x10A` SHALL be interpreted as the login accepted response in every scene. No alternative
body layout for that opcode exists.

#### Scenario: Server sends 0x10A mid-session

- **WHEN** the server sends `0x10A` after the player is in the field
- **THEN** it is parsed with the login accepted layout, not any other

### Requirement: Login rejected responses

The server SHALL reject a login with opcode `0x11C` or `0x11D`. The client SHALL treat both
identically: show a rejection message, re-enable the login controls, and stay on the login screen.

#### Scenario: Unknown email

- **WHEN** the email is not registered and the server answers `0x11C`
- **THEN** the client shows a rejection message and the player can try again

#### Scenario: Wrong password

- **WHEN** the password does not match and the server answers `0x11D`
- **THEN** the client shows a rejection message and the player can try again

### Requirement: No channel handoff protocol

There SHALL be no protocol for moving a session between channels or servers. The client SHALL NOT
send a whisper addressed to `srv`, SHALL NOT act on opcode `0x52A`, and SHALL NOT open a second
connection carrying a handoff token.

#### Scenario: Server sends a handoff

- **WHEN** the server sends opcode `0x52A`
- **THEN** the client ignores it and the session is unaffected
