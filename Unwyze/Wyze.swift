//
//  Wyze.swift
//  Unwyze
//
//  Created by Saagar Jha on 4/11/26.
//

import CoreBluetooth
import Foundation

// MARK: - Types

enum Sex: UInt8 {
	case male = 0
	case female = 1
}

enum WeightUnit: UInt8 {
	case kg = 0
	case lb = 1
}

struct Measurement {
	let weight: Double  // kg
	let bodyFat: Double  // %
	let muscleMass: Double  // kg
	let boneMass: Double  // kg
	let bodyWater: Double  // %
	let protein: Double  // %
	let leanMass: Double  // kg
	let visceralFat: Int  // %
	let bmr: Int  // kcal
	let bodyAge: Int
	let bmi: Double
	let impedance: Double  // ohms
	let battery: Int  // %
}

struct UserProfile {
	let sex: Sex
	let age: UInt8
	let height: UInt8  // cm
	let athlete: Bool

	init(sex: Sex, age: UInt8, height: UInt8, athlete: Bool = false) {
		self.sex = sex
		self.age = age
		self.height = height
		self.athlete = athlete
	}
}

enum ScaleError: LocalizedError {
	case notFound
	case timeout
	case bluetoothUnavailable

	var errorDescription: String? {
		switch self {
			case .notFound: return "No scale found. Step on it to wake it."
			case .timeout: return "Measurement timed out."
			case .bluetoothUnavailable: return "Bluetooth is not available. Check permissions and settings."
		}
	}
}

// MARK: - Public API

enum MeasurementStatus {
	case scanning
	case connecting
	case settingUp
	case weighing(kg: Double, state: WeighState)
	case complete(Measurement)
}

enum WyzeScale {
	private static let serviceUUID = CBUUID(string: "FD7B")
	private static let characteristicUUID = CBUUID(string: "0001")

	static func measure(
		user: UserProfile,
		unit: WeightUnit = .kg
	) -> AsyncThrowingStream<MeasurementStatus, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					// 1. Find scale
					continuation.yield(.scanning)
					guard
						let peripheral = try await Peripheral.scan().first(where: {
							$0.name?.hasPrefix("WL_SC") == true
						})
					else {
						throw ScaleError.notFound
					}

					// 2. Connect and set up BLE channel
					continuation.yield(.connecting)
					let connected = try await peripheral.connect()
					defer { connected.disconnect() }

					let service = try await connected.services().first { $0.uuid == serviceUUID }
					guard let service else { throw ScaleError.notFound }
					let characteristic = try await connected.characteristics(of: service).first {
						$0.uuid == characteristicUUID
					}
					guard let characteristic else { throw ScaleError.notFound }
					let channel = try await connected.subscribe(to: characteristic)

					// 3. Establish encrypted protocol
					var proto = try await WyzeProtocol.establish(over: channel)

					// 4. Setup sequence
					continuation.yield(.settingUp)
					proto.send(SyncTime(payload: .init(date: .now)))
					proto.send(DeleteAllUsers())
					proto.send(UpdateUser(payload: .init(from: user)))
					proto.send(SetCurrentUser(payload: .init(from: user)))
					proto.send(SetUnit(payload: .init(unit: unit)))
					proto.send(SetHello(payload: .init(true)))
					proto.send(SetBroadcastTime(payload: .init(enabled: true)))

					// 5. Listen for weight data
					for await event in proto.messages {
						switch event {
							case .weighing(let kg, _, let state):
								if state == .stable {
									proto.send(AckWeight())
								}
								continuation.yield(.weighing(kg: kg, state: state))
							case .bodyComposition(let measurement):
								proto.send(DeleteAllUsers())
								continuation.yield(.complete(measurement))
								continuation.finish()
								return
						}
					}

					throw ScaleError.timeout
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}

// MARK: - Wire Encoding (binary encode/decode from field keypaths)

/// A type that can be read/written to a little-endian wire byte buffer.
private protocol WireValue {
	static var wireSize: Int { get }
	init?(fromWire bytes: [UInt8])
	func wireBytes() -> [UInt8]
}

