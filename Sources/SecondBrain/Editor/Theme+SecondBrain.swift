// Theme+SecondBrain.swift — тема превью MarkdownUI: системные цвета, а не веб.
//
// MarkdownUI из коробки предлагает `.gitHub`/`.basic`, обе — на хардкоженных
// вебовских цветах/шрифтах. Здесь — на семантических `Color(nsColor:)`
// (адаптируются к light/dark и accessibility сами), с иерархией заголовков и
// отступами, близкой к редактору (ParagraphStyling.swift) — но не пиксель-в-
// пиксель, это два разных рендер-пайплайна (NSTextView vs SwiftUI).
//
// Цвет фона код-блока/инлайн-кода — Color с .opacity, а не заранее посчитанный
// blended(NSColor) (как в редакторе): значение Color лениво резолвится SwiftUI
// на момент отрисовки под текущую тему, поэтому остаётся живым при смене
// light/dark, в отличие от единожды вычисленного static let NSColor.

import SwiftUI
import MarkdownUI

extension Theme {
    static let secondBrain: Theme = {
        let codeBackground = Color(nsColor: .quaternaryLabelColor).opacity(0.5)

        return Theme()
            .text {
                ForegroundColor(Color(nsColor: .textColor))
                FontSize(15)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(codeBackground)
            }
            .strong { FontWeight(.bold) }
            .link { ForegroundColor(Color(nsColor: .controlAccentColor)) }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.6)) }
                    .markdownMargin(top: 20, bottom: 10)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.35)) }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.15)) }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)) }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .secondaryLabelColor))
                        .relativeFrame(width: .em(0.2))
                    configuration.label
                        .markdownTextStyle { ForegroundColor(Color(nsColor: .secondaryLabelColor)) }
                        .relativePadding(.horizontal, length: .em(1))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 4, bottom: 8)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.2))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.9))
                        }
                        .padding(12)
                }
                .background(codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: 2)
            }
    }()
}
