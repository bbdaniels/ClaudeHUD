import SwiftUI

struct PeopleView: View {
    @EnvironmentObject var contactService: ContactService
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""

    private var displayedContacts: [Contact] {
        if searchText.isEmpty {
            return contactService.allContacts
        }
        return contactService.search(query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            if contactService.allContacts.isEmpty {
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
                // Header
                HStack {
                    Text("People")
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(contactService.allContacts.count)")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                    TextField("Search contacts...", text: $searchText)
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
        }
    }
}

// MARK: - Contact Row

private struct ContactRow: View {
    let contact: Contact
    @EnvironmentObject var contactService: ContactService
    @State private var expanded = false
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 8) {
                // Source indicator
                HStack(spacing: 2) {
                    ForEach(Array(contact.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                        Image(systemName: sourceIcon(source))
                            .font(.system(size: 8 * scale))
                            .foregroundColor(sourceColor(source))
                    }
                }
                .frame(width: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name.isEmpty ? contact.email : contact.name)
                        .font(.smallFont(scale))
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

                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.4))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }

            if expanded {
                ContactDetailView(contact: contact)
                    .environmentObject(contactService)
                    .padding(.leading, 32)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
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

    private func sourceColor(_ source: ContactSource) -> Color {
        switch source {
        case .calendar: return .green
        case .email: return .blue
        case .macContacts: return .purple
        }
    }
}

// MARK: - Contact Detail (editable)

private struct ContactDetailView: View {
    let contact: Contact
    @EnvironmentObject var contactService: ContactService
    @Environment(\.fontScale) private var scale

    @State private var editedName: String = ""
    @State private var editedEmail: String = ""
    @State private var editedOrg: String = ""
    @State private var hasChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Editable fields
            EditableField(label: "Name", text: $editedName, scale: scale)
            EditableField(label: "Email", text: $editedEmail, scale: scale)
            EditableField(label: "Org", text: $editedOrg, scale: scale)

            // Source + last seen info
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Last seen \(contact.lastSeen.relativeString)")
                        .font(.custom("Fira Code", size: 9.5 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                if contact.manualOverride {
                    HStack(spacing: 2) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 9 * scale))
                        Text("edited")
                            .font(.custom("Fira Code", size: 9 * scale))
                    }
                    .foregroundColor(.orange.opacity(0.6))
                }

                Spacer()
            }

            // Save / Delete buttons
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
