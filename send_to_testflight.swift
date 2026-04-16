#!/usr/bin/env swift
import CryptoKit
import Foundation

struct API {
	struct _API {
		let header: String
		let issuerID: String
		let privateKey: P256.Signing.PrivateKey

		init(key: Data, keyID: String, issuerID: String) throws {
			header = try JSONEncoder().encode([
				"alg": "ES256",
				"kid": keyID,
				"typ": "JWT",
			]).base64EncodedString().filter {
				$0 != "="
			}

			self.issuerID = issuerID

			let pem = String(data: key, encoding: .utf8)!
			privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
		}

		func generateJWT() throws -> String {
			let payload = try JSONSerialization.data(
				withJSONObject: [
					"iss": issuerID,
					"iat": Date.now.timeIntervalSince1970,
					"exp": Date.now.addingTimeInterval(2 * 60).timeIntervalSince1970,
					"aud": "appstoreconnect-v1",
				] as [String: Any]
			).base64EncodedString().filter {
				$0 != "="
			}

			let signature = try privateKey.signature(for: Data((header + "." + payload).utf8)).rawRepresentation.base64EncodedString().filter {
				$0 != "="
			}

			return header + "." + payload + "." + signature
		}

		static func decode<T: Decodable>(_: T.Type, from data: Data, endpoint: String) throws -> T {
			do {
				return try JSONDecoder().decode(T.self, from: data)
			} catch {
				fputs("Failed to decode response from \(endpoint)! Data:\n", stderr)
				try FileHandle.standardError.write(contentsOf: data)
				try FileHandle.standardError.synchronize()
				throw error
			}
		}

		static func send(_ request: URLRequest) async throws -> Data {
			let (data, response) = try await URLSession.shared.data(for: request)
			let statusCode = (response as! HTTPURLResponse).statusCode
			guard 200..<300 ~= statusCode else {
				fputs("Got an error code \(statusCode) from \(request.url!)! Response:\n", stderr)
				try FileHandle.standardError.write(contentsOf: data)
				try FileHandle.standardError.synchronize()
				throw NSError(domain: "\(ProcessInfo.processInfo.processName)-HTTP", code: statusCode)
			}
			return data
		}

		func _fetchyRequest(endpoint: String, method: String = "GET") async throws -> Data {
			var request = URLRequest(url: URL(string: endpoint)!)
			request.addValue("Bearer \(try generateJWT())", forHTTPHeaderField: "Authorization")
			request.httpMethod = method
			return try await Self.send(request)
		}

		func fetchyRequest<T: Codable>(endpoint: String, method: String = "GET", parsing response: T.Type) async throws -> T {
			try Self.decode(T.self, from: await _fetchyRequest(endpoint: endpoint, method: method), endpoint: endpoint)
		}

		func _postyRequest(endpoint: String, method: String = "POST", object: Encodable) async throws -> Data {
			var request = URLRequest(url: URL(string: endpoint)!)
			request.addValue("Bearer \(try generateJWT())", forHTTPHeaderField: "Authorization")
			request.addValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpMethod = method
			request.httpBody = try JSONEncoder().encode(object)
			return try await Self.send(request)
		}

		func postyRequest<T: Codable>(endpoint: String, method: String = "POST", object: Encodable, parsing response: T.Type) async throws -> T {
			try Self.decode(T.self, from: await _postyRequest(endpoint: endpoint, method: method, object: object), endpoint: endpoint)
		}

		struct Response<T: Codable>: Codable {
			struct Links: Codable {
				let next: String?
			}

			let data: [T]
			let links: Links
		}

		func pagedGetRequest<T: Codable>(endpoint: String, parsing data: T.Type) async throws -> [T] {
			var result = [T]()
			var nextEndpoint = Optional.some(endpoint)
			while let endpoint = nextEndpoint {
				let next = try await fetchyRequest(endpoint: endpoint, parsing: Response<T>.self)
				result.append(contentsOf: next.data)
				nextEndpoint = next.links.next
			}
			return result
		}

