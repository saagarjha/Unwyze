# Wyze Scale S (WL_SC2) — BLE Protocol Documentation

Reverse-engineered from the Wyze app v3.6.6.683 (`com.hualai`) APK via static analysis. Verified against a live WL_SC2 scale with firmware 1.0.108.

## Overview

The Wyze Scale S (model WL_SC2) communicates over Bluetooth Low Energy using a proprietary protocol called WFAP (Wyze Firmware Application Protocol). The scale measures weight and body composition (bioelectrical impedance analysis) and streams results to a connected device. No Wyze cloud account or internet connection is required.

### Hardware

- **Model**: WL_SC2 (also sold as "Wyze Scale S")
- **BLE name**: `WL_SC2`
- **Firmware**: 1.0.108 (as tested)
- **Manufacturer**: WYZE (shown in GATT Device Information Service)
- **Power**: 3x AAA batteries
- **No WiFi**, no heart rate sensor (those are Scale Ultra / WL_SCU features)

### What it measures

Weight plus 12 body composition metrics: body fat %, muscle mass, bone mass, body water %, protein %, lean body mass, visceral fat level, BMR, metabolic age, BMI, and raw impedance. All computed on-device from the impedance reading and the user profile (sex, age, height, athlete mode).

## BLE Service Layout

| Service | UUID | Purpose |
|---|---|---|
| Device Information | `180A` | Standard GATT: model, serial, firmware, hardware, manufacturer |
| **WFAP** | **`FD7B`** | Scale communication (single characteristic) |
| DFU | `00001530-1212-EFDE-1523-785FEABCD123` | Firmware update bootloader |

### FD7B Service

Single characteristic `0001` with properties **WriteWithoutResponse** + **Indicate**. Both TX (app to scale) and RX (scale to app) use this one characteristic. The app writes commands, the scale sends responses as indications.

## Protocol Stack

```
Application     Scale commands (CMD_TIME, CMD_CUR_WEIGHT_DATA, etc.)
    |
TLV             Tag 0x0016, little-endian tag + length prefix
    |
XXTEA-ECB       2-word (8-byte) blocks, 32 rounds, key from DH
    |
WFAP Frame      4-byte header: [msgId|encrypt, cmdType, frag, payloadLen]
    |
BLE             Write/Indicate on characteristic 0001 in service FD7B
```

## WFAP Frame Format

Every BLE write/indication is a WFAP frame:

```
Byte 0: [bit 7-5: reserved] [bit 4: encrypted] [bit 3-0: message ID]
Byte 1: command type (0xF0 = DH key exchange, 0x01 = encrypted data)
Byte 2: [bit 7-4: subcontracts] [bit 3-0: frame number] (fragmentation, usually 0)
Byte 3: plaintext payload length (NOT encrypted length)
Byte 4+: payload (encrypted if bit 4 of byte 0 is set)
```

The message ID is a 4-bit counter (0-15) incremented per message. The scale's responses have bit 6 of byte 0 set (reserved, ignored by the protocol).

The payload length in byte 3 is the **plaintext** length, even when the actual payload is encrypted (and thus padded to 8-byte blocks). The receiver uses this to know the original data size after decryption.

## Encryption

### Diffie-Hellman Key Exchange

The session begins with a plaintext DH key exchange using CMD type `0xF0`:

- **Prime**: `0xFFFFFFC5` (2^32 - 59)
- **Generator**: 5
- **Key size**: 32 bits

No cloud or pre-shared keys are needed — the scale accepts the DH exchange from any connecting device.

**Flow:**

```
App → Scale:  [0xF0 frame] public key A (4 bytes LE) + 4 zero bytes
Scale → App:  [0xF0 frame] public key B (4 bytes LE) + 4 zero bytes

Both sides compute: shared_secret = other_pub ^ own_priv mod prime
```

Public keys are encoded as **little-endian** uint32.

### XXTEA Key Derivation

The XXTEA encryption key is the shared secret formatted as a **lowercase hex string** using C-style `sprintf("%x", shared_secret)`:

- Shared secret `0x7da75f0a` → key bytes `"7da75f0a"` (8 ASCII bytes)
- Shared secret `0x3b138f6` → key bytes `"3b138f6"` (7 ASCII bytes, no leading zero)