/// All fixed-width integers get LE wire encoding for free.
extension WireValue where Self: FixedWidthInteger {
	static var wireSize: Int { MemoryLayout<Self>.size }

	init?(fromWire bytes: [UInt8]) {
		guard bytes.count >= Self.wireSize else { return nil }
		var raw: Self = 0
		for i in 0..<Self.wireSize { raw |= Self(bytes[i]) << (i * 8) }
		self = Self(littleEndian: raw)
	}

	func wireBytes() -> [UInt8] {
		let le = self.littleEndian
		return (0..<Self.wireSize).map { UInt8(truncatingIfNeeded: le >> ($0 * 8)) }
	}
}

extension UInt8: WireValue {}
extension UInt16: WireValue {}
extension UInt32: WireValue {}

extension InlineArray: WireValue where Element: WireValue {
	static var wireSize: Int {
		MemoryLayout<Self>.size / MemoryLayout<Element>.size * Element.wireSize
	}
	init?(fromWire bytes: [UInt8]) {
		guard bytes.count >= Self.wireSize else { return nil }
		self.init(repeating: Element(fromWire: [UInt8](repeating: 0, count: Element.wireSize))!)
		let count = Self.wireSize / Element.wireSize
		for i in 0..<count {
			self[i] = Element(
				fromWire: [UInt8](bytes[i * Element.wireSize..<(i + 1) * Element.wireSize]))!
		}
	}
	func wireBytes() -> [UInt8] {
		let count = Self.wireSize / Element.wireSize
		return (0..<count).flatMap { self[$0].wireBytes() }
	}
}

/// Visits struct fields for encoding or decoding. Each call to `field()` is fully typed.
private protocol FieldVisitor<Root> {
	associatedtype Root
	mutating func field<T: WireValue>(_ keyPath: WritableKeyPath<Root, T>)
}

/// A type that declares its wire layout once via the visitor pattern.
/// Both `decode` and `encode` are derived from the single `fields` definition.
private protocol WireCodable {
	init()
	static func fields<V: FieldVisitor<Self>>(_ visitor: inout V)
}

extension WireCodable {
	init?(from bytes: [UInt8]) {
		self.init()
		var decoder = Decoder(target: self, bytes: bytes)
		Self.fields(&decoder)
		guard !decoder.failed else { return nil }
		self = decoder.target
	}

	func encode() -> [UInt8] {
		var encoder = Encoder(source: self)
		Self.fields(&encoder)
		return encoder.bytes
	}
}

private struct Decoder<Root>: FieldVisitor {
	var target: Root
	let bytes: [UInt8]
	var offset = 0
	var failed = false

	mutating func field<T: WireValue>(_ keyPath: WritableKeyPath<Root, T>) {
		guard !failed else { return }
		guard let value = T(fromWire: [UInt8](bytes[offset...])) else {
			failed = true
			return
		}
		target[keyPath: keyPath] = value
		offset += T.wireSize
	}
}

private struct Encoder<Root>: FieldVisitor {
	let source: Root
	var bytes: [UInt8] = []

	mutating func field<T: WireValue>(_ keyPath: WritableKeyPath<Root, T>) {
		bytes.append(contentsOf: source[keyPath: keyPath].wireBytes())
	}
}

// MARK: - Wire Packets

