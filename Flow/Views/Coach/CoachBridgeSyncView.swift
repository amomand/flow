import SwiftUI

/// The coach mailbox section of the Flow Coach sheet (#39).
///
/// Everything here is user initiated. Nothing uploads on its own, the connected
/// mailbox is always named on screen, and the categories that would leave the
/// device are shown and confirmed before the first sync.
struct CoachBridgeSyncView: View {
    let sync: CoachBridgeSync
    let routines: [Routine]
    let strengthWorkouts: [CompletedWorkout]
    let cardioWorkouts: [Run]
    let constraintsNotes: String

    @State private var showingPairing = false
    @State private var showingSharing = false
    @State private var showingSignOutConfirmation = false
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COACH MAILBOX")
                .terminalFont(13, weight: .bold)
                .foregroundColor(TN.cyan)

            if let pairing = sync.pairingStore.pairing {
                pairedBody(pairing)
            } else {
                unpairedBody
            }

            if let error = sync.lastSyncError {
                Text(error)
                    .terminalFont(12)
                    .foregroundColor(TN.red)
            }
            if let status = sync.statusMessage {
                Text(status)
                    .terminalFont(12)
                    .foregroundColor(TN.green)
            }
            if let pairingError = sync.pairingStore.lastError {
                Text(pairingError)
                    .terminalFont(12)
                    .foregroundColor(TN.yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingPairing) {
            CoachBridgePairingSheet(sync: sync)
        }
        .sheet(isPresented: $showingSharing) {
            CoachSharingApprovalSheet(sync: sync)
        }
        .confirmationDialog(
            "Sign out of this coach mailbox?",
            isPresented: $showingSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { sync.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flow stops syncing. Your routines, pending patches, and edit history stay on this device.")
        }
        .confirmationDialog(
            "Delete everything in this mailbox?",
            isPresented: $showingDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete remote data", role: .destructive) {
                Task { await sync.deleteAllRemoteData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every snapshot and draft this mailbox holds. Patches already in Flow's inbox stay here, and this does not touch anyone else's mailbox.")
        }
    }

    // MARK: - Unpaired

    private var unpairedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not paired. Flow Coach still works by paste, file, and link; pairing adds sync with your own coach mailbox.")
                .terminalFont(12)
                .foregroundColor(TN.comment)
            Button {
                showingPairing = true
            } label: {
                Text("[ PAIR MAILBOX ]")
            }
            .buttonStyle(TerminalButtonStyle(color: TN.blue))
        }
    }

    // MARK: - Paired

