//
//  EditableUserProfile.swift
//  Unwyze
//
//  Created by Saagar Jha on 4/12/26.
//

import SwiftUI

@propertyWrapper
struct UserProfileStorage: DynamicProperty {
	// Dummy state that SwiftUI thinks we depend on
	@State
	var _update = false

	var wrappedValue: EditableUserProfile {
		get {
			_ = _update
			return (UserDefaults.standard.value(forKey: "profile") as! Data?).flatMap {
				try! JSONDecoder().decode(EditableUserProfile.self, from: $0)
			} ?? EditableUserProfile()
		}
		nonmutating set {
			_update.toggle()
			UserDefaults.standard.set(try! JSONEncoder().encode(newValue), forKey: "profile")
		}
	}

	var projectedValue: Binding<EditableUserProfile> {
		.init(
			get: {
				wrappedValue
			},
			set: {
				wrappedValue = $0
			})
	}
}

struct EditableUserProfile: Codable {
	var sex = Sex?.none
	var birthdate = Date.now
	var height = Int?.none
	var isAthlete = false

	var profile: UserProfile? {
		guard let sex, let height else {
			return nil
		}

		return UserProfile(
			sex: sex,
			age: UInt8(Calendar.current.dateComponents([.year], from: birthdate, to: .now).year!),
			height: UInt8(height),
			athlete: isAthlete
		)
	}
}

extension Sex: Codable {}
