// Stem Eye -- the one screen: the Controller address (+ a connection test), the broadcast button, what the broadcast is doing.
import SwiftUI
import ReplayKit
import Security

struct ContentView: View {
    @State private var address = ""
    @State private var rotation = -1
    @State private var maxFps = 12.0
    @State private var loaded = false
    @State private var testing = false
    @State private var testText = ""
    @State private var testOK: Bool? = nil
    @State private var saveProblem = ""
    @State private var group = ""
    @State private var status: Status? = nil
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.20", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { save(); test() }
                    Button(testing ? "Testing..." : "Test connection") { save(); test() }
                        .disabled(testing)
                    if !testText.isEmpty {
                        Label(testText, systemImage: testOK == true ? "checkmark.circle.fill" : (testOK == nil ? "clock" : "exclamationmark.triangle.fill"))
                            .foregroundColor(testOK == true ? Color.green : (testOK == nil ? Color.secondary : Color.orange))
                    }
                    if !saveProblem.isEmpty {
                        Label(saveProblem, systemImage: "exclamationmark.triangle.fill").foregroundColor(Color.orange)
                    }
                } header: {
                    Text("Controller")
                } footer: {
                    Text("The computer that runs the lighting Controller: the address in your CC link (port 8080 unless you add one). Test it once here -- iPadOS then asks to allow Local Network: say yes.")
                }

                Section {
                    HStack(spacing: 16) {
                        BroadcastButton()
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start / stop watching djay").font(.headline)
                            Text("Tap the button, choose Stem Eye, Start Broadcast. Then open djay.")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Watch djay")
                } footer: {
                    Text("Stop it with the red recording pill at the top of the screen, or in Control Center (Screen Recording, long-press).")
                }

                Section {
                    StatusRows(status: status)
                } header: {
                    Text("Broadcast")
                }

                Section {
                    Picker("Rotation", selection: $rotation) {
                        Text("Automatic").tag(-1)
                        Text("None").tag(0)
                        Text("90 degrees clockwise").tag(1)
                        Text("180 degrees").tag(2)
                        Text("90 degrees counter-clockwise").tag(3)
                    }
                    Stepper(value: $maxFps, in: 4...15, step: 1) {
                        Text("Frames a second: \(Int(maxFps))")
                    }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Leave the rotation on Automatic: it finds the right way up by itself. Fewer frames a second = less Wi-Fi, a little less precise.")
                }

                Section {
                    Text("Stem Eye sends small, shrunk pieces of djay's screen -- the deck lanes, the mixer, the transport row -- to the Controller about 12 times a second (around half a megabyte a second on your Wi-Fi). The Controller reads djay's own beat grid and the stems from them, to know the drops before they happen. Nothing is recorded or kept on the iPad.")
                        .font(.footnote)
                    Text("For it to work: djay full screen, landscape, the two-deck view with the Neural Mix lanes showing; the iPad on the same Wi-Fi as the Controller.")
                        .font(.footnote)
                    if !group.isEmpty {
                        Text("Settings shared with the broadcast through " + group).font(.caption2).foregroundColor(.secondary)
                    }
                } header: {
                    Text("How it works")
                }
            }
            .navigationTitle("Stem Eye")
        }
        .onAppear(perform: load)
        .onReceive(tick) { _ in status = Shared.status() }
        .onChange(of: rotation) { _, _ in save() }
        .onChange(of: maxFps) { _, _ in save() }
    }

    private func load() {
        if loaded { return }
        let s = Shared.settings()
        address = s.controller
        rotation = s.rotation
        maxFps = s.maxFps
        status = Shared.status()
        group = Shared.settingsGroup() ?? ""
        loaded = true
    }

    private func save() {
        if !loaded { return }
        var s = Shared.load(Settings.self, "settings") ?? Settings()
        s.controller = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.rotation != rotation { s.flip = 0 }      // a new rotation choice: forget what the automatic one learned
        s.rotation = rotation
        s.maxFps = maxFps
        let st = Shared.save(s)
        saveProblem = st == errSecSuccess ? "" : "Couldn't share the settings with the broadcast (keychain error \(st)). Rebuild with the keychain group in the entitlements."
        group = Shared.settingsGroup() ?? ""
    }

    private func test() {
        guard let base = Shared.baseURL(address) else {
            testOK = false
            testText = "Type the Controller's address first, like 192.168.1.20"
            return
        }
        testing = true
        testOK = nil
        testText = "Connecting to " + (base.host ?? "the Controller") + "..."
        let req: URLRequest = {
            var r = URLRequest(url: base.appendingPathComponent("sr/program"))
            r.timeoutInterval = 5
            r.cachePolicy = .reloadIgnoringLocalCacheData
            return r
        }()
        Task { @MainActor in
            var ok = false
            var msg = ""
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    msg = "That's a Controller without the stem reader: run build 17c or later."
                } else if code != 200 {
                    msg = "It answered \(code) -- is that the lighting Controller?"
                } else if let p = try? JSONDecoder().decode(Program.self, from: data) {
                    ok = true
                    msg = "Connected: stem reader " + p.v + ", " + String(p.tiles.count) + " pieces of the screen to send."
                } else {
                    msg = "Something answered, but not the lighting Controller."
                }
            } catch {
                msg = "Couldn't reach it: " + error.localizedDescription + " Same Wi-Fi? Local Network allowed (Settings > Stem Eye)? Controller running?"
            }
            testing = false
            testOK = ok
            testText = msg
        }
    }
}

/// what the broadcast extension last reported
struct StatusRows: View {
    let status: Status?

    var body: some View {
        if let s = status, s.state != "stopped", Date().timeIntervalSince1970 - s.at < 7 {
            row("State", stateText(s))
            if !s.detail.isEmpty { row("", s.detail) }
            row("Sending", String(format: "%.1f frames/s, %.0f KB/s (%ld sent)", s.fps, s.kbps, s.sent))
            row("Controller sees djay", s.live ? "yes" : "not yet")
            if !s.screen.isEmpty { row("Picture", s.screen + ", turned \(s.rot * 90) degrees (" + s.rotFrom + ")") }
            if !s.buffer.isEmpty { row("From ReplayKit", s.buffer) }
            if s.offMs != nil { row("Clock", String(format: "synced (round trip %.0f ms, frame times: %@)", s.rttMs ?? 0, s.clock)) }
            row("Program", s.prog)
            if s.errors > 0 { row("Errors", "\(s.errors): " + s.lastError) }
        } else {
            Text(status?.state == "stopped" ? "Stopped." : "Not broadcasting.").foregroundColor(.secondary)
            if let s = status, !s.lastError.isEmpty, s.state != "idle" {
                row("Last error", s.lastError)
            }
        }
    }

    private func stateText(_ s: Status) -> String {
        switch s.state {
        case "sending": return "sending to " + s.controller
        case "connecting": return "connecting to " + s.controller
        case "can't reach": return "can't reach " + s.controller
        case "no address": return "no Controller address"
        default: return s.state
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

/// the system's broadcast button, set to start our extension (no microphone: the Controller listens through the Pi)
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".Broadcast"
        v.showsMicrophoneButton = false
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