The key string is null-padded to 16 bytes and split into 4 little-endian uint32 words for XXTEA.

**Important**: `%x` does NOT zero-pad. Shared secrets with leading zero nibbles produce shorter key strings.

### XXTEA-ECB

After the DH exchange, all data payloads are encrypted with XXTEA in ECB mode:

- Block size: 8 bytes (2 x uint32 words)
- Rounds: 32 (from the formula 52/n + 6 where n=2)
- Mode: ECB (each 8-byte block encrypted independently)
- Padding: zero-padded to 8-byte boundary
- Delta constant: `0x9E3779B9`

The XXTEA implementation matches `WYZE_F_xxtea_encrypt` / `WYZE_F_xxtea_decrypt` in `libwyze_wfap-lib.so` from the APK. The native library was decompiled using Ghidra.

## TLV Wrapping

Encrypted payloads contain TLV (Tag-Length-Value) encoded data:

```
Byte 0-1: tag (uint16 LE) — always 0x0016 for scale commands
Byte 2-3: length (uint16 LE) — length of the value (command data)
Byte 4+:  value (command ID + command-specific payload)
```

Response TLV uses tag `0x0122`.

## Command Protocol

All command payloads start with a 2-byte command ID (uint16 LE), followed by command-specific data. Multi-byte integers are **little-endian** throughout.

### Setup Sequence

The Wyze app performs this sequence after BLE connection + DH:

1. `CMD_TIME` (0xA801) — sync clock
2. `CMD_USER_LIST_NEW` (0xA80D) — get users on scale (firmware > 1.0.67)
3. `CMD_UPDATE_USER` (0xA80A) — create/update user profile on scale
4. `CMD_CURRENT_USER_NEW` (0xA80E) — set active user for measurement
5. `CMD_SET_UNIT` (0xA804) — set display unit (kg/lb)
6. `CMD_SET_HELLO` (0xA805) — enable/disable greeting display
7. `CMD_BROAD_TIME` (0xA807) — power saver mode

Each command waits for its response before sending the next (the app is sequential). Commands can also be sent in rapid succession — the scale processes them in order.

### Command Reference

#### CMD_TIME (0xA801) — Sync Time

**Direction**: App → Scale

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 4 | timestamp | Unix epoch seconds (uint32 LE) |
| 4 | 1 | osType | 1 = Android, 2 = iOS |

**Response**: 1 byte status (0 = success).

The scale may not use the timestamp for anything meaningful on the WL_SC2 (no history storage). It's part of the expected setup handshake.

#### CMD_USER_LIST_NEW (0xA80D) — Get User List

**Direction**: App → Scale (request, no payload) / Scale → App (response)

For firmware > 1.0.67, the app sends 0xA80D instead of 0xA802.

**Response**:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | user count |
| Per user (25 bytes each): |
| +0 | 16 | userId |
| +16 | 2 | weight (uint16 LE, kg × 100) |
| +18 | 1 | sex (0=male, 1=female) |
| +19 | 1 | age |
| +20 | 1 | height (cm) |
| +21 | 1 | athleteMode |
| +22 | 1 | onlyWeight |
| +23 | 2 | lastImpedance (uint16 LE) |

The weight and impedance values are updated by the scale from actual measurements. They are not just echoes of what was sent via CMD_UPDATE_USER.

#### CMD_UPDATE_USER (0xA80A) — Create/Update User

**Direction**: App → Scale

New format (firmware > 1.0.67) appends `lastImp` field:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 16 | userId |
| 16 | 2 | weight (uint16 LE, kg × 100) |
| 18 | 1 | sex |
| 19 | 1 | age |
| 20 | 1 | height (cm) |
| 21 | 1 | athleteMode |
| 22 | 1 | onlyWeight (0 = full body comp, 1 = weight only) |
| 23 | 2 | lastImpedance (uint16 LE) |

**Response**: 1 byte status.

The sex, age, height, and athleteMode fields are used by the scale's BIA formulas to compute body composition from impedance. The weight field is an estimate for user auto-matching; the scale overwrites it with the actual measured weight. Setting lastImpedance to 0 is fine.

#### CMD_CURRENT_USER_NEW (0xA80E) — Set Active User