		func _uploadAsset(endpoint: String, reservation: Encodable, data: Data) async throws -> Data {
			struct Response: Codable {
				struct Asset: Codable {
					struct Attributes: Codable {
						struct UploadOperation: Codable {
							struct HttpHeader: Codable {
								let name: String
								let value: String
							}

							let url: String
							let method: String
							let offset: Int
							let length: Int
							let requestHeaders: [HttpHeader]
						}

						let uploadOperations: [UploadOperation]
					}

					let id: String
					let type: String
					let attributes: Attributes
				}

				let data: Asset
			}

			let asset = try await postyRequest(endpoint: endpoint, object: reservation, parsing: Response.self).data

			for operation in asset.attributes.uploadOperations {
				var request = URLRequest(url: URL(string: operation.url)!)
				request.httpMethod = operation.method
				request.httpBody = data.subdata(in: data.startIndex + operation.offset..<data.startIndex + operation.offset + operation.length)
				for header in operation.requestHeaders {
					request.addValue(header.value, forHTTPHeaderField: header.name)
				}
				_ = try await Self.send(request)
			}

			let checksum = Insecure.MD5.hash(data: data).map { String(format: "%02hhx", $0) }.joined()

			struct Request: Encodable {
				struct Data: Encodable {
					struct Attributes: Encodable {
						let uploaded = true
						let sourceFileChecksum: String
					}

					let id: String
					let type: String
					let attributes: Attributes
				}

				let data: Data
			}

			let request = Request(data: .init(id: asset.id, type: asset.type, attributes: .init(sourceFileChecksum: checksum)))
			return try await _postyRequest(endpoint: "\(endpoint)/\(asset.id)", method: "PATCH", object: request)
		}

		func uploadAsset<T: Codable>(endpoint: String, reservation: Encodable, data: Data, parsing: T.Type) async throws -> T {
			try Self.decode(T.self, from: await _uploadAsset(endpoint: endpoint, reservation: reservation, data: data), endpoint: endpoint)
		}
	}

	let _api: _API

	init(key: Data, keyID: String, issuerID: String) throws {
		_api = try .init(key: key, keyID: keyID, issuerID: issuerID)
	}

	struct App: Codable {
		struct Attributes: Codable {
			let bundleId: String
		}

		let id: String
		let attributes: Attributes
	}