/// CMD_CUR_WEIGHT_DATA (0xA808) response from scale during measurement.
private struct WeightData: WireCodable {
	var battery: UInt8 = 0
	var unit: UInt8 = 0
	var userId: InlineArray<16, UInt8> = .init(repeating: 0)
	var sex: UInt8 = 0
	var age: UInt8 = 0
	var height: UInt8 = 0
	var athleteMode: UInt8 = 0
	var onlyWeight: UInt8 = 0
	var measureState: UInt8 = 0
	var weightRaw: UInt16 = 0  // ×10 = grams
	var impedance: UInt16 = 0  // ÷10.0
	var bodyFat: UInt16 = 0  // ÷10.0 → %
	var muscleMass: UInt16 = 0  // ÷10.0 → kg
	var boneMass: UInt8 = 0  // ÷10.0 → kg
	var bodyWater: UInt16 = 0  // ÷10.0 → %
	var protein: UInt16 = 0  // ÷10.0 → %
	var leanMass: UInt16 = 0  // ÷10.0 → kg
	var visceralFat: UInt8 = 0
	var bmr: UInt16 = 0  // kcal
	var bodyAge: UInt8 = 0
	var bmi: UInt16 = 0  // ÷10.0

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.battery)
		v.field(\.unit)
		v.field(\.userId)
		v.field(\.sex)
		v.field(\.age)
		v.field(\.height)
		v.field(\.athleteMode)
		v.field(\.onlyWeight)
		v.field(\.measureState)
		v.field(\.weightRaw)
		v.field(\.impedance)
		v.field(\.bodyFat)
		v.field(\.muscleMass)
		v.field(\.boneMass)
		v.field(\.bodyWater)
		v.field(\.protein)
		v.field(\.leanMass)
		v.field(\.visceralFat)
		v.field(\.bmr)
		v.field(\.bodyAge)
		v.field(\.bmi)
	}

	var weightKg: Double { Double(weightRaw) * 10.0 / 1000.0 }
	var hasImpedance: Bool { impedance > 0 }

	var measurement: Measurement {
		Measurement(
			weight: weightKg,
			bodyFat: Double(bodyFat) / 10.0,
			muscleMass: Double(muscleMass) / 10.0,
			boneMass: Double(boneMass) / 10.0,
			bodyWater: Double(bodyWater) / 10.0,
			protein: Double(protein) / 10.0,
			leanMass: Double(leanMass) / 10.0,
			visceralFat: Int(visceralFat),
			bmr: Int(bmr),
			bodyAge: Int(bodyAge),
			bmi: Double(bmi) / 10.0,
			impedance: Double(impedance) / 10.0,
			battery: Int(battery)
		)
	}
}

// MARK: - Scale Commands

private protocol ScaleCommand {
	static var id: UInt16 { get }
	associatedtype Payload: WireCodable
	var payload: Payload { get }
}

private struct EmptyPayload: WireCodable {
	init() {}
	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {}
}

private struct SyncTime: ScaleCommand {
	static let id: UInt16 = 0xA801
	var payload: TimePayload
}

private struct DeleteAllUsers: ScaleCommand {
	static let id: UInt16 = 0xA80F
	var payload = EmptyPayload()
}

private struct UpdateUser: ScaleCommand {
	static let id: UInt16 = 0xA80A
	var payload: UserPayload
}

private struct SetCurrentUser: ScaleCommand {
	static let id: UInt16 = 0xA80E
	var payload: UserPayload
}

private struct SetUnit: ScaleCommand {
	static let id: UInt16 = 0xA804
	var payload: UnitPayload
}

private struct SetHello: ScaleCommand {
	static let id: UInt16 = 0xA805
	var payload: BoolPayload
}

private struct SetBroadcastTime: ScaleCommand {
	static let id: UInt16 = 0xA807
	var payload: BroadcastTimePayload
}

private struct AckWeight: ScaleCommand {
	static let id: UInt16 = 0xA808
	var payload = StatusPayload()  // 0x00 = success
}

// MARK: - Command Payloads

private struct TimePayload: WireCodable {
	var timestamp: UInt32 = 0
	var osType: UInt8 = 0x02  // iOS

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.timestamp)
		v.field(\.osType)
	}

	init() {}

	init(date: Date) {
		self.timestamp = UInt32(date.timeIntervalSince1970)
	}
}

private struct UserPayload: WireCodable {
	var userId: InlineArray<16, UInt8> = .init(repeating: 0)
	var weight: UInt16 = 0
	var sex: UInt8 = 0
	var age: UInt8 = 0
	var height: UInt8 = 0
	var athleteMode: UInt8 = 0
	var onlyWeight: UInt8 = 0
	var lastImp: UInt16 = 0

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.userId)
		v.field(\.weight)
		v.field(\.sex)
		v.field(\.age)
		v.field(\.height)
		v.field(\.athleteMode)
		v.field(\.onlyWeight)
		v.field(\.lastImp)
	}

	init() {}

	init(from profile: UserProfile) {
		self.sex = profile.sex.rawValue
		self.age = profile.age
		self.height = profile.height
		self.athleteMode = profile.athlete ? 1 : 0
	}
}

