//
//  AutoUpdater.swift
//  Feather
//
//  One-tap updates: download the source's new build, sign it on the device with the
//  certificate and options the app was last signed with, install it, and delete the older
//  Signed and Imported copies of that app so only the new one is left.
//

import CoreData
import Foundation
import UIKit

@MainActor
final class AutoUpdater: ObservableObject {
	static let shared = AutoUpdater()

	/// Apps being updated, by the library app's UUID: what is happening now.
	@Published private(set) var working: [String: String] = [:]

	/// Download ids carry this, after the "manual download" prefix so the download header still shows them.
	static let marker = "FeatherManualDownload_AutoUpdate_"

	private struct Pending {
		let localUUID: String
		let oldIdentifier: String?
		let sourceIdentifier: String
		let certificate: CertificatePair?
		let started: Date
	}

	private var _pending: [String: Pending] = [:]
	
	/// Signed updates whose install has not started yet (the install sheet was closed first), by the
	/// Signed copy's UUID. Their row keeps an Update button until iOS starts installing them.
	@Published private(set) var pendingInstall: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "feather.autoUpdate.pendingInstall") ?? [])
	
	private func _savePendingInstall() {
		UserDefaults.standard.set(Array(pendingInstall), forKey: "feather.autoUpdate.pendingInstall")
	}
	
	/// Apps whose install sheet is open: their row says Updating, not Update.
	@Published private(set) var installing: Set<String> = []
	
	func installSheet(_ app: AppInfoPresentable, shown: Bool) {
		guard let uuid = app.uuid, pendingInstall.contains(uuid) || installing.contains(uuid) else { return }
		if shown { installing.insert(uuid) } else { installing.remove(uuid) }
	}
	
	/// iOS has begun installing (or finished installing) this app: it no longer needs an Update button.
	func installStarted(_ app: AppInfoPresentable) {
		guard let uuid = app.uuid, pendingInstall.contains(uuid) else { return }
		pendingInstall.remove(uuid)
		_savePendingInstall()
	}

	private init() {}

	// MARK: Start

	func isUpdating(_ app: AppInfoPresentable) -> Bool {
		guard let uuid = app.uuid else { return false }
		return working[uuid] != nil
	}

	func start(_ update: AppUpdate, replacing app: AppInfoPresentable) {
		guard working[update.localUUID] == nil else { return }
		let id = Self.marker + update.localUUID
		_pending[id] = Pending(
			localUUID: update.localUUID,
			oldIdentifier: app.identifier,
			sourceIdentifier: update.bundleIdentifier,
			certificate: Storage.shared.getCertificate(from: app) ?? Self._selectedCertificate(),
			started: Date()
		)
		// Already downloaded (Download Only, or a signing that failed): sign that copy, no new download.
		if let ready = _downloadedCopy(of: update, newerThan: app) {
			let pending = _pending.removeValue(forKey: id)!
			_sign(ready, pending)
			return
		}
		working[update.localUUID] = .localized("Downloading")
		_ = DownloadManager.shared.startDownload(
			from: update.downloadURL,
			id: id,
			sourceProvenance: update.sourceProvenance
		)
	}

	/// Called by the download manager once a download has been imported (or failed to).
	func downloadFinished(id: String, error: Error?) {
		guard let pending = _pending.removeValue(forKey: id) else { return }
		if let error {
			_fail(pending, String.localized("The download could not be imported: ") + error.localizedDescription)
			return
		}
		guard let imported = _newestImported(since: pending.started, preferring: pending.sourceIdentifier) else {
			_fail(pending, .localized("The downloaded app was not found in the library."))
			return
		}
		_sign(imported, pending)
	}

	/// A download that was cancelled or failed before it finished.
	func downloadCancelled(id: String) {
		guard let pending = _pending.removeValue(forKey: id) else { return }
		working[pending.localUUID] = nil
	}

	// MARK: Sign, clean up, install

	private func _sign(_ imported: Imported, _ pending: Pending) {
		guard pending.certificate != nil else {
			_fail(pending, .localized("No certificate to sign with. Add one in Settings › Certificates."))
			return
		}
		working[pending.localUUID] = .localized("Signing")

		var options: Options
		do {
			options = try Self.rememberedOptions(for: imported.identifier)
				?? Self.rememberedOptions(for: pending.oldIdentifier)
				?? OptionsManager.shared.options
		} catch {
			_fail(pending, error.localizedDescription)
			return
		}
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false
		options.appVersion = nil
		// The same renames the signing screen applies when it opens.
		if options.appIdentifier == nil, let id = imported.identifier {
			if let renamed = options.identifiers[id] {
				options.appIdentifier = renamed
			} else if options.ppqProtection, pending.certificate?.ppQCheck == true {
				options.appIdentifier = "\(id).\(options.ppqString)"
			}
		}
		if options.appName == nil, let name = imported.name, let renamed = options.displayNames[name] {
			options.appName = renamed
		}

		let signStarted = Date()
		FR.signPackageFile(
			imported,
			using: options,
			icon: nil,
			certificate: pending.certificate
		) { error in
			Task { @MainActor in
				let updater = AutoUpdater.shared
				if let error {
					updater._fail(pending, String.localized("Signing failed: ") + error.localizedDescription)
					return
				}
				updater._finish(imported: imported, signedSince: signStarted, pending)
			}
		}
	}

	private func _finish(imported: Imported, signedSince: Date, _ pending: Pending) {
		guard let newSigned = _newestSigned(since: signedSince) else {
			_fail(pending, .localized("The signed app was not found in the library."))
			return
		}

		// Keep only the new signed copy: older signed copies of this app, and its imported copies.
		var identifiers = Set([newSigned.identifier, pending.oldIdentifier].compactMap { $0 })
		if let id = imported.identifier { identifiers.insert(id) }
		for old in _signed() where old.uuid != newSigned.uuid && identifiers.contains(old.identifier ?? "") {
			Storage.shared.deleteApp(for: old)
		}
		var importedIdentifiers = Set([imported.identifier, pending.sourceIdentifier, pending.oldIdentifier].compactMap { $0 })
		importedIdentifiers.remove("")
		for old in _imported() where importedIdentifiers.contains(old.identifier ?? "") {
			Storage.shared.deleteApp(for: old)
		}

		working[pending.localUUID] = nil
		if let uuid = newSigned.uuid {
			pendingInstall.insert(uuid)
			_savePendingInstall()
		}
		UINotificationFeedbackGenerator().notificationOccurred(.success)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
			NotificationCenter.default.post(name: Notification.Name("Feather.installApp"), object: nil)
			NotificationCenter.default.post(name: Notification.Name("Feather.autoUpdateFinished"), object: nil)
		}
	}

	private func _fail(_ pending: Pending, _ message: String) {
		working[pending.localUUID] = nil
		UINotificationFeedbackGenerator().notificationOccurred(.error)
		UIAlertController.showAlertWithOk(title: .localized("Update Failed"), message: message)
	}

	// MARK: Library lookups

	private func _signed() -> [Signed] {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}

	private func _imported() -> [Imported] {
		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.sortDescriptors = [NSSortDescriptor(keyPath: \Imported.date, ascending: false)]
		return (try? Storage.shared.context.fetch(request)) ?? []
	}

	/// An imported copy of this update, newer than the app being updated, waiting to be signed.
	private func _downloadedCopy(of update: AppUpdate, newerThan app: AppInfoPresentable) -> Imported? {
		let identifiers = Set([update.bundleIdentifier, app.identifier].compactMap { $0 })
		let after = app.date ?? .distantPast
		return _imported().first {
			$0.uuid != app.uuid && identifiers.contains($0.identifier ?? "") && ($0.date ?? .distantPast) > after
		}
	}
	
	private func _newestImported(since date: Date, preferring identifier: String) -> Imported? {
		let fresh = _imported().filter { ($0.date ?? .distantPast) >= date.addingTimeInterval(-1) }
		return fresh.first { $0.identifier == identifier } ?? fresh.first
	}

	private func _newestSigned(since date: Date) -> Signed? {
		_signed().first { ($0.date ?? .distantPast) >= date.addingTimeInterval(-1) }
	}

	private static func _selectedCertificate() -> CertificatePair? {
		Storage.shared.getCertificate(for: UserDefaults.standard.integer(forKey: "feather.selectedCert"))
	}

	// MARK: Remembered signing options
	//
	// Each manual signing saves the options it used under the app's identifier, so an update is signed
	// the same way (tweaks, name, identifier, entitlements). Tweak files live in a temporary folder
	// while signing, so they are copied to Documents/AutoUpdate/<identifier>/ and found by name.

	private static func _key(_ identifier: String) -> String { "feather.autoUpdate.options.\(identifier)" }

	private static func _tweakFolder(_ identifier: String) -> URL {
		URL.documentsDirectory
			.appendingPathComponent("AutoUpdate", isDirectory: true)
			.appendingPathComponent(identifier, isDirectory: true)
	}

	static func remember(_ options: Options, for identifier: String?) {
		guard let identifier, !identifier.isEmpty else { return }
		let fileManager = FileManager.default
		let folder = _tweakFolder(identifier)
		var saved = options
		saved.appVersion = nil
		saved.post_installAppAfterSigned = false
		saved.post_deleteAppAfterSigned = false

		// Copy the tweaks first, then swap the folder in, so a failed copy keeps the last good set.
		let staging = folder.deletingLastPathComponent().appendingPathComponent(".\(identifier).\(UUID().uuidString)", isDirectory: true)
		try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
		var names: [URL] = []
		for file in options.injectionFiles {
			let destination = staging.appendingPathComponent(file.lastPathComponent)
			try? fileManager.copyItem(at: file, to: destination)
			guard fileManager.fileExists(atPath: destination.path) else {
				try? fileManager.removeItem(at: staging)
				return
			}
			names.append(URL(fileURLWithPath: file.lastPathComponent))
		}
		try? fileManager.removeItem(at: folder)
		try? fileManager.moveItem(at: staging, to: folder)

		saved.injectionFiles = names
		if let data = try? JSONEncoder().encode(saved) {
			UserDefaults.standard.set(data, forKey: _key(identifier))
		}
	}

	static func rememberedOptions(for identifier: String?) throws -> Options? {
		guard
			let identifier, !identifier.isEmpty,
			let data = UserDefaults.standard.data(forKey: _key(identifier)),
			var options = try? JSONDecoder().decode(Options.self, from: data)
		else {
			return nil
		}
		let folder = _tweakFolder(identifier)
		options.injectionFiles = try options.injectionFiles.map { name in
			let file = folder.appendingPathComponent(name.lastPathComponent)
			guard FileManager.default.fileExists(atPath: file.path) else {
				throw AutoUpdaterError.missingTweak(name.lastPathComponent)
			}
			return file
		}
		return options
	}
}

enum AutoUpdaterError: LocalizedError {
	case missingTweak(String)

	var errorDescription: String? {
		switch self {
		case .missingTweak(let name):
			return String.localized("The tweak \(name) used last time is missing. Sign this update once from the Sign screen, and later updates will use it again.")
		}
	}
}
