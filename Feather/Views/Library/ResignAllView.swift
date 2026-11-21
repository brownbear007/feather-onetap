//
//  ResignAllView.swift
//  Feather
//
//  Local patch: Re-sign All. Every app in the Signed list with a certificate picker of its own (it
//  starts on the one picked for that app last time), a tick to leave an app out, and one button to
//  re-sign them all. Revoked certificates are marked, and "Set all to" switches every app at once.
//

import CoreData
import SwiftUI

struct ResignAllView: View {
	@Environment(\.dismiss) private var dismiss
	@ObservedObject private var resigner = BatchResigner.shared

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
	) private var _signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)]
	) private var _certificates: FetchedResults<CertificatePair>

	/// The certificate picked for each app (by the Signed copy's UUID), and the apps left out.
	@State private var _picked: [String: String] = [:]
	@State private var _skipped: Set<String> = []
	@State private var _started = false

	var body: some View {
		NavigationView {
			List {
				Section {
					Menu {
						ForEach(_certificates, id: \.uuid) { cert in
							Button {
								for app in _signedApps { if let uuid = app.uuid { _picked[uuid] = cert.uuid } }
							} label: {
								Label(Self.name(of: cert), systemImage: cert.revoked ? "xmark.seal" : "checkmark.seal")
							}
						}
					} label: {
						Label(String.localized("Set All Apps To…"), systemImage: "rectangle.stack.badge.person.crop")
					}
					.disabled(_started)
				} footer: {
					Text(String.localized("Each app keeps the certificate you pick for it here, and its next update uses it too."))
				}

				Section(String.localized("Apps")) {
					ForEach(_signedApps, id: \.uuid) { app in
						_row(app)
					}
				}
			}
			.navigationTitle(String.localized("Re-sign All"))
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(_started && !resigner.isRunning ? String.localized("Done") : String.localized("Cancel")) { dismiss() }
						.disabled(resigner.isRunning)
				}
				ToolbarItem(placement: .confirmationAction) {
					if resigner.isRunning {
						ProgressView()
					} else if !_started {
						Button(String.localized("Re-sign (\(_jobs.count))")) {
							_started = true
							resigner.run(_jobs)
						}
						.disabled(_jobs.isEmpty)
					}
				}
			}
			.onAppear(perform: _fillDefaults)
		}
		.interactiveDismissDisabled(resigner.isRunning)
	}

	@ViewBuilder
	private func _row(_ app: Signed) -> some View {
		let uuid = app.uuid ?? ""
		let included = !_skipped.contains(uuid)
		HStack(spacing: 12) {
			Button {
				if included { _skipped.insert(uuid) } else { _skipped.remove(uuid) }
			} label: {
				Image(systemName: included ? "checkmark.circle.fill" : "circle")
					.font(.title3)
					.foregroundStyle(included ? Color.accentColor : Color.secondary)
			}
			.buttonStyle(.plain)
			.disabled(_started)

			FRAppIconView(app: app, size: 40)

			VStack(alignment: .leading, spacing: 3) {
				Text(app.name ?? String.localized("Unknown")).font(.body.weight(.medium)).lineLimit(1)
				if let status = resigner.status[uuid] {
					Text(status).font(.caption).foregroundStyle(status.hasPrefix(String.localized("Failed")) ? .red : .secondary)
						.lineLimit(2)
				} else {
					Text(app.identifier ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			Menu {
				ForEach(_certificates, id: \.uuid) { cert in
					Button {
						_picked[uuid] = cert.uuid
					} label: {
						if _picked[uuid] == cert.uuid {
							Label(Self.name(of: cert), systemImage: "checkmark")
						} else {
							Text(Self.name(of: cert) + (cert.revoked ? " · " + String.localized("Revoked") : ""))
						}
					}
				}
			} label: {
				let cert = _certificates.first { $0.uuid == _picked[uuid] }
				HStack(spacing: 4) {
					if cert?.revoked == true { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
					Text(cert.map(Self.name(of:)) ?? String.localized("Choose")).lineLimit(1)
					Image(systemName: "chevron.up.chevron.down").font(.caption2)
				}
				.font(.subheadline)
				.foregroundStyle(cert?.revoked == true ? .red : Color.accentColor)
				.frame(maxWidth: 140, alignment: .trailing)
			}
			.disabled(_started)
		}
		.opacity(included ? 1 : 0.5)
	}

	private var _jobs: [BatchResigner.Job] {
		_signedApps.compactMap { app in
			guard let uuid = app.uuid, !_skipped.contains(uuid),
			      let cert = _certificates.first(where: { $0.uuid == _picked[uuid] }) else { return nil }
			return .init(id: uuid, name: app.name ?? "", identifier: app.identifier, certificate: cert)
		}
	}

	private func _fillDefaults() {
		for app in _signedApps {
			guard let uuid = app.uuid, _picked[uuid] == nil else { continue }
			_picked[uuid] = BatchResigner.defaultCertificate(for: app)?.uuid
		}
	}

	/// A certificate's nickname, or its profile's name, with its expiry month for telling them apart.
	static func name(of cert: CertificatePair) -> String {
		let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
		let base = cert.nickname ?? decoded?.Name ?? String.localized("Certificate")
		let isDev = decoded?.Entitlements?["get-task-allow"]?.value as? Bool == true
		return base + (isDev ? " (" + String.localized("Dev") + ")" : "")
	}
}
