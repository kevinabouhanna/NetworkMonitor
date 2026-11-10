import AppKit

/// The standard About window, with what the old Settings' About pane had (#436):
/// the version, and links to the website, the release notes and the source.
///
/// AppKit draws the credits in a text view with no name, which VoiceOver reads
/// as just "text" (#494). Once the panel is up, `show()` finds that text view
/// by its text and names it.
public enum AboutPanel {

    /// What the panel shows under the version, in the current language.
    public static func credits() -> NSAttributedString {
        let credits = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func line(_ text: String, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link { attributes[.link] = URL(string: link) }
            credits.append(NSAttributedString(string: text + "\n", attributes: attributes))
        }
        line(L("Live network speed in your menu bar, and which app used your data."))
        line("")
        line(L("Website"), link: "https://kevinabouhanna.github.io/NetworkMonitor/")
        line(L("What's new"), link: "https://github.com/kevinabouhanna/NetworkMonitor/releases/latest")
        line(L("Source code"), link: "https://github.com/kevinabouhanna/NetworkMonitor")
        line("")
        line(L("Free and open source, under the Apache 2.0 licence."))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        return credits
    }

    /// What VoiceOver calls the credits text.
    public static var creditsName: String { L("Credits") }

    /// Shows the panel and names its credits text for VoiceOver.
    public static func show() {
        let credits = credits()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        // The panel is usually built by now; if AppKit fills it in on a later
        // turn of the run loop, name it then.
        if !nameCredits(credits.string) {
            DispatchQueue.main.async { nameCredits(credits.string) }
        }
    }

    /// The window the panel is in: the one whose text view shows `credits`.
    public static func window(showing credits: String = AboutPanel.credits().string) -> NSWindow? {
        NSApp.windows.first { creditsView(in: $0.contentView, showing: credits) != nil }
    }

    /// Names the text view showing `credits`, in whichever window has it.
    @discardableResult
    static func nameCredits(_ credits: String) -> Bool {
        var named = false
        for window in NSApp.windows {
            if let view = creditsView(in: window.contentView, showing: credits) {
                view.setAccessibilityLabel(creditsName)
                named = true
            }
        }
        return named
    }

    private static func creditsView(in view: NSView?, showing credits: String) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.string == credits { return text }
        for subview in view.subviews {
            if let found = creditsView(in: subview, showing: credits) { return found }
        }
        return nil
    }
}