private struct UnitPayload: WireCodable {
	var unit: UInt8 = 0

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.unit)
	}

	init() {}

	init(unit: WeightUnit) {
		self.unit = unit.rawValue
	}
}

private struct BoolPayload: WireCodable {
	var value: UInt8 = 0

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.value)
	}

	init() {}

	init(_ value: Bool) {
		self.value = value ? 0x01 : 0x00
	}
}

private struct BroadcastTimePayload: WireCodable {
	var value: UInt16 = 0  // app sends 1 (power save on) or 0 (off)

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.value)
	}

	init() {}

	init(enabled: Bool) {
		self.value = enabled ? 1 : 0
	}
}

private struct StatusPayload: WireCodable {
	var status: UInt8 = 0  // 0 = success

	static func fields<V: FieldVisitor<Self>>(_ v: inout V) {
		v.field(\.status)
	}

	init() {}
}

enum WeighState {
	case stepping
	case measuring
	case stable
}

private enum ScaleEvent {
	case weighing(kg: Double, battery: Int, state: WeighState)
	case bodyComposition(Measurement)

	static func from(_ w: WeightData) -> ScaleEvent? {
		if w.measureState >= 2 && w.hasImpedance {
			return .bodyComposition(w.measurement)
		} else if w.weightKg > 0.5 {
			let state: WeighState =
				switch w.measureState {
					case 0: .stepping
					case 1: .measuring
					default: .stable
				}
			return .weighing(kg: w.weightKg, battery: Int(w.battery), state: state)
		}
		return nil
	}
}

// MARK: - WFAP Frame (Wyze Firmware Application Protocol)

/// 4-byte frame header used by the WFAP transport layer.
///
///     byte 0: [encrypt:1][reserved:3][messageId:4]
///     byte 1: command type (0xF0 = key exchange, 0x01 = data)
///     byte 2: [subcontracts:4][frameNumber:4]
///     byte 3: plaintext payload length
private enum WFAPFrame {
	static let keyExchange: UInt8 = 0xF0
	static let data: UInt8 = 0x01
	static let tlvTag: UInt16 = 0x0016  // TLV tag for scale command payloads

	static func build(
		messageId: UInt8,
		command: UInt8,
		encrypted: Bool,
		plaintextLength: Int,
		payload: [UInt8]
	) -> [UInt8] {
		var frame: [UInt8] = [
			(messageId & 0x0F) | (encrypted ? 0x10 : 0),
			command,
			0,  // single-fragment
			UInt8(plaintextLength),
		]
		frame.append(contentsOf: payload)
		return frame
	}
}

// MARK: - Wyze Protocol

private struct WyzeProtocol {
	let channel: Channel
	private var encryptionKey: [UInt8]
	private var messageId: UInt8 = 0

	static func establish(over channel: Channel) async throws -> WyzeProtocol {
		let privateKey = UInt32.random(in: 2..<DiffieHellman.prime - 2)
		let publicKey = DiffieHellman.powmod(
			base: DiffieHellman.generator, exp: privateKey, mod: DiffieHellman.prime)

		// Send our public key (little-endian) + 4 zero bytes
		let payload = publicKey.wireBytes() + [0, 0, 0, 0]
		let frame = WFAPFrame.build(
			messageId: 0,
			command: WFAPFrame.keyExchange,
			encrypted: false,
			plaintextLength: 8,
			payload: payload
		)
		channel.write(frame)

		// Receive the scale's public key
		var iterator = channel.received.makeAsyncIterator()
		guard let response = await iterator.next(),
			response.count >= 4,
			let remotePublicKey = UInt32(fromWire: [UInt8](response[4...]))
		else {
			throw ScaleError.notFound
		}
		let sharedSecret = DiffieHellman.powmod(
			base: remotePublicKey, exp: privateKey, mod: DiffieHellman.prime)

		let encryptionKey = [UInt8](String(format: "%x", sharedSecret).utf8)
		return WyzeProtocol(channel: channel, encryptionKey: encryptionKey)
	}

