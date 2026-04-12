//
//  MeasurementView.swift
//  Unwyze
//
//  Created by Saagar Jha on 4/12/26.
//

import HealthKit
import SwiftUI

struct MeasurementView: View {
	@UserProfileStorage
	var profile

	@State
	var showUserProfile = false

	@State
	var measurementStatus: MeasurementStatus?

	@State
	var measurementTask: Task<Void, Error>?

	@State
	var saved = false

	@State
	var error: Error?

	@State
	var showWeighingError = false

	@State
	var showSavingError = false

	var body: some View {
		NavigationStack {
			Form {
				if case .complete(let measurement) = measurementStatus {
					Group {
						Section {
							LabeledContent("Weight", value: Foundation.Measurement(value: measurement.weight, unit: UnitMass.kilograms), format: Self.massFormat)
							LabeledContent("Body Fat", value: measurement.bodyFat / 100, format: Self.percentFormat)
							LabeledContent("Muscle Mass", value: Foundation.Measurement(value: measurement.muscleMass, unit: UnitMass.kilograms), format: Self.massFormat)
							LabeledContent("Bone Mass", value: Foundation.Measurement(value: measurement.boneMass, unit: UnitMass.kilograms), format: Self.massFormat)
							LabeledContent("Body Water", value: measurement.bodyWater / 100, format: Self.percentFormat)
							LabeledContent("Protein", value: measurement.protein / 100, format: Self.percentFormat)
							LabeledContent("Lean Mass", value: Foundation.Measurement(value: measurement.leanMass, unit: UnitMass.kilograms), format: Self.massFormat)
							LabeledContent("Visceral Fat", value: measurement.visceralFat, format: .number)
							LabeledContent("BMR", value: Foundation.Measurement(value: Double(measurement.bmr), unit: UnitEnergy.kilocalories), format: Self.energyFormat)
							LabeledContent("Body Age", value: measurement.bodyAge, format: .number)
							LabeledContent("Impedance", value: Foundation.Measurement(value: measurement.impedance, unit: UnitElectricResistance.ohms), format: Self.resistanceFormat)
							LabeledContent("BMI", value: measurement.bmi, format: .number.precision(.fractionLength(1)))
						}
						Section(
							content: {
								Button("Save to HealthKit") {
									Task {
										do {
											try await saveToHealthKit(measurement)
											saved = true
										} catch {
											self.error = error
											showSavingError = true
										}
									}
								}
								.disabled(saved)
							},
							footer: {
								if saved {
									Text("Your data has been saved to HealthKit.")
								} else {
									Text("Your weight, body fat percentage, lean mass, BMR, and BMI will be saved to HealthKit.")
								}
							})
					}
					.navigationTitle("Completed")
					.navigationSubtitle(Text("Battery: \(measurement.battery, format: IntegerFormatStyle.Percent.percent)"))
				} else if let measurementStatus {
					let text =
						switch measurementStatus {
							case .scanning:
								Text("Scanning…")
							case .connecting:
								Text("Connecting…")
							case .settingUp:
								Text("Setting up…")
							case .weighing(_, .stepping):
								Text("Settling…")
							case .weighing(_, .measuring):
								Text("Weighing…")
							case .weighing(_, .stable):
								Text("Measuring…")
							case .complete:
								fatalError()
						}

					Section {
						if case .weighing(let kg, _) = measurementStatus {
							LabeledContent("Weight") {
								HStack {
									Text(Foundation.Measurement(value: kg, unit: UnitMass.kilograms), format: Self.massFormat)
									ProgressView()
								}
							}
						} else {
							LabeledContent("Weight") {
								ProgressView()
							}
						}
						LabeledContent("Body Fat") {
							ProgressView()
						}
						LabeledContent("Muscle Mass") {
							ProgressView()
						}
						LabeledContent("Bone Mass") {
							ProgressView()
						}
						LabeledContent("Body Water") {
							ProgressView()
						}
						LabeledContent("Protein") {
							ProgressView()
						}
						LabeledContent("Lean Mass") {
							ProgressView()
						}
						LabeledContent("Visceral Fat") {
							ProgressView()
						}
						LabeledContent("BMR") {
							ProgressView()
						}
						LabeledContent("Body Age") {
							ProgressView()
						}
						LabeledContent("Impedance") {
							ProgressView()
						}
						LabeledContent("BMI") {
							ProgressView()
						}
					}
					.navigationTitle(text)
				} else {
					Section(
						content: {
							Button("Start Measuring") {
								takeMeasurement()
							}
							.disabled(profile.profile == nil)
						},
						footer: {
							Text("As you hit this button, stand on the scale to wake it up.")
						}
					)
					.navigationTitle("Ready")
				}
			}
			.refreshable {
				// This should be on the completed view but that isn't supported
				if case .complete = measurementStatus {
					measurementStatus = nil
				}
			}
			.toolbar {
				ToolbarItem {
					Button(action: {
						showUserProfile = true
					}) {
						Image(systemName: "person")
					}
				}
			}
		}
		.sheet(isPresented: $showUserProfile) {
			UserProfileView(showSettings: $showUserProfile, profile: $profile)
		}
		.onAppear {
			showUserProfile = profile.profile == nil
		}
		.onDisappear {
			measurementTask?.cancel()
		}
		.alert(
			"Weighing failed", isPresented: $showWeighingError,
			actions: {
				Button("OK", role: .close) {
					error = nil
					measurementStatus = nil
				}
			}
		) {
			// For whatever reason, this gets called eagerly.
			if let error {
				Text(error.localizedDescription)
			}
		}
		.alert(
			"Saving to HealthKit failed", isPresented: $showSavingError,
			actions: {
				Button("OK", role: .close) {
					error = nil
				}
			}
		) {
			// For whatever reason, this gets called eagerly.
			if let error {
				Text(error.localizedDescription)
			}
		}
	}

