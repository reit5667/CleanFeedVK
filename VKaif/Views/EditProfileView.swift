import SwiftUI

struct EditProfileView: View {

    let token: String
    let user: VKUserDetail
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var lastName: String
    @State private var status: String

    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    private let vkApi = VKApiService()

    init(token: String, user: VKUserDetail, onSaved: @escaping () -> Void) {
        self.token = token
        self.user = user
        self.onSaved = onSaved
        _firstName = State(initialValue: user.firstName ?? "")
        _lastName  = State(initialValue: user.lastName  ?? "")
        _status    = State(initialValue: user.status    ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Имя") {
                    TextField("Имя", text: $firstName)
                        .autocorrectionDisabled()
                    TextField("Фамилия", text: $lastName)
                        .autocorrectionDisabled()
                }
                Section("Статус") {
                    TextField("Статус", text: $status)
                }
                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Редактировать профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Сохранить") { save() }
                            .disabled(isSaving)
                    }
                }
            }
        }
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let fn = firstName.trimmingCharacters(in: .whitespaces)
                let ln = lastName.trimmingCharacters(in: .whitespaces)
                let st = status.trimmingCharacters(in: .whitespaces)
                _ = try await vkApi.saveProfileInfo(
                    token: token,
                    firstName: fn.isEmpty ? nil : fn,
                    lastName:  ln.isEmpty ? nil : ln,
                    status:    st
                )
                await MainActor.run {
                    isSaving = false
                    onSaved()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