**Direction**: App → Scale

Same payload as CMD_UPDATE_USER. For firmware > 1.0.67, the app sends 0xA80E instead of 0xA803.

**Response**: 1 byte status.

This tells the scale who is about to step on. The scale uses this profile for body composition calculations and user matching.

#### CMD_SET_UNIT (0xA804) — Set Display Unit

**Direction**: App → Scale

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | unit (0 = kg, 1 = lb) |

**Response**: 1 byte status.

Only affects the scale's LED display. Wire data is always in the same raw format regardless of unit.

#### CMD_SET_HELLO (0xA805) — Set Greeting Display

**Direction**: App → Scale

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | show (0 = off, 1 = on) |

**Response**: 1 byte status.

Controls whether the scale shows a brief greeting animation when stepped on.

#### CMD_BROAD_TIME (0xA807) — Power Saver Mode

**Direction**: App → Scale

| Offset | Size | Field |
|--------|------|-------|
| 0 | 2 | enabled (uint16 LE, 1 = on, 0 = off) |

**Response**: 1 byte status.

The app sends 1 (power save on) or 0 (off). Despite the name suggesting a time duration, the app code passes a boolean.

#### CMD_CUR_WEIGHT_DATA (0xA808) — Weight + Body Composition

**Direction**: Scale → App (streamed during measurement)

| Offset | Size | Field | Encoding |
|--------|------|-------|----------|
| 0 | 1 | battery | 0-100% |
| 1 | 1 | unit | 0=kg display, 1=lb display |
| 2 | 16 | userId | Matched user |
| 18 | 1 | sex | From user profile |
| 19 | 1 | age | From user profile |
| 20 | 1 | height | cm, from user profile |
| 21 | 1 | athleteMode | From user profile |
| 22 | 1 | onlyWeight | From user profile |
| 23 | 1 | measureState | 0=stepping, 1=measuring, 2=stable |
| 24 | 2 | weightRaw | uint16 LE. Multiply by 10 for grams, divide by 1000 for kg |
| 26 | 2 | impedance | uint16 LE, divide by 10.0 |
| 28 | 2 | bodyFat | uint16 LE, divide by 10.0 → % |
| 30 | 2 | muscleMass | uint16 LE, divide by 10.0 → kg |
| 32 | 1 | boneMass | uint8, divide by 10.0 → kg |
| 33 | 2 | bodyWater | uint16 LE, divide by 10.0 → % |
| 35 | 2 | protein | uint16 LE, divide by 10.0 → % |
| 37 | 2 | leanMass | uint16 LE, divide by 10.0 → kg |
| 39 | 1 | visceralFat | uint8 |
| 40 | 2 | bmr | uint16 LE, kcal |
| 42 | 1 | bodyAge | uint8, years |
| 43 | 2 | bmi | uint16 LE, divide by 10.0 |

**Total: 45 bytes.**

The scale streams this continuously while someone is standing on it. During stepping/measuring (states 0-1), the body composition fields are zero. At state 2 (stable), if impedance is enabled (`onlyWeight=0`), all body composition fields are populated in the same message.

On the WL_SC2, the scale goes silent on BLE immediately after sending state 2 with body composition. It does not send a separate state 3 message.

**ACK**: The app sends `[0xA808, 0x00]` back to the scale when `measureState >= 2` and impedance is zero (weight-only stable). This acknowledgment is needed for the protocol flow. When impedance data is present, no ACK is sent — the measurement is complete.

#### CMD_DEL_USER (0xA80B) — Delete User

**Direction**: App → Scale

| Offset | Size | Field |
|--------|------|-------|
| 0 | 16 | userId |

**Response**: 1 byte status.

#### CMD_DEL_ALL_USER (0xA80F) — Delete All Users

**Direction**: App → Scale. No payload.

**Response**: 1 byte status.

#### CMD_DEV_BIND_STATE (0xA80C) — Query Bind State

**Direction**: App → Scale (no payload) / Scale → App

**Response**:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | status |
| 1 | 1 | color (device color variant) |

### Commands Not Supported by WL_SC2

These commands exist in the protocol but the WL_SC2 hardware does not respond to them:

| Command | ID | Reason |
|---|---|---|
| CMD_HEART_MODE | 0xA810 | No heart rate sensor (Scale Ultra only) |
| CMD_HEART_RESULT | 0xA811 | No heart rate sensor |
| CMD_WEIGHT_MODE | 0xA812 | No heart rate to return from |
| CMD_WIFI_SCAN | 0xA813 | No WiFi radio |
| CMD_WIFI_LIST | 0xA814 | No WiFi radio |
| CMD_WIFI_SEND | 0xA815 | No WiFi radio |
| CMD_WIFI_STATE | 0xA816 | No WiFi radio |
| CMD_DEVICE_INFO | 0xA81B | No response from WL_SC2 firmware |
| CMD_GET_LOG | 0xA81D | No response from WL_SC2 firmware |
| CMD_DEVICE_UI_ITEM | 0xA817 | Code-gated to WL_SCU |
| CMD_DEVICE_OTA_START | 0xA820 | Scale Ultra only |

### Commands Not Tested

| Command | ID | Reason |
|---|---|---|
| CMD_RESET | 0xA806 | Factory reset — destructive |
| CMD_HISTORY_WEIGHT_DATA | 0xA809 | Sent but never returned data; WL_SC2 may not store history |
| CMD_BROAD_POWER_OFF | 0xA81C | Not tested |

## Reverse Engineering Notes

### Sources

The protocol was reverse-engineered from the Wyze Android app v3.6.6.683 (`com.hualai`). The app-layer protocol is implemented in Java (`com.wyze.pluto.utils.dataparse.ICWyzeProtocol`). The WFAP encryption layer is in a native ARM64 library (`libwyze_wfap-lib.so`, 247KB), decompiled with Ghidra.

The WL_SC2 uses the "Pluto" plugin in the Wyze app, which is separate from the older Jiuan/iHealth-based "HS2S" plugin used by the JA.SC / JA.SC2 models. Those older models use a completely different BLE service, transport framing, and cloud-assisted key exchange.

### What the Scale Stores

The scale maintains up to 8 user slots. Each slot stores the user profile (sex, age, height, athlete mode) plus the last measured weight and impedance. These values are updated on each measurement. The scale uses stored weights for auto-matching users when no app is connected.

The scale does not appear to maintain a measurement history log on the WL_SC2. The `CMD_HISTORY_WEIGHT_DATA` (0xA809) command never returned data in any test. The Wyze app builds its measurement history by capturing each live measurement over BLE and uploading it to the cloud.

### App-Side Features

The Wyze app provides several features that are purely app-side (no BLE commands):

- **Heart rate via phone camera** — uses the ICCameraHr SDK, not the scale
- **Baby/pet/luggage mode** — differential weighing (weigh yourself, then weigh yourself holding the item, subtract)
- **Trend charts and history** — stored in the Wyze cloud
- **Goal setting** — app-side
- **Data export** — server-generated email
- **Third-party sync** — Google Fit, Fitbit, Apple Health

### Protocol Differences by Model

The Pluto plugin supports multiple scale models:

| Model | PID | WiFi | Heart Rate | UI Customization |
|---|---|---|---|---|
| WL_SC2 (Scale S) | 1 | No | No | No |
| WL_SC3 | 2 | ? | ? | ? |
| WL_SCU (Scale Ultra) | 3 | Yes | Yes | Yes (CMD_DEVICE_UI_ITEM) |
| WL_SC4 | 4 | ? | ? | ? |

The SCU uses additional commands: `CMD_DEVICE_USER_LIST_SCU` (0xA818), `CMD_CURRENT_USER_SUC` (0xA819), `CMD_UPDATE_USER_NEW` (0xA81A), with extended payloads including goals, nicknames, and icons.

### Firmware Version Branching

The app checks the firmware version string to choose between old and new command formats:

```java
z10 = ICCommon.versionBigger(firmwareVersion, "1.0.67");
```

When `true` (firmware > 1.0.67, which includes 1.0.108):
- User list uses `CMD_USER_LIST_NEW` (0xA80D) instead of `CMD_USER_LIST` (0xA802)
- Current user uses `CMD_CURRENT_USER_NEW` (0xA80E) instead of `CMD_CURRENT_USER` (0xA803)
- Update user includes the `lastImp` field (2 extra bytes)