	func apps() async throws -> [App] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/apps", parsing: App.self)
	}

	struct AppBuild: Codable {
		struct Attributes: Codable {
			let version: String
		}

		let id: String
		let attributes: Attributes
	}

	func builds(forAppID appID: String) async throws -> [AppBuild] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/apps/\(appID)/builds", parsing: AppBuild.self)
	}

	struct Build: Codable {
		struct Attributes: Codable {
			enum ProcessingState: String, Codable {
				case PROCESSING
				case FAILED
				case INVALID
				case VALID
			}

			let processingState: ProcessingState
		}

		let id: String
		let attributes: Attributes
	}

	func build(forBuildID buildID: String) async throws -> Build {
		struct Response: Codable {
			let data: Build
		}

		return try await _api.fetchyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/builds/\(buildID)", parsing: Response.self).data
	}

	struct BetaLocalization: Codable {
		struct Attributes: Codable {
			let whatsNew: String?
			let locale: String
		}

		let id: String
		let attributes: Attributes
	}

	func betaLocalizations(forBuildID buildID: String) async throws -> [BetaLocalization] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/builds/\(buildID)/betaBuildLocalizations", parsing: BetaLocalization.self)
	}

	func updateWhatsNew(_ whatsNew: String, forBetaLocalizationID betaLocalizationID: String) async throws {
		struct Request: Encodable {
			struct BetaLocalizationUpdate: Encodable {
				struct Attributes: Encodable {
					let whatsNew: String
				}

				let id: String
				let type = "betaBuildLocalizations"
				let attributes: Attributes
			}

			let data: BetaLocalizationUpdate
		}
		let request = Request(data: .init(id: betaLocalizationID, attributes: .init(whatsNew: whatsNew)))
		_ = try await _api._postyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/betaBuildLocalizations/\(betaLocalizationID)", method: "PATCH", object: request)
	}

	struct BetaGroup: Codable {
		struct Attributes: Codable {
			let name: String
			let isInternalGroup: Bool
		}

		let id: String
		let attributes: Attributes
	}

	func betaGroups(forAppID appID: String) async throws -> [BetaGroup] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/apps/\(appID)/betaGroups", parsing: BetaGroup.self)
	}

	struct BetaGroupBuild: Codable {
		let id: String
	}

	func builds(forBetaGroupID betaGroupID: String) async throws -> [BetaGroupBuild] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/betaGroups/\(betaGroupID)/builds", parsing: BetaGroupBuild.self)
	}

	func setBuilds(buildIDs: [String], toBetaGroupID betaGroupID: String) async throws {
		struct Request: Encodable {
			struct BetaGroupBuild: Encodable {
				let id: String
				let type = "builds"
			}

			let data: [BetaGroupBuild]
		}
		let request = Request(data: buildIDs.map(Request.BetaGroupBuild.init(id:)))
		_ = try await _api._postyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/betaGroups/\(betaGroupID)/relationships/builds", object: request)
	}

	func submitBuildForReview(buildID: String) async throws {
		struct Request: Encodable {
			struct Submission: Encodable {
				struct Relationships: Encodable {
					struct Build: Encodable {
						struct Data: Encodable {
							let id: String
							let type = "builds"
						}

						let data: Data
					}

					let build: Build
				}

				let type = "betaAppReviewSubmissions"
				let relationships: Relationships
			}

			let data: Submission
		}
		let request = Request(data: .init(relationships: .init(build: .init(data: .init(id: buildID)))))
		_ = try await _api._postyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/betaAppReviewSubmissions", object: request)
	}

	struct AppStoreVersion: Codable {
		struct Attributes: Codable {
			enum AppVersionState: String, Codable {
				case ACCEPTED
				case DEVELOPER_REJECTED
				case IN_REVIEW
				case INVALID_BINARY
				case METADATA_REJECTED
				case PENDING_APPLE_RELEASE
				case PENDING_DEVELOPER_RELEASE
				case PREPARE_FOR_SUBMISSION
				case PROCESSING_FOR_DISTRIBUTION
				case READY_FOR_DISTRIBUTION
				case READY_FOR_REVIEW
				case REJECTED
				case REPLACED_WITH_NEW_VERSION
				case WAITING_FOR_EXPORT_COMPLIANCE
				case WAITING_FOR_REVIEW
			}

			let appVersionState: AppVersionState
		}

		let id: String
		let attributes: Attributes
	}

	func appStoreVersions(forAppID appID: String) async throws -> [AppStoreVersion] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/apps/\(appID)/appStoreVersions", parsing: AppStoreVersion.self)
	}

	struct AppStoreVersionLocalization: Codable {
		struct Attributes: Codable {
			let locale: String
		}

		let id: String
		let attributes: Attributes
	}

	func appStoreVersionLocalizations(forVersionID versionID: String) async throws -> [AppStoreVersionLocalization] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", parsing: AppStoreVersionLocalization.self)
	}

	enum ScreenshotDisplayType: String, Codable {
		case APP_IPHONE_67
		case APP_IPHONE_65
		case APP_IPHONE_61
		case APP_IPHONE_58
		case APP_IPHONE_55
		case APP_IPHONE_47
		case APP_IPHONE_40
		case APP_IPHONE_35
		case APP_IPAD_PRO_3GEN_129
		case APP_IPAD_PRO_3GEN_11
		case APP_IPAD_PRO_129
		case APP_IPAD_105
		case APP_IPAD_97
		case APP_DESKTOP
		case APP_WATCH_ULTRA
		case APP_WATCH_SERIES_10
		case APP_WATCH_SERIES_7
		case APP_WATCH_SERIES_4
		case APP_WATCH_SERIES_3
		case APP_APPLE_TV
		case APP_APPLE_VISION_PRO
		case IMESSAGE_APP_IPHONE_67
		case IMESSAGE_APP_IPHONE_61
		case IMESSAGE_APP_IPHONE_65
		case IMESSAGE_APP_IPHONE_58
		case IMESSAGE_APP_IPHONE_55
		case IMESSAGE_APP_IPHONE_47
		case IMESSAGE_APP_IPHONE_40
		case IMESSAGE_APP_IPAD_PRO_3GEN_129
		case IMESSAGE_APP_IPAD_PRO_3GEN_11
		case IMESSAGE_APP_IPAD_PRO_129
		case IMESSAGE_APP_IPAD_105
		case IMESSAGE_APP_IPAD_97
	}

	struct AppScreenshotSet: Codable {
		struct Attributes: Codable {
			let screenshotDisplayType: ScreenshotDisplayType
		}

		let id: String
		let attributes: Attributes
	}

	func appScreenshotSets(forLocalizationID localizationID: String) async throws -> [AppScreenshotSet] {
		try await _api.pagedGetRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets", parsing: AppScreenshotSet.self)
	}

	func deleteAppScreenshotSet(screenshotSetID: String) async throws {
		_ = try await _api._fetchyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/appScreenshotSets/\(screenshotSetID)", method: "DELETE")
	}

	func createAppScreenshotSet(forLocalizationID localizationID: String, displayType: ScreenshotDisplayType) async throws -> AppScreenshotSet {
		struct Request: Encodable {
			struct Data: Encodable {
				struct Attributes: Encodable {
					let screenshotDisplayType: ScreenshotDisplayType
				}

				struct Relationships: Encodable {
					struct Localization: Encodable {
						struct Data: Encodable {
							let id: String
							let type = "appStoreVersionLocalizations"
						}

						let data: Data
					}

					let appStoreVersionLocalization: Localization
				}

				let type = "appScreenshotSets"
				let attributes: Attributes
				let relationships: Relationships
			}

			let data: Data
		}

		struct Response: Codable {
			let data: AppScreenshotSet
		}

		let request = Request(data: .init(attributes: .init(screenshotDisplayType: displayType), relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationID)))))
		return try await _api.postyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/appScreenshotSets", object: request, parsing: Response.self).data
	}

	struct AppScreenshot: Codable {
		struct Attributes: Codable {
			struct AppMediaAssetState: Codable {
				enum State: String, Codable {
					case AWAITING_UPLOAD
					case UPLOAD_COMPLETE
					case COMPLETE
					case FAILED
				}

				let state: State
			}

			let assetDeliveryState: AppMediaAssetState
		}

		let id: String
		let attributes: Attributes
	}

	func uploadScreenshot(fileName: String, data: Data, toScreenshotSetID screenshotSetID: String) async throws -> AppScreenshot {
		struct Request: Encodable {
			struct Data: Encodable {
				struct Attributes: Encodable {
					let fileName: String
					let fileSize: Int
				}

				struct Relationships: Encodable {
					struct ScreenshotSet: Encodable {
						struct Data: Encodable {
							let id: String
							let type = "appScreenshotSets"
						}

						let data: Data
					}

					let appScreenshotSet: ScreenshotSet
				}

				let type = "appScreenshots"
				let attributes: Attributes
				let relationships: Relationships
			}

			let data: Data
		}

		struct Response: Codable {
			let data: AppScreenshot
		}

		let request = Request(data: .init(attributes: .init(fileName: fileName, fileSize: data.count), relationships: .init(appScreenshotSet: .init(data: .init(id: screenshotSetID)))))
		return try await _api.uploadAsset(endpoint: "https://api.appstoreconnect.apple.com/v1/appScreenshots", reservation: request, data: data, parsing: Response.self).data
	}

	func appScreenshot(forAppScreenshotID appScreenshotID: String) async throws -> AppScreenshot {
		struct Response: Codable {
			let data: AppScreenshot
		}

		return try await _api.fetchyRequest(endpoint: "https://api.appstoreconnect.apple.com/v1/appScreenshots/\(appScreenshotID)", parsing: Response.self).data
	}
}

