import Foundation

extension WorkspaceModel {
    public func testConnection(profileID: UUID, service: DecisionService) async {
        guard !isPreview, let configuration else { return }
        do {
            guard let profile = try await store.profiles().first(where: { $0.id == profileID }) else {
                throw FalconError("profile_missing", "The connection is no longer available.")
            }
            let issued = try await configuration.createSource(name: "Falcon connection check", profileID: profileID)
            let question: JSONValue = .object([
                "type": .string("choice"), "instructions": .string("Classify this fixed input."),
                "criteria": .object([
                    "synthetic": .string("An explicitly synthetic check."), "real": .string("A real task."),
                ]),
            ])
            let input = try JSONValue.object([
                "model": .string(profile.defaultModel),
                "state": .object(["purpose": .string("Synthetic connection check"), "synthetic": .bool(true)]),
                "questions": .object(["input_kind": question]),
            ]).data()
            let reply = await service.submit(
                token: issued.token, body: input, transport: .app, metadata: ["intent": "connection_check"])
            try await configuration.revokeKey(sourceID: issued.source.id)
            var archived = issued.source
            archived.archived = true
            try await configuration.saveSource(archived)
            clearEvidenceFilters()
            sourceFilters = []
            statusFilter = nil
            reviewFilter = nil
            search = ""
            hours = 168
            page = .decisions
            await refresh(reset: true)
            if let id = reply.requestID { await select(id) }
            if reply.status != 200 {
                errorMessage =
                    reply.error?.message ?? "The upstream returned HTTP \(reply.status). Inspect the recorded response."
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
