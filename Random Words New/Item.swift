//
//  Item.swift
//  Random Words New
//
//  Created by Artoem Liebert on 18.02.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
