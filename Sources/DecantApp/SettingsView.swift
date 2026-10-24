import DecantCore
import SwiftUI

struct SettingsView: View {
    let preferences: AppPreferences

    var body: some View {
        Form {
            SettingToggle(title: "Keep Decant in the menu bar",
                          detail: "Decant stays in the menu bar when its window is closed.",
                          setting: preferences.menuBar,
                          set: preferences.setMenuBar)
            SettingToggle(title: "Open at login",
                          detail: "Decant opens when you log in.",
                          setting: preferences.openAtLogin,
                          set: preferences.setOpenAtLogin)
            Divider().padding(.bottom, 8)
            SettingToggle(title: "Install updates automatically",
                          detail: "New versions of Decant are installed from GitHub while your Mac is idle.",
                          setting: preferences.updates.automatic,
                          set: preferences.setAutomaticUpdates)
            DeferralStepper(setting: preferences.updates.deferralDays,
                            isEnabled: preferences.updates.automatic.isEnabled,
                            set: preferences.setUpdateDeferralDays)
            UpdateStatus(state: preferences.updateState)
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct SettingToggle: View {
    let title: String
    let detail: String
    let setting: ManagedSetting
    let set: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { setting.isEnabled }, set: { set($0) }))
                .disabled(setting.isManaged)
            Text(setting.isManaged ? "Managed by your organisation." : detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }
}

/// How many days after a release it is installed.
private struct DeferralStepper: View {
    let setting: ManagedValue<Int>
    let isEnabled: Bool
    let set: @MainActor (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: Binding(get: { setting.value }, set: { set($0) }), in: 0...Configuration.maxUpdateDeferralDays) {
                Text(setting.value == 0 ? "Install as soon as a version is released"
                     : "Wait \(setting.value) \(setting.value == 1 ? "day" : "days") after a release")
            }
            .disabled(setting.isManaged || !isEnabled)
            Text(setting.isManaged ? "Managed by your organisation."
                 : "Gives time for problems with a new version to be found first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }
}

/// The current version and what the update daemon last did.
private struct UpdateStatus: View {
    let state: UpdateState?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Decant \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            if let report = state?.lastReport {
                Text(report.message)
            }
            if let lastCheck = state?.lastCheck {
                Text("Last checked \(lastCheck.formatted(.relative(presentation: .named))).")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}
