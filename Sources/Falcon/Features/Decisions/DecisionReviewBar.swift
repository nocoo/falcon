import FalconCore
import SwiftUI

struct DecisionReviewBar: View {
    @Bindable var model: WorkspaceModel
    let record: RequestSummary
    @State private var showingNote = false

    var body: some View {
        HStack(spacing: FalconTheme.Space.compact) {
            Button {
                model.editReview(model.reviewState == .flagged ? .unreviewed : .flagged)
                Task { await model.saveReview() }
            } label: {
                Image(systemName: model.reviewState == .flagged ? "flag.fill" : "flag").foregroundStyle(
                    model.reviewState == .flagged ? FalconTheme.flag : FalconTheme.secondary)
            }.buttonStyle(FalconButtonStyle(compact: true)).help("Toggle needs attention").accessibilityLabel(
                model.reviewState == .flagged ? "Remove flag" : "Flag for attention")
            Button {
                showingNote.toggle()
            } label: {
                Label(model.note.isEmpty ? "Note" : "Note added", systemImage: "text.bubble")
            }.buttonStyle(FalconButtonStyle(compact: true)).popover(isPresented: $showingNote, arrowEdge: .top) {
                noteEditor
            }
            Spacer(minLength: FalconTheme.Space.compact)
            if let message = model.triageMessage {
                Text("No next unread").font(FalconTheme.caption).foregroundStyle(FalconTheme.secondary).help(message)
            }
            if model.reviewState == .reviewed {
                Label("Reviewed", systemImage: "checkmark.circle.fill").font(FalconTheme.caption).foregroundStyle(
                    FalconTheme.success)
                Button {
                    model.editReview(.unreviewed)
                    Task { await model.saveReview() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }.buttonStyle(.plain).foregroundStyle(FalconTheme.secondary).help("Mark as unread").accessibilityLabel(
                    "Mark as unread")
            } else if model.reviewState == .flagged {
                Text("Needs attention").font(FalconTheme.caption).foregroundStyle(FalconTheme.warning)
            }
            Button {
                Task { await model.triage() }
            } label: {
                Label(
                    model.isTriaging ? "Saving…" : model.reviewState == .reviewed ? "Next unread" : "Review & next",
                    systemImage: model.reviewState == .reviewed ? "arrow.down" : "checkmark")
            }.buttonStyle(FalconButtonStyle(prominent: true, compact: true)).keyboardShortcut(
                .return, modifiers: .command
            ).disabled(model.triageMessage != nil).help("Mark reviewed and open the next unread decision · ⌘Return")
        }.disabled(model.isTriaging || model.isUpdatingStar || model.isSelecting).padding(
            .horizontal, FalconTheme.Space.section
        ).frame(height: FalconTheme.Layout.reviewBarHeight).background(FalconTheme.surface).overlay(alignment: .top) {
            Rectangle().fill(FalconTheme.line).frame(height: FalconTheme.hairline)
        }.onChange(of: record.id) { _, _ in showingNote = false }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: FalconTheme.Space.regular) {
            Text("Review note").font(FalconTheme.sectionTitle)
            TextEditor(text: Binding(get: { model.note }, set: model.editNote)).font(FalconTheme.body)
                .scrollContentBackground(.hidden).padding(FalconTheme.Space.compact).frame(
                    height: FalconTheme.Layout.noteEditorHeight
                ).background(FalconTheme.inset, in: RoundedRectangle(cornerRadius: FalconTheme.Radius.control))
                .accessibilityLabel("Review note")
            HStack {
                Text(model.noteIsDirty ? "Unsaved changes" : "Saved on this Mac").font(FalconTheme.footnote)
                    .foregroundStyle(FalconTheme.secondary)
                Spacer()
                Button("Done") {
                    Task {
                        await model.saveReview()
                        if !model.noteIsDirty { showingNote = false }
                    }
                }.buttonStyle(FalconButtonStyle(prominent: true, compact: true))
            }
        }.padding(FalconTheme.Space.medium).frame(width: FalconTheme.Layout.notePopoverWidth).foregroundStyle(
            FalconTheme.ink)
    }
}