    private func pairedBody(_ pairing: CoachBridgePairing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.label)
                    .terminalFont(12, weight: .bold)
                    .foregroundColor(TN.fg)
                // The endpoint is shown alongside the label because the label is
                // only a name: the endpoint is what decides where data goes.
                Text(pairing.endpointDescription)
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
                if !pairing.isVerified {
                    // Saved while offline, so nothing has proved this address
                    // and credential work together yet (#58).
                    Text("Not checked yet: you paired while offline. The first sync will confirm it works.")
                        .terminalFont(11)
                        .foregroundColor(TN.yellow)
                }
            }

            sharingLine

            snapshotLine

            if !sync.actionableAcknowledgements.isEmpty {
                Text("\(sync.actionableAcknowledgements.count) outcome\(sync.actionableAcknowledgements.count == 1 ? "" : "s") still to report to the mailbox. Flow retries these; your local decisions are already saved.")
                    .terminalFont(11)
                    .foregroundColor(TN.yellow)
            }

            actionButtons
            secondaryButtons
        }
    }

    private var sharingLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("SHARING")
                .terminalFont(10, weight: .bold)
                .foregroundColor(TN.comment)
            Text(sharingSummary)
                .terminalFont(11)
                .foregroundColor(sharingSummaryColor)
            Spacer()
            Button {
                showingSharing = true
            } label: {
                Text("[ REVIEW ]")
                    .terminalFont(11)
                    .foregroundColor(TN.blue)
            }
            .buttonStyle(.plain)
        }
    }

    /// An approved selection wider than the recommended pair is a settled,
    /// working state, so it needs saying out loud here rather than reading as
    /// ordinary (#60). It is a different thing from needing review, and says
    /// so in different words and a different colour.
    private var sharingSummary: String {
        Self.sharingSummary(for: sync.sharingProfile.dataTiers, needsReview: sync.requiresSharingApproval)
    }

    static func sharingSummary(for tiers: [FlowCoachDataTier], needsReview: Bool) -> String {
        let names = tiers.map(tierName)
        let list = names.isEmpty ? "nothing" : names.joined(separator: ", ")
        if needsReview { return "\(list) — needs review" }
        guard !tiersBeyondRecommended(tiers).isEmpty else { return list }
        // Wider means the recommended pair plus something. A selection that
        // takes an opt-in but drops part of the pair is a different shape, not
        // a wider one, and the list already names the tiers either way.
        return coversRecommended(tiers)
            ? "\(list) — wider than recommended"
            : "\(list) — not the recommended pair"
    }

    private var sharingSummaryColor: Color {
        if sync.requiresSharingApproval { return TN.yellow }
        return Self.tiersBeyondRecommended(sync.sharingProfile.dataTiers).isEmpty ? TN.comment : TN.orange
    }

    @ViewBuilder
    private var snapshotLine: some View {
        if let snapshot = sync.lastSnapshot {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last synced \(snapshot.uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
                Text(snapshot.isExpired()
                    ? "That snapshot has expired. Sync again before asking for changes."
                    : "Expires \(snapshot.expiresAt.formatted(date: .omitted, time: .shortened))")
                    .terminalFont(11)
                    .foregroundColor(snapshot.isExpired() ? TN.yellow : TN.comment)
            }
        } else {
            Text("No snapshot in the mailbox.")
                .terminalFont(11)
                .foregroundColor(TN.comment)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                if sync.requiresSharingApproval {
                    showingSharing = true
                } else {
                    Task {
                        await sync.syncToCoach(
                            routines: routines,
                            strengthWorkouts: strengthWorkouts,
                            cardioWorkouts: cardioWorkouts,
                            constraintsNotes: constraintsNotes
                        )
                    }
                }
            } label: {
                Text("[ SYNC TO COACH ]")
            }
            .buttonStyle(TerminalButtonStyle(color: TN.green))
            .disabled(sync.isBusy)
            .opacity(sync.isBusy ? 0.45 : 1)

            Button {
                Task { await sync.pullPendingPatches() }
            } label: {
                Text("[ CHECK DRAFTS ]")
            }
            .buttonStyle(TerminalButtonStyle(color: TN.blue))
            .disabled(sync.isBusy)
            .opacity(sync.isBusy ? 0.45 : 1)
        }
    }

    private var secondaryButtons: some View {
        HStack(spacing: 10) {
            if sync.lastSnapshot != nil {
                Button {
                    Task { await sync.deleteSnapshot() }
                } label: {
                    Text("[ DELETE SNAPSHOT ]")
                        .terminalFont(11)
                        .foregroundColor(TN.yellow)
                }
                .buttonStyle(.plain)
            }
            Button {
                showingPairing = true
            } label: {
                Text("[ PAIRING ]")
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
            }
            .buttonStyle(.plain)
            Button {
                showingDeleteAllConfirmation = true
            } label: {
                Text("[ WIPE MAILBOX ]")
                    .terminalFont(11)
                    .foregroundColor(TN.red)
            }
            .buttonStyle(.plain)
            Button {
                showingSignOutConfirmation = true
            } label: {
                Text("[ SIGN OUT ]")
                    .terminalFont(11)
                    .foregroundColor(TN.comment)
            }
            .buttonStyle(.plain)
        }
    }

    /// The tiers #37 made deliberate opt-ins, in the order they escalate. Kept
    /// here rather than on the model because this is presentation: the model
    /// already carries the decision in `FlowCoachSharingProfile.recommended`.
    static let recommendedTiers: [FlowCoachDataTier] = FlowCoachSharingProfile.recommended.dataTiers

    static let escalationTiers: [FlowCoachDataTier] = FlowCoachDataTier.allCases.filter {
        !FlowCoachSharingProfile.recommended.dataTiers.contains($0)
    }

    static func tiersBeyondRecommended(_ tiers: [FlowCoachDataTier]) -> [FlowCoachDataTier] {
        escalationTiers.filter(tiers.contains)
    }

    static func isRecommendedSelection(_ tiers: Set<FlowCoachDataTier>) -> Bool {
        tiers == Set(recommendedTiers)
    }

    /// Whether the selection contains the whole recommended pair, which is what
    /// makes an opt-in on top of it a widening rather than a swap.
    static func coversRecommended(_ tiers: [FlowCoachDataTier]) -> Bool {
        Set(recommendedTiers).isSubset(of: Set(tiers))
    }

    /// The recommended tiers a selection leaves out.
    static func recommendedTiersMissing(from tiers: [FlowCoachDataTier]) -> [FlowCoachDataTier] {
        recommendedTiers.filter { !tiers.contains($0) }
    }

    static func list(_ tiers: [FlowCoachDataTier]) -> String {
        let names = tiers.map(tierName)
        guard names.count > 1 else { return names.first ?? "nothing" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    static func tierName(_ tier: FlowCoachDataTier) -> String {
        switch tier {
        case .routines: return "routines"
        case .strengthHistory: return "strength history"
        case .cardioHistory: return "cardio totals"
        case .healthMetrics: return "health metrics"
        }
    }

    static func tierDetail(_ tier: FlowCoachDataTier) -> String {
        switch tier {
        case .routines:
            return "Routine structure: sections, exercises, sets, reps, rest, notes, and phase overrides."
        case .strengthHistory:
            return "Recent strength sessions Flow recorded: dates, routine, phase, set ratings, and the adjustments Flow proposed."
        case .cardioHistory:
            return "Recent cardio totals: date, activity, distance, duration, and elevation. No routes or map data, ever."
        case .healthMetrics:
            return "Apple Health derived figures Flow already holds: heart rate averages, energy, effort, and METs. No raw samples or workout IDs."
        }
    }
}

/// Pairing, credential rotation, and mailbox switching.
private struct CoachBridgePairingSheet: View {
    let sync: CoachBridgeSync

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var endpoint = ""
    @State private var credential = ""
    @State private var problem: String?
    @State private var showingSwitchConfirmation = false
    @State private var isChecking = false

    private var isRepairing: Bool { sync.pairingStore.isPaired }

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("// MAILBOX PAIRING")
                            .terminalFont(15, weight: .bold)
                            .foregroundColor(TN.purple)
                        Spacer()
                        Button { dismiss() } label: {
                            Text("[ x ]")
                                .terminalFont(14, weight: .bold)
                                .foregroundColor(TN.comment)
                        }
                    }

                    Text("One Flow installation pairs with one mailbox. The name is just so you can tell yours apart; the address and credential decide where anything actually goes.")
                        .terminalFont(12)
                        .foregroundColor(TN.comment)

                    Text("Flow checks the address and credential against the mailbox before saving anything.")
                        .terminalFont(11)
                        .foregroundColor(TN.comment)

                    field("NAME", text: $label, placeholder: "Alex's coach mailbox")
                    // Includes the account subdomain: without it the hint reads
                    // like a complete address that does not resolve.
                    field("ADDRESS", text: $endpoint, placeholder: "your-mailbox.your-account.workers.dev")
                    field("DEVICE CREDENTIAL", text: $credential, placeholder: "paste the device secret", secure: true)

                    if let problem {
                        Text(problem)
                            .terminalFont(12)
                            .foregroundColor(TN.red)
                    }

                    if isRepairing {
                        Text("Already paired with \(sync.pairingStore.pairing?.label ?? "a mailbox"). Rotating replaces the credential only. Pairing a different address is a switch, and Flow will discard anything still owed to the old mailbox.")
                            .terminalFont(11)
                            .foregroundColor(TN.yellow)
                    }

                    HStack(spacing: 10) {
                        Button { attemptPair() } label: {
                            Text(isChecking ? "[ CHECKING… ]" : (isRepairing ? "[ SAVE ]" : "[ PAIR ]"))
                        }
                        .buttonStyle(TerminalButtonStyle(color: TN.green))
                        .disabled(isChecking)

                        if isRepairing {
                            Button { rotate() } label: {
                                Text("[ ROTATE CREDENTIAL ]")
                            }
                            .buttonStyle(TerminalButtonStyle(color: TN.blue))
                            .disabled(isChecking)
                        }
                    }
                    .opacity(isChecking ? 0.45 : 1)
                }
                .padding()
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if let pairing = sync.pairingStore.pairing {
                label = pairing.label
                endpoint = pairing.endpoint.absoluteString
            }
        }
        .confirmationDialog(
            "Switch to a different mailbox?",
            isPresented: $showingSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Switch mailbox", role: .destructive) { commitPair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(switchWarning)
        }
    }

    private var switchWarning: String {
        let owed = sync.acknowledgementsLostBySwitching()
        var lines = ["Flow will stop talking to \(sync.pairingStore.pairing?.label ?? "the current mailbox")."]
        if owed > 0 {
            lines.append("\(owed) outcome\(owed == 1 ? "" : "s") still owed to it will be discarded rather than sent to the new mailbox.")
        }
        lines.append("Local routines, patches, and history stay on this device.")
        return lines.joined(separator: " ")
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .terminalFont(10, weight: .bold)
                .foregroundColor(TN.comment)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .terminalFont(12)
            .foregroundColor(TN.fg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(TN.darkCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(TN.comment.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }

    private func attemptPair() {
        problem = nil
        if sync.pairingStore.isSwitch(to: endpoint) {
            showingSwitchConfirmation = true
        } else {
            commitPair()
        }
    }

    private func commitPair() {
        isChecking = true
        // Explicitly main-actor: this closure writes @State and calls
        // dismiss() after the await, and an unstructured Task started from a
        // nonisolated view method would otherwise resume off the main actor.
        Task { @MainActor in
            let result = await sync.pairingStore.pair(label: label, endpointText: endpoint, credential: credential)
            isChecking = false
            switch result {
            case .success(let pairing):
                // Anything owed to a previous endpoint must never be delivered here.
                sync.discardAcknowledgements(notMatching: pairing.endpoint)
                dismiss()
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    private func rotate() {
        problem = nil
        isChecking = true
        Task { @MainActor in
            let result = await sync.pairingStore.rotateCredential(credential)
            isChecking = false
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }
}

/// Shows exactly which categories would leave the device, and takes the
/// explicit approval the first sync requires.
///
/// #37 decided the tiers as an escalation, not a menu: routines and Flow's own
/// strength history are the starting point, cardio totals are a separate
/// opt-in, and health metrics are a further one. Four identical rows flattened
/// that decision and made it easy to approve more than intended (#60), so the
/// recommended pair and the additions are now different things on screen:
/// different groups, different marks, and health metrics has to be confirmed
/// against what it contains before it can go on.
private struct CoachSharingApprovalSheet: View {
    let sync: CoachBridgeSync

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<FlowCoachDataTier> = []
    @State private var confirmingEscalation: FlowCoachDataTier?

    var body: some View {
        ZStack {
            TN.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("// WHAT LEAVES THIS DEVICE")
                            .terminalFont(15, weight: .bold)
                            .foregroundColor(TN.purple)
                        Spacer()
                        Button { dismiss() } label: {
                            Text("[ x ]")
                                .terminalFont(14, weight: .bold)
                                .foregroundColor(TN.comment)
                        }
                    }

                    Text("A snapshot is uploaded only when you tap Sync to Coach, and it expires after 24 hours. Raw Apple Health samples, workout IDs, and route data never leave Flow.")
                        .terminalFont(12)
                        .foregroundColor(TN.comment)

                    recommendedGroup
                    escalationGroup
                    selectionSummary

                    Button { approve() } label: {
                        Text("[ APPROVE THESE CATEGORIES ]")
                    }
                    .buttonStyle(TerminalButtonStyle(color: TN.green))
                    .disabled(selected.isEmpty)
                    .opacity(selected.isEmpty ? 0.45 : 1)
                }
                .padding()
            }
        }
        .presentationDetents([.large])
        .onAppear { selected = Set(sync.sharingProfile.dataTiers) }
        .confirmationDialog(
            confirmingEscalation.map { "Also share \(CoachBridgeSyncView.tierName($0))?" } ?? "",
            isPresented: Binding(
                get: { confirmingEscalation != nil },
                set: { if !$0 { confirmingEscalation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tier = confirmingEscalation {
                Button("Share \(CoachBridgeSyncView.tierName(tier))") {
                    selected.insert(tier)
                    confirmingEscalation = nil
                }
                Button("Cancel", role: .cancel) { confirmingEscalation = nil }
            }
        } message: {
            if let tier = confirmingEscalation {
                // What the tier actually contains, at the moment of turning it
                // on rather than in prose further down the sheet.
                Text(CoachBridgeSyncView.tierDetail(tier))
            }
        }
    }

    // MARK: - Groups

    private var recommendedGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupHeader("RECOMMENDED", color: TN.green)
            Text("What a coach needs to work from, and the least Flow can usefully send.")
                .terminalFont(11)
                .foregroundColor(TN.comment)

            ForEach(CoachBridgeSyncView.recommendedTiers, id: \.self) { tier in
                tierRow(tier, isEscalation: false)
            }

            if !CoachBridgeSyncView.isRecommendedSelection(selected) {
                // One tap back to exactly the recommendation, so nobody has to
                // undo a row they did not knowingly select.
                Button {
                    selected = Set(CoachBridgeSyncView.recommendedTiers)
                } label: {
                    Text("[ JUST THE RECOMMENDED PAIR ]")
                        .terminalFont(11)
                        .foregroundColor(TN.green)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var escalationGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupHeader("A STEP FURTHER", color: TN.orange)
            Text("Off unless you turn them on. Each one sends a category the recommended pair does not.")
                .terminalFont(11)
                .foregroundColor(TN.comment)

            ForEach(CoachBridgeSyncView.escalationTiers, id: \.self) { tier in
                tierRow(tier, isEscalation: true)
            }
        }
    }

    private func groupHeader(_ title: String, color: Color) -> some View {
        Text("// \(title)")
            .terminalFont(12, weight: .bold)
            .foregroundColor(color)
    }

    @ViewBuilder
    private var selectionSummary: some View {
        let extra = CoachBridgeSyncView.tiersBeyondRecommended(Array(selected))
        if selected.isEmpty {
            Text("Nothing selected, so there is nothing to approve.")
                .terminalFont(11)
                .foregroundColor(TN.comment)
        } else if extra.isEmpty {
            Text(CoachBridgeSyncView.isRecommendedSelection(selected)
                ? "This is the recommended pair."
                : "Narrower than the recommended pair.")
                .terminalFont(11)
                .foregroundColor(TN.comment)
        } else if CoachBridgeSyncView.coversRecommended(Array(selected)) {
            Text("Wider than recommended: this also sends \(CoachBridgeSyncView.list(extra)).")
                .terminalFont(11)
                .foregroundColor(TN.orange)
        } else {
            // An opt-in taken while part of the recommended pair is left out.
            // Saying "wider" here would be wrong in both directions.
            Text("Not the recommended pair: this sends \(CoachBridgeSyncView.list(extra)) and leaves out \(CoachBridgeSyncView.list(CoachBridgeSyncView.recommendedTiersMissing(from: Array(selected)))).")
                .terminalFont(11)
                .foregroundColor(TN.orange)
        }
    }

    // MARK: - Rows

    private func tierRow(_ tier: FlowCoachDataTier, isEscalation: Bool) -> some View {
        let isOn = selected.contains(tier)
        let accent = isEscalation ? TN.orange : TN.green
        return Button {
            toggle(tier, isOn: isOn)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Turning on an addition is marked differently from keeping a
                // recommended row: the two are not the same act.
                Text(isOn ? (isEscalation ? "[+]" : "[x]") : "[ ]")
                    .terminalFont(12, weight: .bold)
                    .foregroundColor(isOn ? accent : TN.comment)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(CoachBridgeSyncView.tierName(tier).uppercased())
                            .terminalFont(12, weight: .bold)
                            .foregroundColor(TN.fg)
                        if isEscalation {
                            Text("OPT-IN")
                                .terminalFont(9, weight: .bold)
                                .foregroundColor(TN.orange)
                        }
                    }
                    Text(CoachBridgeSyncView.tierDetail(tier))
                        .terminalFont(11)
                        .foregroundColor(TN.comment)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .terminalCard()
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ tier: FlowCoachDataTier, isOn: Bool) {
        if isOn {
            selected.remove(tier)
        } else if tier == .healthMetrics {
            // The furthest step, and the one whose contents are least obvious
            // from its name, so it does not go on from a single tap.
            confirmingEscalation = tier
        } else {
            selected.insert(tier)
        }
    }

    private func approve() {
        // Any change of selection clears the approval inside
        // `updateSharingProfile`, so nothing can be approved that was not seen
        // in this final form.
        sync.updateSharingProfile(FlowCoachSharingProfile(dataTiers: Array(selected)))
        sync.approveSharing()
        dismiss()
    }
}