func run(script: URL, arguments: [String]? = nil) throws -> String {
	let output = Pipe()
	let process = Process()
	process.executableURL = script
	process.arguments = arguments
	process.standardOutput = output
	try process.run()
	process.waitUntilExit()
	return String(data: try output.fileHandleForReading.readToEnd()!, encoding: .utf8)!
}

// Turn off buffering so GitHub Actions prints output immediately
setbuf(stdout, nil)

let build = CommandLine.arguments[1]
print("Performing steps for build \(build)...")
print()

let _key = ProcessInfo.processInfo.environment["AUTHENTICATION_KEY"]!
let keyID = ProcessInfo.processInfo.environment["AUTHENTICATION_KEY_ID"]!
let issuerID = ProcessInfo.processInfo.environment["AUTHENTICATION_KEY_ISSUER_ID"]!
print("Loading authentication from \(_key), keyID \(keyID), issuerID \(issuerID)...", terminator: "")

let key = try Data(contentsOf: URL(fileURLWithPath: _key))
let api = try API(key: key, keyID: keyID, issuerID: issuerID)
print("Loaded")

print("Listing apps...", terminator: "")
let apps = try await api.apps()
let appID = apps.first {
	$0.attributes.bundleId == "com.saagarjha.Unwyze"
}!.id
print("Found app ID \(appID)")

// Even though we should've uploaded builds before running this script, they
// might not be listed yet.
print("Waiting for build to become available...")
var builds: [API.AppBuild]
repeat {
	print("Listing builds...", terminator: "")
	builds = try await api.builds(forAppID: appID).filter {
		$0.attributes.version == build
	}
	print("Found \(builds.count) builds")
	guard builds.count != 1 else {
		break
	}
	try await Task.sleep(for: .seconds(10))
} while true