	mutating func send<C: ScaleCommand>(_ command: C) {
		let commandId = C.id
		let payload = command.payload.encode()

		// Build command: [cmd_lo, cmd_hi, payload...]
		var commandData = commandId.wireBytes()
		commandData.append(contentsOf: payload)

		// Wrap in TLV: [tag_lo, tag_hi, len_lo, len_hi, data...]
		var tlv = WFAPFrame.tlvTag.wireBytes() + UInt16(commandData.count).wireBytes()
		tlv.append(contentsOf: commandData)

		let encrypted = XXTEA.encrypt(tlv, key: encryptionKey)
		messageId = (messageId &+ 1) & 0x0F

		let frame = WFAPFrame.build(
			messageId: messageId,
			command: WFAPFrame.data,
			encrypted: true,
			plaintextLength: tlv.count,
			payload: encrypted
		)
		channel.write(frame)
	}

	var messages: AsyncStream<ScaleEvent> {
		AsyncStream { continuation in
			Task {
				for await raw in channel.received {
					guard raw.count >= 8 else { continue }

					let isEncrypted = (raw[0] & 0x10) != 0
					let payload = [UInt8](raw[4...])
					let decrypted =
						isEncrypted ? XXTEA.decrypt(payload, key: encryptionKey) : payload

					guard let (commandId, data) = parseTLV(decrypted),
						commandId == 0xA808,
						let w = WeightData(from: data)
					else { continue }

					if let event = ScaleEvent.from(w) {
						continuation.yield(event)
					}
				}
				continuation.finish()
			}
		}
	}

	private func parseTLV(_ bytes: [UInt8]) -> (command: UInt16, data: [UInt8])? {
		guard bytes.count >= 4,
			UInt16(fromWire: [UInt8](bytes[0...])) != nil,  // tag
			let lengthRaw = UInt16(fromWire: [UInt8](bytes[2...]))
		else { return nil }
		let length = Int(lengthRaw)
		guard length >= 2, bytes.count >= 4 + length,
			let commandId = UInt16(fromWire: [UInt8](bytes[4...]))
		else { return nil }
		let valueData = length > 2 ? [UInt8](bytes[6..<4 + length]) : []
		return (commandId, valueData)
	}
}

// MARK: - Diffie-Hellman (32-bit)

private enum DiffieHellman {
	static let prime: UInt32 = 0xFFFF_FFC5  // 2^32 - 59
	static let generator: UInt32 = 5

	/// Modular exponentiation via square-and-multiply. Uses 64-bit intermediates to avoid overflow.
	static func powmod(base: UInt32, exp: UInt32, mod: UInt32) -> UInt32 {
		var result: UInt64 = 1
		var base = UInt64(base) % UInt64(mod)
		var exp = exp
		while exp > 0 {
			if exp & 1 == 1 {
				result = result &* base % UInt64(mod)
			}
			exp >>= 1
			base = base &* base % UInt64(mod)
		}
		return UInt32(result)
	}
}

// MARK: - XXTEA (2-word ECB, 32 rounds)

/// XXTEA block cipher operating on 2 x UInt32 words (8 bytes) with a 128-bit key.
/// Each 8-byte block is encrypted independently (ECB mode).
/// Matches the WYZE_F_xxtea_encrypt/decrypt functions in libwyze_wfap-lib.so.
private enum XXTEA {
	static let delta: UInt32 = 0x9E37_79B9
	static let rounds = 32  // 52/n + 6 where n=2

	static func encrypt(_ bytes: [UInt8], key: [UInt8]) -> [UInt8] {
		var bytes = padToBlockSize(bytes)
		let keyWords = expandKey(key)
		for offset in stride(from: 0, to: bytes.count, by: 8) {
			processBlock(&bytes, at: offset, key: keyWords, encrypt: true)
		}
		return bytes
	}

