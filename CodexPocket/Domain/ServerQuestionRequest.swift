import Foundation

struct ServerQuestionRequest: Identifiable, Hashable {
    struct Prompt: Identifiable, Hashable {
        struct Option: Hashable {
            let label: String
            let detail: String
        }
        let id: String
        let header: String
        let question: String
        let isOther: Bool
        let isSecret: Bool
        let options: [Option]
    }
    let id: Int
    let requestID: String?
    let threadId: String
    let turnId: String
    let itemId: String
    let isBlocking: Bool
    let questions: [Prompt]

    init?(id: Int, requestID: String?, params: JSONDict) {
        guard let thread = params.str("threadId"), !thread.isEmpty,
              let turn = params.str("turnId"), let item = params.str("itemId"),
              let blocking = params.bool("isBlocking"),
              let raw = params["questions"] as? [JSONDict], !raw.isEmpty else { return nil }
        var prompts: [Prompt] = []
        var ids = Set<String>()
        for q in raw {
            guard let qid = q.str("id"), !qid.isEmpty, ids.insert(qid).inserted,
                  let header = q.str("header"), let text = q.str("question") else { return nil }
            let options = q.dicts("options").compactMap { option -> Prompt.Option? in
                guard let label = option.str("label"), let detail = option.str("description") else { return nil }
                return Prompt.Option(label: label, detail: detail)
            }
            if let rawOptions = q["options"] as? [Any], options.count != rawOptions.count { return nil }
            prompts.append(Prompt(id: qid, header: header, question: text,
                isOther: q.bool("isOther") ?? false, isSecret: q.bool("isSecret") ?? false, options: options))
        }
        self.id = id; self.requestID = requestID; self.threadId = thread
        self.turnId = turn; self.itemId = item; self.isBlocking = blocking; self.questions = prompts
    }

    func result(answers: [String: [String]]) -> JSONDict? {
        guard Set(answers.keys) == Set(questions.map(\.id)),
              questions.allSatisfy({ question in
                  guard let values = answers[question.id], !values.isEmpty else { return false }
                  return values.allSatisfy { value in
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      (question.options.isEmpty || question.isOther || question.options.contains { $0.label == value })
                  }
              }) else { return nil }
        return ["answers": answers.mapValues { ["answers": $0] }]
    }
}
