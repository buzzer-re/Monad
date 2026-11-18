//
//  GuestCursor.swift — how the Mac's pointer looks over a Linux program's
//  window (LinuxAppWindows.swift).
//
//  The program says it by name (wp_cursor_shape_v1: "text", "pointer",
//  "ew-resize"), the VM's window manager passes the name's number on, and
//  the Mac draws its own cursor for it: an I-beam over text, a hand over a
//  link. No picture comes from the VM. A program that draws a cursor of
//  its own gets the arrow; one that asks for none (a terminal while one
//  types) gets none, over its own window only.
//

import AppKit

enum GuestCursor: Equatable {
    /// What a window's edge or a divider is dragged by.
    enum Resize: Equatable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        case leftRight, upDown, rising, falling, column, row
    }

    case hidden, arrow, contextMenu, pointingHand, crosshair, text, verticalText
    case alias, copy, notAllowed, openHand, closedHand, zoomIn, zoomOut
    case resize(Resize)

    /// The last of wp_cursor_shape_device_v1's shapes (mwm_server.h's MWM_CURSOR_LAST).
    static let lastShape = 36

    /// From the number the window manager says: 0 hidden, then the
    /// protocol's shapes. The arrow for the ones the Mac has no cursor of
    /// its own for (help, wait), and for a number that is no shape.
    init(shape: Int) {
        switch shape {
        case 0: self = .hidden
        case 2: self = .contextMenu
        case 4: self = .pointingHand
        case 7, 8: self = .crosshair
        case 9: self = .text
        case 10: self = .verticalText
        case 11: self = .alias
        case 12: self = .copy
        case 14, 15: self = .notAllowed
        case 13, 16, 32: self = .openHand // move, grab, scroll any way
        case 17: self = .closedHand
        case 18: self = .resize(.right)
        case 19: self = .resize(.top)
        case 20: self = .resize(.topRight)
        case 21: self = .resize(.topLeft)
        case 22: self = .resize(.bottom)
        case 23: self = .resize(.bottomRight)
        case 24: self = .resize(.bottomLeft)
        case 25: self = .resize(.left)
        case 26: self = .resize(.leftRight)
        case 27: self = .resize(.upDown)
        case 28: self = .resize(.rising)
        case 29: self = .resize(.falling)
        case 30: self = .resize(.column)
        case 31: self = .resize(.row)
        case 33: self = .zoomIn
        case 34: self = .zoomOut
        default: self = .arrow
        }
    }

    /// No pointer: a picture with nothing in it.
    @MainActor private static let none = NSCursor(image: NSImage(size: NSSize(width: 16, height: 16)), hotSpot: .zero)

    @MainActor var mac: NSCursor {
        switch self {
        case .hidden: return Self.none
        case .arrow: return .arrow
        case .contextMenu: return .contextualMenu
        case .pointingHand: return .pointingHand
        case .crosshair: return .crosshair
        case .text: return .iBeam
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .alias: return .dragLink
        case .copy: return .dragCopy
        case .notAllowed: return .operationNotAllowed
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .zoomIn:
            if #available(macOS 15.0, *) { return .zoomIn }
            return .arrow
        case .zoomOut:
            if #available(macOS 15.0, *) { return .zoomOut }
            return .arrow
        case .resize(let resize):
            if #available(macOS 15.0, *) { return Self.resizing(resize) }
            return Self.resizingBefore15(resize)
        }
    }

    @available(macOS 15.0, *)
    @MainActor private static func resizing(_ resize: Resize) -> NSCursor {
        switch resize {
        case .left: return .frameResize(position: .left, directions: .all)
        case .right, .leftRight: return .frameResize(position: .right, directions: .all)
        case .top, .upDown: return .frameResize(position: .top, directions: .all)
        case .bottom: return .frameResize(position: .bottom, directions: .all)
        case .topLeft, .falling: return .frameResize(position: .topLeft, directions: .all)
        case .topRight, .rising: return .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        case .column: return .columnResize
        case .row: return .rowResize
        }
    }

    /// macOS 14 has no cursor for a corner: the arrow there.
    @MainActor private static func resizingBefore15(_ resize: Resize) -> NSCursor {
        switch resize {
        case .left: return .resizeLeft
        case .right: return .resizeRight
        case .top: return .resizeUp
        case .bottom: return .resizeDown
        case .leftRight, .column: return .resizeLeftRight
        case .upDown, .row: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .rising, .falling: return .arrow
        }
    }
}
