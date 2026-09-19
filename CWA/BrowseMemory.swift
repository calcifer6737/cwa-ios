import SwiftUI
import UIKit

// UI snapshots belong to one signed-in Catalog and are accessed on the main thread.
final class BrowseMemory {
    struct Page { var entries: [Entry]; var next: URL?; var scroll: String? }
    struct Groups { var entries: [Entry]; var counts: [String: Int]; var scroll: String? }
    var pages: [URL: Page] = [:]
    var groups: [String: Groups] = [:]
    let covers = NSCache<NSURL, UIImage>()
    init() { covers.totalCostLimit = 64 * 1024 * 1024 }
    func clear() { pages.removeAll(); groups.removeAll(); covers.removeAllObjects() }
}