	static let massFormat = Foundation.Measurement<UnitMass>.FormatStyle.measurement(width: .abbreviated, usage: .personWeight, numberFormatStyle: .number.precision(.fractionLength(1)))
	static let percentFormat = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(1))
	static let energyFormat = Foundation.Measurement<UnitEnergy>.FormatStyle.measurement(width: .abbreviated, usage: .food)
	static let resistanceFormat = Foundation.Measurement<UnitElectricResistance>.FormatStyle.measurement(width: .abbreviated, usage: .asProvided)

	func saveToHealthKit(_ measurement: Measurement) async throws {
		let healthStore = HKHealthStore()
		let types: Set<HKSampleType> = [
			HKQuantityType(.bodyMass),
			HKQuantityType(.bodyFatPercentage),
			HKQuantityType(.leanBodyMass),
			HKQuantityType(.basalEnergyBurned),
			HKQuantityType(.bodyMassIndex),
		]
		try await healthStore.requestAuthorization(toShare: types, read: [])
		let now = Date()
		let samples: [HKQuantitySample] = [
			HKQuantitySample(type: HKQuantityType(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: measurement.weight), start: now, end: now),
			HKQuantitySample(type: HKQuantityType(.bodyFatPercentage), quantity: HKQuantity(unit: .percent(), doubleValue: measurement.bodyFat / 100), start: now, end: now),
			HKQuantitySample(type: HKQuantityType(.leanBodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: measurement.leanMass), start: now, end: now),
			HKQuantitySample(type: HKQuantityType(.basalEnergyBurned), quantity: HKQuantity(unit: .largeCalorie(), doubleValue: Double(measurement.bmr)), start: now, end: now),
			HKQuantitySample(type: HKQuantityType(.bodyMassIndex), quantity: HKQuantity(unit: .count(), doubleValue: measurement.bmi), start: now, end: now),
		]
		for sample in samples where healthStore.authorizationStatus(for: sample.sampleType) == .sharingAuthorized {
			try await healthStore.save(sample)
		}
	}

	func takeMeasurement() {
		measurementTask?.cancel()
		saved = false
		measurementTask = Task {
			do {
				for try await status in WyzeScale.measure(user: profile.profile!) {
					measurementStatus = status
				}
			} catch {
				self.error = error
				showWeighingError = true
			}
		}
	}
}

#Preview {
	MeasurementView()
}

#Preview {
	MeasurementView(measurementStatus: .scanning)
}

#Preview {
	MeasurementView(measurementStatus: .connecting)
}

#Preview {
	MeasurementView(measurementStatus: .settingUp)
}

#Preview {
	MeasurementView(measurementStatus: .weighing(kg: 67, state: .stepping))
}

#Preview {
	MeasurementView(measurementStatus: .weighing(kg: 67, state: .measuring))
}

#Preview {
	MeasurementView(measurementStatus: .weighing(kg: 67, state: .stable))
}

#Preview {
	MeasurementView(measurementStatus: .complete(.init(weight: 67, bodyFat: 42, muscleMass: 50, boneMass: 2.5, bodyWater: 50, protein: 15, leanMass: 50, visceralFat: 5, bmr: 1500, bodyAge: 25, bmi: 20, impedance: 500, battery: 0)))
}
