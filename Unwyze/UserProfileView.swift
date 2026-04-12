//
//  UserProfileView.swift
//  Unwyze
//
//  Created by Saagar Jha on 4/11/26.
//

import SwiftUI

struct UserProfileView: View {
	@Binding
	var showSettings: Bool

	@Binding
	var profile: EditableUserProfile

	private static let heightOptions: [Foundation.Measurement<UnitLength>] = {
		if Locale.current.measurementSystem == .metric {
			return (100...250).map { .init(value: Double($0), unit: .centimeters) }
		} else {
			return (40...100).map { .init(value: Double($0), unit: .inches) }
		}
	}()

	var body: some View {
		NavigationStack {
			Form {
				Section(
					content: {
						Picker("Sex", selection: $profile.sex) {
							if profile.sex == nil {
								Text("").tag(Sex?.none)
							}
							Text("Male").tag(Sex.male)
							Text("Female").tag(Sex.female)
						}
						DatePicker("Birthdate", selection: $profile.birthdate, displayedComponents: .date)
						LabeledContent("Height") {
							Picker("", selection: $profile.height) {
								if profile.height == nil {
									Text("").tag(Int?.none)
								}
								ForEach(Self.heightOptions, id: \.value) { height in
									let cm = Int(height.converted(to: .centimeters).value.rounded())
									Text(height.formatted(.measurement(width: .abbreviated, usage: .personHeight)))
										.tag(Int?(cm))
								}
							}
							.pickerStyle(.wheel)
						}
						LabeledContent("Athlete Mode") {
							Toggle("", isOn: $profile.isAthlete)
						}
					},
					footer: {
						Text("This information is sent to your scale so it can calculate your body metrics. It is deleted from the scale once the reading is done and is not persisted in HealthKit.")
					})
			}
			.navigationTitle("You")
			.interactiveDismissDisabled(profile.profile == nil)
			.toolbar {
				ToolbarItem(placement: .confirmationAction) {
					Button(
						role: .confirm,
						action: {
							showSettings = false
						}
					)
					.disabled(profile.profile == nil)
				}
			}
		}
	}
}

#Preview {
	@Previewable
	@State
	var profile = EditableUserProfile()

	UserProfileView(showSettings: .constant(true), profile: $profile)
}
