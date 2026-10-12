@testable import NoodleMobile
import HubLink
import SwiftUI
import Testing

@MainActor struct MessageTableLayoutTests {
    @Test func headerBackgroundShrinksWhenTextSizeDecreases() throws {
        let table = MessageTable(header: ["Area", "Details"], alignments: [.leading, .leading],
                                 rows: [["Art", "Notebooks and coloured pencils"]])
        func content(_ size: DynamicTypeSize) -> some View {
            MessageTableGrid(table: table, sort: .constant(nil))
                .background(.white)
                .environment(\.colorScheme, .light)
                .environment(\.dynamicTypeSize, size)
        }
        let renderer = ImageRenderer(content: content(.large))
        renderer.scale = 1
        let original = try #require(renderer.cgImage)
        #expect(try red(in: original, x: 4, y: 20) < 250, "The header band must be rendered")
        #expect(try red(in: original, x: 4, y: 40) == 255, "The first row starts below the band")

        renderer.content = content(.accessibility3)
        let enlarged = try #require(renderer.cgImage)
        #expect(try red(in: enlarged, x: 4, y: 40) < 250, "Larger text makes the header taller")

        renderer.content = content(.large)
        let restored = try #require(renderer.cgImage)
        #expect(try red(in: restored, x: 4, y: 40) == 255,
                "After reducing text size, the header band must not cover the first row")
    }

    private func red(in image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return pixel[0]
    }

    @Test func wrappedRowsReserveTheirFullHeight() {
        let text = "A selection of notebooks, coloured pencils, sketchbooks, watercolour paints, brushes, folders and drawing paper"
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let cell = UIHostingController(rootView: Text(text).font(.subheadline.monospacedDigit())
                .frame(width: 240).fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, typeSize))
            let table = MessageTable(header: ["Area", "Details"], alignments: [.leading, .leading],
                                     rows: (0..<4).map { ["Row \($0)", text] })
            let grid = UIHostingController(rootView: MessageTableGrid(table: table, sort: .constant(nil))
                .environment(\.dynamicTypeSize, typeSize))
            let proposal = CGSize(width: 1000, height: 10000)
            let cellHeight = cell.sizeThatFits(in: proposal).height
            #expect(cellHeight > 30)
            #expect(grid.sizeThatFits(in: proposal).height >= 4 * (cellHeight + 16))
        }
    }
}
