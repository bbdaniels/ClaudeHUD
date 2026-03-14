import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var contactService: ContactService
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
    @State private var inboxEmails: [SparkEmailResult] = []

    private var displayedContacts: [Contact] {
        if searchText.isEmpty {
            return contactService.allContacts
        }
        return contactService.search(query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if contactService.allContacts.isEmpty && inboxEmails.isEmpty {
                Spacer()
                Image(systemName: "person.2")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No contacts yet")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                Text("Contacts appear as you use Today and Projects")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                Spacer()
            } else {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                    TextField("Search people...", text: $searchText)
                        .font(.smallFont(scale))
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11 * scale))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(.textBackgroundColor).opacity(0.3))

                Divider().opacity(0.3)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Inbox section
                        if !inboxEmails.isEmpty && searchText.isEmpty {
                            InboxSection(emails: inboxEmails, scale: scale)
                            Divider().opacity(0.3)
                        }

                        // Contacts
                        ForEach(displayedContacts) { contact in
                            ContactRow(contact: contact)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            contactService.refreshPublished()
            Task.detached {
                let emails = SparkService.fetchInboxEmails(limit: 10)
                await MainActor.run { inboxEmails = emails }
            }
        }
    }
}

// MARK: - Inbox Section

private struct InboxSection: View {
    let emails: [SparkEmailResult]
    let scale: CGFloat
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.4))
                        .frame(width: 10)
                    Image(systemName: "envelope")
                        .font(.system(size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Inbox")
                        .font(.captionFont(scale).weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text("\(emails.count)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.4))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)

            if expanded {
                ForEach(Array(emails.enumerated()), id: \.element.pk) { _, email in
                    InboxEmailRow(email: email, scale: scale)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Inbox Email Row (expandable with AI briefing)

private struct InboxEmailRow: View {
    let email: SparkEmailResult
    let scale: CGFloat
    @State private var expanded = false
    @State private var briefing: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                let willExpand = !expanded
                withAnimation(.easeInOut(duration: 0.15)) { expanded = willExpand }
                if willExpand && briefing == nil && !isLoading {
                    isLoading = true
                    let emailCopy = email
                    DispatchQueue.global(qos: .utility).async {
                        let result = Self.generateBriefingSync(email: emailCopy)
                        DispatchQueue.main.async {
                            briefing = result ?? "No summary available."
                            isLoading = false
                        }
                    }
                }
            }) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.4))
                        .frame(width: 10)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(email.subject)
                            .font(.captionFont(scale))
                            .foregroundColor(.primary)
                            .lineLimit(expanded ? nil : 1)
                        HStack(spacing: 4) {
                            Text(email.from)
                                .font(.custom("Fira Code", size: 9.5 * scale))
                                .foregroundColor(.secondary.opacity(0.5))
                                .lineLimit(1)
                            Text("[\(email.date)]")
                                .font(.custom("Fira Code", size: 9.5 * scale))
                                .foregroundColor(.secondary.opacity(0.4))
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .padding(.leading, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let briefing = briefing {
                        Text(briefing)
                            .font(.custom("Fira Sans", size: 11.5 * scale))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing...")
                                .font(.captionFont(scale))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
            }
        }
    }

    /// Synchronous briefing generation (call from background queue only)
    nonisolated static func generateBriefingSync(email: SparkEmailResult) -> String? {
        let priorEmails = SparkService.searchEmails(
            terms: [email.from.split(separator: " ").first.map(String.init) ?? email.from],
            limit: 5,
            includeBody: true
        )

        var context = "Current email:\nFrom: \(email.from)\nSubject: \(email.subject)\n"
        if !email.body.isEmpty { context += "Body: \(String(email.body.prefix(500)))\n" }

        if !priorEmails.isEmpty {
            context += "\nRecent email history with this person:\n"
            for prior in priorEmails where prior.pk != email.pk {
                context += "- \(prior.date): \(prior.subject)"
                if !prior.body.isEmpty { context += " — \(String(prior.body.prefix(200)))" }
                context += "\n"
            }
        }

        let prompt = """
        You're a sharp executive assistant. Based on this email and prior history, write 2-3 sentences covering:
        1. What this email is about and what's being asked/shared
        2. Relevant context from prior emails if any
        3. Suggested action (reply, follow up, archive, etc.)

        Be specific and concise. No headers or bullets — flowing sentences.

        \(context)
        """

        let claudePaths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        let claudePath = claudePaths.first { FileManager.default.fileExists(atPath: $0) } ?? "claude"

        // Write prompt to temp file, redirect output to temp file
        let tmpIn = NSTemporaryDirectory() + "claudehud-email-prompt-\(UUID().uuidString).txt"
        let tmpOut = NSTemporaryDirectory() + "claudehud-email-out-\(UUID().uuidString).txt"
        try? prompt.write(toFile: tmpIn, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: tmpIn)
            try? FileManager.default.removeItem(atPath: tmpOut)
        }

        // Use shell to handle piping properly
        let shellCmd = "\(claudePath) -p \"$(cat \(tmpIn))\" --model haiku --max-turns 1 --output-format text > \(tmpOut) 2>/dev/null"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", shellCmd]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard let output = try? String(contentsOfFile: tmpOut, encoding: .utf8) else { return nil }
            let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }
}

// MARK: - Contact Row

private struct ContactRow: View {
    let contact: Contact
    @EnvironmentObject var contactService: ContactService
    @State private var expanded = false
    @State private var editing = false
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 8) {
                // Expand chevron
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.4))
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name.isEmpty ? contact.email : contact.name)
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if !contact.org.isEmpty {
                            Text(contact.org)
                                .font(.custom("Fira Code", size: 9.5 * scale))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        if !contact.org.isEmpty && !contact.email.isEmpty {
                            Text("\u{00b7}")
                                .foregroundColor(.secondary.opacity(0.3))
                        }
                        Text(contact.email)
                            .font(.custom("Fira Code", size: 9.5 * scale))
                            .foregroundColor(.secondary.opacity(0.4))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(contact.lastSeen.relativeString)
                    .font(.custom("Fira Code", size: 9.5 * scale))
                    .foregroundColor(.secondary.opacity(0.4))

                // Edit button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        editing.toggle()
                        if editing { expanded = true }
                    }
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .help("Edit contact")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }

            if expanded {
                if editing {
                    ContactEditView(contact: contact)
                        .environmentObject(contactService)
                        .padding(.leading, 20)
                        .padding(.trailing, 4)
                        .padding(.bottom, 8)
                } else {
                    ContactInfoView(contact: contact)
                        .padding(.leading, 20)
                        .padding(.trailing, 4)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

// MARK: - Contact Info (expanded, read-only)

private struct ContactInfoView: View {
    let contact: Contact
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Sources
            HStack(spacing: 6) {
                ForEach(Array(contact.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                    HStack(spacing: 3) {
                        Image(systemName: sourceIcon(source))
                            .font(.system(size: 9 * scale))
                        Text(sourceName(source))
                            .font(.custom("Fira Code", size: 9 * scale))
                    }
                    .foregroundColor(.secondary.opacity(0.5))
                }

                Spacer()

                Text("Last seen \(contact.lastSeen.relativeString)")
                    .font(.custom("Fira Code", size: 9 * scale))
                    .foregroundColor(.secondary.opacity(0.4))
            }

            // Email threads for this person
            if !contact.email.isEmpty {
                let emails = SparkService.searchEmails(
                    terms: [contact.email.split(separator: "@").first.map(String.init) ?? contact.email],
                    limit: 3
                )
                if !emails.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent emails")
                            .font(.custom("Fira Code", size: 9 * scale))
                            .foregroundColor(.secondary.opacity(0.5))
                        ForEach(Array(emails.enumerated()), id: \.element.pk) { _, email in
                            HStack(spacing: 4) {
                                Text(email.subject)
                                    .font(.captionFont(scale))
                                    .foregroundColor(.primary.opacity(0.8))
                                    .lineLimit(1)
                                Spacer()
                                Text(email.date)
                                    .font(.custom("Fira Code", size: 9 * scale))
                                    .foregroundColor(.secondary.opacity(0.4))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func sourceIcon(_ source: ContactSource) -> String {
        switch source {
        case .calendar: return "calendar"
        case .email: return "envelope"
        case .macContacts: return "person.crop.circle"
        }
    }

    private func sourceName(_ source: ContactSource) -> String {
        switch source {
        case .calendar: return "Calendar"
        case .email: return "Email"
        case .macContacts: return "Contacts"
        }
    }
}

// MARK: - Contact Edit View

private struct ContactEditView: View {
    let contact: Contact
    @EnvironmentObject var contactService: ContactService
    @Environment(\.fontScale) private var scale

    @State private var editedName: String = ""
    @State private var editedEmail: String = ""
    @State private var editedOrg: String = ""
    @State private var hasChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EditableField(label: "Name", text: $editedName, scale: scale)
            EditableField(label: "Email", text: $editedEmail, scale: scale)
            EditableField(label: "Org", text: $editedOrg, scale: scale)

            HStack(spacing: 10) {
                if hasChanges {
                    Button(action: saveChanges) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9 * scale))
                            Text("Save")
                                .font(.captionFont(scale))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                }

                Button(action: { contactService.delete(id: contact.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 9 * scale))
                        Text("Remove")
                            .font(.captionFont(scale))
                    }
                    .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear {
            editedName = contact.name
            editedEmail = contact.email
            editedOrg = contact.org
        }
        .onChange(of: editedName) { _, _ in checkChanges() }
        .onChange(of: editedEmail) { _, _ in checkChanges() }
        .onChange(of: editedOrg) { _, _ in checkChanges() }
    }

    private func checkChanges() {
        hasChanges = editedName != contact.name || editedEmail != contact.email || editedOrg != contact.org
    }

    private func saveChanges() {
        var updated = contact
        updated.name = editedName
        updated.email = editedEmail
        updated.org = editedOrg
        updated.manualOverride = true
        contactService.update(updated)
        hasChanges = false
    }
}

private struct EditableField: View {
    let label: String
    @Binding var text: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.custom("Fira Code", size: 9.5 * scale))
                .foregroundColor(.secondary.opacity(0.5))
                .frame(width: 36, alignment: .trailing)
            TextField(label, text: $text)
                .font(.captionFont(scale))
                .textFieldStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlBackgroundColor))
                )
        }
    }
}
