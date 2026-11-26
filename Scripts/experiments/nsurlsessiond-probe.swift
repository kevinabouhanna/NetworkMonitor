import AppKit
import Foundation

final class Probe: NSObject, NSApplicationDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var downloadedBytes: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2,
              let url = URL(string: CommandLine.arguments[1]),
              url.scheme == "http", url.host == "127.0.0.1",
              let bundle = Bundle.main.bundleIdentifier else {
            exit(2)
        }

        let configuration = URLSessionConfiguration.background(withIdentifier: bundle)
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            return
        }
        downloadedBytes = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard error == nil, let downloadedBytes else {
            fputs("Background download failed: \(String(describing: error))\n", stderr)
            exit(1)
        }

        print(downloadedBytes)
        NSApplication.shared.terminate(nil)
    }
}

let application = NSApplication.shared
let probe = Probe()
application.delegate = probe
application.setActivationPolicy(.accessory)
withExtendedLifetime(probe) { application.run() }
