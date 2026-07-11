import MessageUI
import SwiftUI
import UIKit

/// Prefilled Apple Mail: the contractor only presses Send.
struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    let attachment: URL?
    @Environment(\.dismiss) private var dismiss

    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    static func quoteEmail(customer: String, company: String) -> (subject: String, body: String) {
        let subject = "Painting Quotation – \(customer)"
        let body = """
        Hi \(customer),

        Thank you for taking the time to meet with me today.

        Attached you'll find your quotation together with the visual preview of your project.

        If you have any questions or would like any changes, simply reply to this email.

        Kind regards,

        \(company)
        """
        return (subject, body)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        if !to.isEmpty { composer.setToRecipients([to]) }
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        if let attachment, let data = try? Data(contentsOf: attachment) {
            composer.addAttachmentData(
                data, mimeType: "application/pdf",
                fileName: attachment.lastPathComponent
            )
        }
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let parent: MailComposer

        init(_ parent: MailComposer) { self.parent = parent }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult, error: Error?
        ) {
            visitLog.info("Mail compose finished: \(result.rawValue)")
            parent.dismiss()
        }
    }
}

/// Exact-preview of the PDF the customer will receive (QuickLook).
import QuickLook

struct QuotePreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
