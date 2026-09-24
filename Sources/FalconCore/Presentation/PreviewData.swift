import Foundation

public enum PreviewData {
    public static let profileID = UUID(uuidString: "FACA0000-0000-0000-0000-000000000001")!
    public static let sources = ["Codex", "Grok", "Pi", "Claude"].enumerated().map { index, name in
        AgentSource(
            id: UUID(uuidString: String(format: "FACA0000-0000-0000-0000-%012d", index + 10))!, name: name,
            profileID: profileID)
    }

    public static func records(now: Date = Date()) throws -> [RequestDetail] {
        let request = try JSONValue.decode(
            Data(
                #"""
                {
                  "model": "jev-latest",
                  "state": {
                    "task": "Review the changes to the decision pipeline",
                    "proposed_action": "Inspect the request boundary, then run the focused tests.",
                    "facts": [
                      "The change touches one isolated module.",
                      "The public interface stays the same.",
                      "A local fixture covers all three question types."
                    ],
                    "constraints": [
                      "Preserve unknown JSON fields.",
                      "Do not retry an inference automatically.",
                      "Record the result before returning it."
                    ],
                    "available_runners": ["local", "delegate", "ask_user"]
                  },
                  "questions": {
                    "execution_mode": {
                      "type": "choice",
                      "instructions": "Choose the most effective way to complete this task, given the scope and available evidence.",
                      "criteria": {
                        "local": "One bounded task with enough context to complete directly.",
                        "delegate": "Independent subtasks would benefit from parallel investigation.",
                        "ask_user": "A missing requirement prevents a correct next step."
                      }
                    },
                    "next_step": {
                      "type": "choice",
                      "instructions": "What should the agent do next?",
                      "criteria": {
                        "proceed": "The proposed action is justified by the available evidence.",
                        "inspect_first": "Resolve an important unknown before making changes.",
                        "simplify": "A smaller action can fully satisfy the requirement."
                      }
                    },
                    "needs_review": {
                      "type": "noul",
                      "instructions": "Does this change require additional human review?",
                      "criteria": {"true": "Material uncertainty remains.", "false": "The scope and evidence are sufficient."}
                    }
                  }
                }
                """#.utf8))
        let response = try JSONValue.decode(
            Data(
                #"""
                {"model":"jev-1.13.0","answers":{
                  "execution_mode":{"type":"choice","choice":"local","probabilities":{"local":0.86,"delegate":0.11,"ask_user":0.03},"confidence":0.72},
                  "next_step":{"type":"choice","choice":"proceed","probabilities":{"proceed":0.78,"inspect_first":0.18,"simplify":0.04},"confidence":0.59},
                  "needs_review":{"type":"noul","noul":0.12}
                },"usage":{"input_tokens":824,"output_tokens":76}}
                """#.utf8))
        return try (0..<40).map { index in
            let source = sources[index % sources.count]
            let receivedAt = now.addingTimeInterval(-Double(index * 147 + 30))
            var summary = RequestSummary(
                sourceID: source.id, keyID: source.id, sourceName: source.name, profileID: profileID,
                profileName: "TypeSafe", transport: index % 3 == 0 ? .mcp : .http, receivedAt: receivedAt,
                status: index == 5 || index == 17 ? .timedOut : .succeeded)
            let latency = Double(782 + (index * 47) % 1400)
            summary.timing = RequestTiming(
                bodyReceivedMS: 2.4, upstreamStartedMS: 8.2,
                responseReceivedMS: summary.status == .succeeded ? latency : nil,
                terminalMS: summary.status == .succeeded ? latency + 3 : 30_000,
                deliveryFinishedMS: summary.status == .succeeded ? latency + 7 : 30_005)
            summary.delivery = .written
            summary.resolvedModel = "jev-1.13.0"
            summary.inputTokens = summary.status == .succeeded ? 824 : nil
            summary.outputTokens = summary.status == .succeeded ? 76 : nil
            summary.questionCount = 3
            summary.preview = summary.status == .succeeded ? "local" : "Upstream deadline exceeded"
            summary.metadata = ["project": "falcon", "agent": source.name, "run_id": "preview-\(index / 4)"]
            summary.reviewState = index % 7 == 3 ? .flagged : index % 3 == 1 ? .reviewed : .unreviewed
            summary.httpStatus = summary.status == .succeeded ? 200 : 504
            summary.errorMessage =
                summary.status == .succeeded
                ? nil : "The upstream request exceeded its 30 second deadline. The outcome may be unknown."
            return RequestDetail(
                summary: summary, receivedRequest: try request.data(), effectiveRequest: try request.data(),
                upstreamResponse: summary.status == .succeeded ? try response.data() : nil)
        }
    }
}
