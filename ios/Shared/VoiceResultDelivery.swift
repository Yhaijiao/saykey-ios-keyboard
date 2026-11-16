import Foundation

/// Holds a final result until the keyboard is visible, then delivers it once.
struct VoiceResultDelivery {
    private var expectedID: String?
    private(set) var documentID: UUID?
    private var pending: (id: String, text: String)?
    mutating func begin(_ id: String, documentID: UUID) {
        expectedID = id; self.documentID = documentID; pending = nil
    }
    /// The keyboard was hidden and shown again while the job was running:
    /// the result now belongs to the field it reappeared in.
    mutating func rebind(documentID: UUID) {
        guard expectedID != nil, pending == nil else { return }
        self.documentID = documentID
    }
    mutating func receive(id: String, text: String) {
        guard id == expectedID, !text.isEmpty else { return }
        pending = (id, text)
    }
    mutating func take(visible: Bool, documentID: UUID) -> (id: String, text: String)? {
        guard self.documentID == documentID else { reset(); return nil }
        guard visible, let result = pending else { return nil }
        reset(); return result
    }
    mutating func reset() { expectedID = nil; documentID = nil; pending = nil }
}
