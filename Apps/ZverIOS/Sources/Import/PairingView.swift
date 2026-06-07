import SwiftUI
import ZverTransport

/// Экран ввода 6-значного кода сопряжения с выбранным Маком.
///
/// Код показывается на Маке в окне импорта. После ввода — `POST /pair`; при
/// успехе токен сохраняется в Keychain и pairing для этого Мака больше не нужен
/// (см. `MacImportModel.select`). Сама сетевая логика — в модели; вьюха только
/// собирает ввод и отражает фазу.
struct PairingView: View {
    @ObservedObject var model: MacImportModel
    let macName: String

    @State private var code: String = ""
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Сопряжение с «\(macName)»")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Введите 6-значный код, показанный на Маке в окне импорта.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .focused($codeFieldFocused)
                .onChange(of: code) { _, newValue in
                    // Только цифры, не длиннее кода.
                    let digits = newValue.filter(\.isNumber)
                    code = String(digits.prefix(Pairing.codeLength))
                }

            if case let .failed(message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                model.submit(code: code)
            } label: {
                if isConnecting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Подключиться")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.count != Pairing.codeLength || isConnecting)

            Spacer()
        }
        .padding()
        .navigationTitle("Сопряжение")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Назад") { model.deselect() }
            }
        }
        .onAppear { codeFieldFocused = true }
    }

    private var isConnecting: Bool {
        if case .connecting = model.phase { return true }
        return false
    }
}
