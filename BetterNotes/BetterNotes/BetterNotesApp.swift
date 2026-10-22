//
//  BetterNotesApp.swift
//  BetterNotes
//
//  Created by Chi Khanh An Vu on 22.10.26.
//

import OSLog
import SwiftUI

@main
struct BetterNotesApp: App {
    init() {
        do {
            try LibraryLocation.documents.prepare()
        } catch {
            // Not fatal: the library screen still opens. Real error UI comes with milestone 5.
            Logger(subsystem: "com.anvu.BetterNotes", category: "setup")
                .error("Could not prepare Documents folder: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
