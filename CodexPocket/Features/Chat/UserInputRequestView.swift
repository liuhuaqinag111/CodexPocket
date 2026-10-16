import SwiftUI

struct UserInputRequestView: View {
    @EnvironmentObject var store: AppCoordinator
    let request: ServerQuestionRequest
    @State private var selections: [String: String] = [:]
    @State private var freeText: [String: String] = [:]
    private let other = "__other__"

    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: request.questions.map { question in
            let selection = selections[question.id] ?? ""
            let value = question.options.isEmpty || selection == other
                ? freeText[question.id] ?? "" : selection
            return (question.id, [value])
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.isBlocking ? "需要你回答" : "补充信息")
                .font(Palette.F.title).foregroundStyle(Palette.text)
            ForEach(request.questions) { question in
                prompt(question)
            }
            Button("提交回答") { store.answerUserInput(request, answers: answers) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Palette.buttonBg)
                .foregroundStyle(Palette.iconInverted)
                .disabled(request.result(answers: answers) == nil || !store.state.isReady)
                .accessibilityIdentifier("userInput.submit")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Palette.R.card).fill(Palette.elevated))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("userInput.request")
    }

    @ViewBuilder private func prompt(_ question: ServerQuestionRequest.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header).font(Palette.F.caption).foregroundStyle(Palette.textSub)
            }
            Text(question.question).font(Palette.F.body).foregroundStyle(Palette.text)
            ForEach(question.options, id: \.label) { option in
                Button { selections[question.id] = option.label } label: {
                    HStack(alignment: .top, spacing: 8) {
                        LucideIcon(selections[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label).font(Palette.F.note)
                            if !option.detail.isEmpty {
                                Text(option.detail).font(Palette.F.caption).foregroundStyle(Palette.textSub)
                            }
                        }
                    }
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(option.label + (option.detail.isEmpty ? "" : "，" + option.detail))
                .accessibilityAddTraits(selections[question.id] == option.label ? .isSelected : [])
                .accessibilityIdentifier("userInput.option." + question.id)
            }
            if question.isOther && !question.options.isEmpty {
                Button("其他") { selections[question.id] = other }
                    .foregroundStyle(Palette.accentText).frame(minHeight: 44)
            }
            if question.options.isEmpty || selections[question.id] == other {
                let binding = Binding(get: { freeText[question.id] ?? "" },
                                      set: { freeText[question.id] = $0 })
                Group {
                    if question.isSecret {
                        SecureField("输入回答", text: binding)
                    } else {
                        TextField("输入回答", text: binding, axis: .vertical).lineLimit(2...6)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel(question.question)
                .accessibilityIdentifier("userInput.answer." + question.id)
            }
        }
    }
}