	static func decrypt(_ bytes: [UInt8], key: [UInt8]) -> [UInt8] {
		var bytes = padToBlockSize(bytes)
		let keyWords = expandKey(key)
		for offset in stride(from: 0, to: bytes.count, by: 8) {
			processBlock(&bytes, at: offset, key: keyWords, encrypt: false)
		}
		return bytes
	}

	// MARK: - Block Processing

	private static func processBlock(
		_ bytes: inout [UInt8], at offset: Int, key: [UInt32], encrypt: Bool
	) {
		let slice0: [UInt8] = .init(bytes[offset..<offset + 4])
		let slice1: [UInt8] = .init(bytes[offset + 4..<offset + 8])
		var v0 = UInt32(fromWire: slice0)!
		var v1 = UInt32(fromWire: slice1)!

		if encrypt {
			var sum: UInt32 = 0
			var z = v1
			for _ in 0..<rounds {
				sum = sum &+ delta
				let e = (sum >> 2) & 3
				v0 = v0 &+ mix(sum: sum, y: v1, z: z, p: 0, e: e, key: key)
				z = v0
				v1 = v1 &+ mix(sum: sum, y: v0, z: z, p: 1, e: e, key: key)
				z = v1
			}
		} else {
			var sum = UInt32(rounds) &* delta
			var y = v0
			for _ in 0..<rounds {
				let e = (sum >> 2) & 3
				v1 = v1 &- mix(sum: sum, y: y, z: v0, p: 1, e: e, key: key)
				y = v1
				v0 = v0 &- mix(sum: sum, y: y, z: v1, p: 0, e: e, key: key)
				y = v0
				sum = sum &- delta
			}
		}

		bytes.replaceSubrange(offset..<offset + 4, with: v0.wireBytes())
		bytes.replaceSubrange(offset + 4..<offset + 8, with: v1.wireBytes())
	}

	private static func mix(sum: UInt32, y: UInt32, z: UInt32, p: Int, e: UInt32, key: [UInt32])
		-> UInt32
	{
		((z >> 5 ^ y << 2) &+ (y >> 3 ^ z << 4)) ^ ((sum ^ y) &+ (key[Int(UInt32(p) & 3 ^ e)] ^ z))
	}

	// MARK: - Key and Padding

	/// Expand key bytes to 4 x UInt32 words. The key is a null-terminated ASCII string (from the DH shared secret).
	private static func expandKey(_ key: [UInt8]) -> [UInt32] {
		var padded = [UInt8](repeating: 0, count: 16)
		for i in 0..<min(key.count, 16) {
			guard key[i] != 0 else { break }
			padded[i] = key[i]
		}
		return (0..<4).map { i -> UInt32 in
			let slice: [UInt8] = .init(padded[i * 4..<i * 4 + 4])
			return UInt32(fromWire: slice)!
		}
	}

	private static func padToBlockSize(_ bytes: [UInt8]) -> [UInt8] {
		let remainder = bytes.count % 8
		guard remainder != 0 else { return bytes }
		return bytes + [UInt8](repeating: 0, count: 8 - remainder)
	}

}

// MARK: - Bluetooth

private struct Peripheral {
	let name: String?
	fileprivate let cbPeripheral: CBPeripheral
	fileprivate let central: CentralDelegate

	static func scan() -> AsyncThrowingStream<Peripheral, Error> {
		let central = CentralDelegate()
		return AsyncThrowingStream { continuation in
			continuation.onTermination = { @Sendable _ in
				central.centralManager.stopScan()
			}
			Task {
				do {
					try await central.waitForPoweredOn()
					central.scanContinuation = continuation
					central.centralManager.scanForPeripherals(withServices: nil)
				} catch {
					continuation.finish(throwing: error)
				}
			}
		}
	}

	func connect() async throws -> ConnectedPeripheral {
		try await withCheckedThrowingContinuation { cont in
			central.connectContinuation = cont
			central.centralManager.connect(cbPeripheral)
		}
		return ConnectedPeripheral(cbPeripheral: cbPeripheral, central: central)
	}
}

private class ConnectedPeripheral {
	private let cbPeripheral: CBPeripheral
	private let central: CentralDelegate
	private let delegate = PeripheralDelegate()