let iOSBuild = builds[0]

print("Waiting for build to process...")

func waitForBuildToProcess(buildID: String) async throws -> API.Build.Attributes.ProcessingState {
	while true {
		let build = try await api.build(forBuildID: buildID)
		print("Build \(buildID) is \(build.attributes.processingState.rawValue)!")
		guard build.attributes.processingState == .PROCESSING else {
			return build.attributes.processingState
		}
		try await Task.sleep(for: .seconds(30))
	}
}

let status = try await waitForBuildToProcess(buildID: iOSBuild.id)
precondition(status == .VALID)

print("Generating notes...", terminator: "")
let notes = try run(script: .init(fileURLWithPath: "generate_notes.sh"))
print("Generated")
print("Notes:")
for line in notes.split(separator: "\n") {
	print("\t\(line)")
}

print("Listing beta groups...", terminator: "")
let betaGroup = try await api.betaGroups(forAppID: appID).first {
	$0.attributes.name == "Test" && !$0.attributes.isInternalGroup
}!
print("Found beta group \(betaGroup.id)")

print("Finding old beta builds in group...", terminator: "")
let betaBuilds = try await api.builds(forBetaGroupID: betaGroup.id)
print("Found \(betaBuilds.count) builds")

print("Adding new build to group...", terminator: "")
try await api.setBuilds(buildIDs: betaBuilds.map(\.id) + [iOSBuild.id], toBetaGroupID: betaGroup.id)
print("Added")

print("Finding localization ID for build \(iOSBuild.id)...", terminator: "")
let localization = try await api.betaLocalizations(forBuildID: iOSBuild.id).first {
	$0.attributes.locale == "en-US"
}!
print("Found")

print("Updating notes for \(localization.id)...", terminator: "")
try await api.updateWhatsNew(notes, forBetaLocalizationID: localization.id)
print("Updated")

print("Submitting build \(iOSBuild.id) for review...", terminator: "")
try await api.submitBuildForReview(buildID: iOSBuild.id)
print("Submitted!")

print("Listing App Store versions...", terminator: "")
let version = try await api.appStoreVersions(forAppID: appID).first {
	$0.attributes.appVersionState == .PREPARE_FOR_SUBMISSION
}!
print("Found App Store version \(version.id)")

print("Finding localization ID for version \(version.id)...", terminator: "")
let appStoreLocalization = try await api.appStoreVersionLocalizations(forVersionID: version.id).first {
	$0.attributes.locale == "en-US"
}!
print("Found")

print("Finding screenshot sets for \(appStoreLocalization.id)...", terminator: "")
let sets = try await api.appScreenshotSets(forLocalizationID: appStoreLocalization.id)
print("Found \(sets.count) sets")

for set in sets {
	print("Deleting screenshot set \(set.id)...", terminator: "")
	try await api.deleteAppScreenshotSet(screenshotSetID: set.id)
	print("Deleted")
}

let screenshots = [
	("iPhone 17 Pro Max", API.ScreenshotDisplayType.APP_IPHONE_67),
	("iPad Pro 13-inch (M5)", API.ScreenshotDisplayType.APP_IPAD_PRO_3GEN_129),
]

for (device, displayType) in screenshots {
	print("Generating screenshots for \(device)...", terminator: "")
	let screenshots = try run(script: .init(fileURLWithPath: "./generate_screenshots.sh"), arguments: [device])
		.split(separator: "\n")
		.map(String.init)
	print("Generated \(screenshots.count) screenshots")

	print("Creating screenshot set for \(displayType.rawValue)...", terminator: "")
	let set = try await api.createAppScreenshotSet(forLocalizationID: appStoreLocalization.id, displayType: displayType)
	print("Created \(set.id)")

	for file in screenshots {
		print("Uploading \(file)...", terminator: "")
		var screenshot = try await api.uploadScreenshot(fileName: file, data: Data(contentsOf: .init(fileURLWithPath: file)), toScreenshotSetID: set.id)
		print("Uploaded")

		while screenshot.attributes.assetDeliveryState.state == .UPLOAD_COMPLETE {
			screenshot = try await api.appScreenshot(forAppScreenshotID: screenshot.id)
			print("Screenshot \(screenshot.id) is \(screenshot.attributes.assetDeliveryState.state.rawValue)!")
			try await Task.sleep(for: .seconds(5))
		}
		precondition(screenshot.attributes.assetDeliveryState.state == .COMPLETE)
	}
}

print()
print("Finished!")
