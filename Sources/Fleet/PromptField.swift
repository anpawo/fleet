import AppKit

/// The prompt field: what the panel opens with, and what Return sends.
///
/// A plain text field and nothing else, and it is *already open* — the panel appears with the
/// caret in it, so anything you type or paste goes straight there without a key to press first.
/// That is what makes a dictation tool usable with it: its shortcut is the only thing you touch,
/// and what it pastes lands where the keyboard already is.
///
/// Fleet owns no microphone, starts no recording and drives no dictation app. It cannot tell a
/// paste from typing, and does not need to.
@MainActor
final class PromptField: ObservableObject {

    /// What will be sent. Bound straight to the field, so a paste and a keystroke are the same
    /// event as far as this is concerned.
    @Published var draft = ""

    /// Bumped whenever the field should take the keyboard back — the panel opening again, a
    /// prompt having just been sent. The view watches it rather than being told, since focus
    /// belongs to SwiftUI and only it can move the caret.
    @Published private(set) var focusRequests = 0

    /// Called with the final text when you press Return.
    var onSubmit: ((String) -> Void)?

    var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return in the field. Returns whether there was anything to send.
    @discardableResult
    func submit() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        focusRequests += 1
        guard !text.isEmpty else { return false }
        onSubmit?(text)
        return true
    }

    /// Esc on a half-written prompt, or the panel closing.
    func clear() {
        draft = ""
    }

    /// The panel is on screen again: empty field, caret in it.
    func opened() {
        draft = ""
        focusRequests += 1
    }
}