	fileprivate init(cbPeripheral: CBPeripheral, central: CentralDelegate) {
		self.cbPeripheral = cbPeripheral
		self.central = central
		cbPeripheral.delegate = delegate
	}

	func services() async throws -> [CBService] {
		try await withCheckedThrowingContinuation { cont in
			delegate.discoverContinuation = cont
			cbPeripheral.discoverServices(nil)
		}
		return cbPeripheral.services!
	}

	func characteristics(of service: CBService) async throws -> [CBCharacteristic] {
		try await withCheckedThrowingContinuation { cont in
			delegate.discoverContinuation = cont
			cbPeripheral.discoverCharacteristics(nil, for: service)
		}
		return service.characteristics!
	}

	func subscribe(to characteristic: CBCharacteristic) async throws -> Channel {
		let (stream, streamContinuation) = AsyncStream.makeStream(of: [UInt8].self)
		delegate.receiveContinuation = streamContinuation
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			delegate.notifyContinuation = cont
			cbPeripheral.setNotifyValue(true, for: characteristic)
		}
		return Channel(cbPeripheral: cbPeripheral, characteristic: characteristic, received: stream)
	}

	func disconnect() {
		central.centralManager.cancelPeripheralConnection(cbPeripheral)
	}
}

private struct Channel {
	fileprivate let cbPeripheral: CBPeripheral
	fileprivate let characteristic: CBCharacteristic
	let received: AsyncStream<[UInt8]>

	func write(_ bytes: [UInt8]) {
		cbPeripheral.writeValue(Data(bytes), for: characteristic, type: .withoutResponse)
	}
}

private class CentralDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
	nonisolated(unsafe) var centralManager: CBCentralManager!
	var readyContinuation: CheckedContinuation<Void, Error>?
	var scanContinuation: AsyncThrowingStream<Peripheral, Error>.Continuation?
	var connectContinuation: CheckedContinuation<Void, Error>?

	override init() {
		super.init()
		centralManager = CBCentralManager(delegate: self, queue: DispatchQueue(label: "ble"))
	}

	func waitForPoweredOn() async throws {
		if centralManager.state == .poweredOn { return }
		try await withCheckedThrowingContinuation { readyContinuation = $0 }
	}

	func centralManagerDidUpdateState(_ central: CBCentralManager) {
		switch central.state {
			case .poweredOn:
				readyContinuation?.resume()
			case .unauthorized, .unsupported, .poweredOff:
				readyContinuation?.resume(throwing: ScaleError.bluetoothUnavailable)
			default:
				return
		}
		readyContinuation = nil
	}

	func centralManager(
		_ central: CBCentralManager,
		didDiscover peripheral: CBPeripheral,
		advertisementData: [String: Any],
		rssi: NSNumber
	) {
		let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
		scanContinuation?.yield(Peripheral(name: name, cbPeripheral: peripheral, central: self))
	}

	func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		connectContinuation!.resume()
		connectContinuation = nil
	}

	func centralManager(
		_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
	) {
		connectContinuation!.resume(throwing: error!)
		connectContinuation = nil
	}

	func centralManager(
		_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
	) {}
}

private class PeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
	var discoverContinuation: CheckedContinuation<Void, Error>?
	var notifyContinuation: CheckedContinuation<Void, Error>?
	var receiveContinuation: AsyncStream<[UInt8]>.Continuation?

	func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
		if let error {
			discoverContinuation!.resume(throwing: error)
		} else {
			discoverContinuation!.resume()
		}
		discoverContinuation = nil
	}

	func peripheral(
		_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
	) {
		if let error {
			discoverContinuation!.resume(throwing: error)
		} else {
			discoverContinuation!.resume()
		}
		discoverContinuation = nil
	}

	func peripheral(
		_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
		error: Error?
	) {
		if let error {
			notifyContinuation!.resume(throwing: error)
		} else {
			notifyContinuation!.resume()
		}
		notifyContinuation = nil
	}

	func peripheral(
		_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
		error: Error?
	) {
		guard let data = characteristic.value else { return }
		receiveContinuation?.yield([UInt8](data))
	}
}
