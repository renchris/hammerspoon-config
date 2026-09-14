// bench/winprobe.swift — the bench's ONE native helper: a falsifier, a pointer, an idle clock and
// a pasteboard custodian.  It is started once per run and driven over stdin, because a process per
// sample would cost more than the thing being measured.
//
// 🚨 THE WINDOW PROBE IS A FALSIFIER, NEVER A CLOCK.  `phase=thumb-visible` is emitted IN PROCESS
// by Hammerspoon from hs.canvas:isOccluded(), which is the window server's own answer.  This prober
// exists to CONTRADICT that line if it is wrong, and its own scheduling gap reaches 89 ms under
// bench load — so run.py treats a disagreement > 100 ms as a failed iteration and never subtracts
// these timestamps to produce a latency.
//
// 🚨 kCGWindowIsOnscreen MEANS "ORDERED IN", NOT "ON A DISPLAY".  A canvas parked at (4000,4000)
// reports onscreen = true.  Visibility here is therefore geometric: the fraction of the window's
// bounds that intersects the union of the displays, ≥ 0.10.
//
// Protocol: one command per line on stdin, one JSON object per line on stdout.
//   probe            -> {"t":<mono ns>,"visible":bool,"frac":f,"n":windows,"bounds":[x,y,w,h]}
//   pointer          -> {"t":...,"x":f,"y":f}
//   idle             -> {"t":...,"idle":seconds}
//   ccount           -> {"t":...,"cc":n}
//   pngsha           -> {"t":...,"len":n,"sha1":"..."}  (public.png on the general pasteboard)
//   snapshot <path>  -> {"ok":bool,"items":n,"types":[...]}   refuses a multi-item board
//   restore <path>   -> {"ok":bool,"types":[...],"lens":[...]}
//   quit             -> exits

import Foundation
import AppKit
import CoreGraphics
import CryptoKit

let out = FileHandle.standardOutput

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: []) {
        out.write(d); out.write("\n".data(using: .utf8)!)
    }
}

func monoNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Display rectangles in CoreGraphics coordinates (origin top-left of the primary display).
func displayRects() -> [CGRect] {
    guard let primary = NSScreen.screens.first else { return [] }
    let h = primary.frame.height
    return NSScreen.screens.map { s in
        CGRect(x: s.frame.origin.x, y: h - s.frame.origin.y - s.frame.height,
               width: s.frame.width, height: s.frame.height)
    }
}

/// Hammerspoon's thumbnail canvas: owner "Hammerspoon", window layer 3 ("floating").
func probe() -> [String: Any] {
    let t = monoNs()
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else {
        return ["t": t, "visible": false, "frac": 0.0, "n": 0]
    }
    let rects = displayRects()
    var best = 0.0
    var bestBounds: [CGFloat] = []
    var n = 0
    for info in infos {
        guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "Hammerspoon",
              let layer = info[kCGWindowLayer as String] as? Int, layer == 3,
              let bdict = info[kCGWindowBounds as String] as? [String: CGFloat],
              let b = CGRect(dictionaryRepresentation: bdict as CFDictionary) else { continue }
        n += 1
        let area = b.width * b.height
        if area <= 0 { continue }
        var inter = 0.0
        for r in rects {
            let i = r.intersection(b)
            if !i.isNull { inter += Double(i.width * i.height) }
        }
        let frac = inter / Double(area)
        if frac > best { best = frac; bestBounds = [b.origin.x, b.origin.y, b.width, b.height] }
    }
    return ["t": t, "visible": best >= 0.10, "frac": best, "n": n, "bounds": bestBounds]
}

func snapshot(_ path: String) -> [String: Any] {
    let pb = NSPasteboard.general
    let items = pb.pasteboardItems ?? []
    // readAllData / a single-item restore preserves only the first item, so a multi-item board
    // cannot be restored faithfully and the bench must refuse to touch it at all.
    if items.count > 1 {
        return ["ok": false, "items": items.count, "error": "multi-item pasteboard; refusing to run"]
    }
    var dict: [String: String] = [:]
    var types: [String] = []
    if let item = items.first {
        for t in item.types {
            if let d = item.data(forType: t) {
                dict[t.rawValue] = d.base64EncodedString()
                types.append(t.rawValue)
            }
        }
    }
    let payload: [String: Any] = ["changeCount": pb.changeCount, "data": dict]
    guard let d = try? PropertyListSerialization.data(fromPropertyList: payload,
                                                      format: .binary, options: 0),
          (try? d.write(to: URL(fileURLWithPath: path))) != nil else {
        return ["ok": false, "items": items.count, "error": "cannot write \(path)"]
    }
    return ["ok": true, "items": items.count, "types": types]
}

func restore(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil),
          let payload = plist as? [String: Any],
          let data = payload["data"] as? [String: String] else {
        return ["ok": false, "error": "cannot read \(path)"]
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    if data.isEmpty { return ["ok": true, "types": [], "lens": []] }
    let item = NSPasteboardItem()
    var types: [String] = []
    var lens: [Int] = []
    for (t, b64) in data {
        guard let bytes = Data(base64Encoded: b64) else { continue }
        item.setData(bytes, forType: NSPasteboard.PasteboardType(t))
        types.append(t); lens.append(bytes.count)
    }
    let ok = pb.writeObjects([item])
    return ["ok": ok, "types": types, "lens": lens]
}

func pngsha() -> [String: Any] {
    let t = monoNs()
    let pb = NSPasteboard.general
    guard let d = pb.data(forType: NSPasteboard.PasteboardType("public.png")) else {
        return ["t": t, "len": 0, "sha1": ""]
    }
    let digest = Insecure.SHA1.hash(data: d)
    return ["t": t, "len": d.count, "sha1": digest.map { String(format: "%02x", $0) }.joined()]
}

while let line = readLine(strippingNewline: true) {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let arg = parts.count > 1 ? parts[1] : ""
    switch cmd {
    case "probe":   emit(probe())
    case "pointer":
        let p = CGEvent(source: nil)?.location ?? .zero
        emit(["t": monoNs(), "x": p.x, "y": p.y])
    case "idle":
        let s = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
        emit(["t": monoNs(), "idle": s])
    case "ccount":  emit(["t": monoNs(), "cc": NSPasteboard.general.changeCount])
    case "pngsha":  emit(pngsha())
    case "snapshot": emit(snapshot(arg))
    case "restore":  emit(restore(arg))
    case "quit":    exit(0)
    default:        emit(["error": "unknown command: \(cmd)"])
    }
}
