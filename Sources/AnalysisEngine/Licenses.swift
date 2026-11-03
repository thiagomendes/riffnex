import Foundation

/// Third-party notices shown in the app's About screen.
public enum Licenses {
    public struct Notice: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let use: String
        public let text: String
    }

    public static var all: [Notice] {
        [
            Notice(name: "Demucs (htdemucs_6s)", use: "Separação dos instrumentos", text: demucsMIT),
            Notice(name: "Basic Pitch", use: "Leitura das notas da guitarra", text: basicPitch),
        ]
    }

    static var basicPitch: String {
        let folder = "BasicPitch"
        func read(_ name: String) -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: folder),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return text
        }
        return [read("NOTICE"), read("LICENSE")].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static let demucsMIT = """
    MIT License

    Copyright (c) Meta Platforms, Inc. and affiliates.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
