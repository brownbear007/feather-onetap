//
//  BatchResigner.swift
//  Feather
//
//  Local patch: Re-sign All. Re-signs the apps in the Signed list, each with the certificate picked
//  for it, so a revoked certificate can be swapped out in one go. The signed copy is re-signed as it
//  is: tweaks, name and identifier are already in it, so nothing is injected or renamed again.
//

import CoreData
import Foundation
import UIKit

@MainActor
final class BatchResigner: ObservableObject {
	static let shared = BatchResigner()
	private init() {}

	struct Job: Identifiable {
		let id: String          // the Signed copy's UUID when the job was queued
		let name: String
		let identifier: String?
		let certificate: CertificatePair
	}

	/// What each queued app is doing now, by the job id: "Waiting", "Signing", "Done", or an error.
	@Published private(set) var status: [String: String] = [:]
	@Published private(set) var isRunning = false

	// MARK: Certificate per app

	private static func _certKey(_ identifier: String) -> String { "feather.certificate.\(identifier)" }

	/// The certificate this app was last signed with (by choice), if it is still in Feather.
	static func rememberedCertificate(for identifier: String?) -> CertificatePair? {
		guard let identifier, !identifier.isEmpty,
		      let uuid = UserDefaults.standard.string(forKey: _certKey(identifier)) else { return nil }
		return Storage.shared.getAllCertificates().first { $0.uuid == uuid }
	}

	static func rememberCertificate(_ certificate: CertificatePair?, for identifier: String?) {
		guard let identifier, !identifier.isEmpty, let uuid = certificate?.uuid else { return }
		UserDefaults.standard.set(uuid, forKey: _certKey(identifier))
	}

	/// The certificate a re-sign of this app starts with: the one picked for it before, else the one its
	/// signed copy carries, else Feather's selected certificate.
	static func defaultCertificate(for app: Signed) -> CertificatePair? {
		rememberedCertificate(for: app.identifier)
			?? app.certificate
			?? Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "feather.selectedCert"))
	}

	// MARK: Run

	func run(_ jobs: [Job]) {
		guard !isRunning, !jobs.isEmpty else { return }
		isRunning = true
		status = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, String.localized("Waiting")) })
		Task { @MainActor in
			var done: [Signed] = []
			for job in jobs {
				guard let app = _signed().first(where: { $0.uuid == job.id }) else {
					status[job.id] = .localized("Not found")
					continue
				}
				status[job.id] = .localized("Signing")
				if let signed = await _resign(app, with: job.certificate) {
					BatchResigner.rememberCertificate(job.certificate, for: job.identifier)
					AutoUpdater.shared.removeOlderSigned(identifier: signed.identifier)
					AutoUpdater.shared.markReadyToInstall(signed)
					done.append(signed)
					status[job.id] = .localized("Done")
				}
			}
			isRunning = false
			UINotificationFeedbackGenerator().notificationOccurred(done.count == jobs.count ? .success : .warning)
			NotificationCenter.default.post(name: Notification.Name("Feather.autoUpdateFinished"), object: nil)
		}
	}

	private func _resign(_ app: Signed, with certificate: CertificatePair) async -> Signed? {
		var options = OptionsManager.shared.options
		// Already in the signed copy: do not inject, remove or rename again.
		options.injectionFiles = []
		options.disInjectionFiles = []
		options.removeFiles = []
		options.appName = nil
		options.appIdentifier = nil
		options.appVersion = nil
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false
		// A custom entitlements file from the last manual signing still applies (a JIT certificate may need it).
		if let remembered = try? AutoUpdater.rememberedOptions(for: app.identifier),
		   let file = remembered.appEntitlementsFile, FileManager.default.fileExists(atPath: file.path) {
			options.appEntitlementsFile = file
		} else {
			options.appEntitlementsFile = nil
		}

		let started = Date()
		let error: Error? = await withCheckedContinuation { continuation in
			FR.signPackageFile(app, using: options, icon: nil, certificate: certificate) { error in
				continuation.resume(returning: error)
			}
		}
		if let error {
			status[app.uuid ?? ""] = String.localized("Failed: ") + error.localizedDescription
			return nil
		}
		return _signed().first { ($0.date ?? .distantPast) >= started.addingTimeInterval(-1) }
	}

	private func _signed() -> [Signed] {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}
}
