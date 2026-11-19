import QtQuick 2.15
import Qt5Compat.GraphicalEffects
import Embedded

// Emulator version of UIKit/Elements/FadeScrollableText.qml: the text is shown directly instead
// of through an OpacityMask (a shader, which the software renderer can't draw).

Item {
    id: fadeScrollableText

    implicitHeight: textMetrics.height
    implicitWidth: textMetrics.width

    property int transparentWidth: 16
    property int fadeWidth: 16

    property alias text: scrollableText.text
    property alias font: scrollableText.font
    property alias color: scrollableText.color
    property alias scroll: scrollableText.scroll
    property alias horizontalAlignment: scrollableText.horizontalAlignment
    property alias textLeftMargin: scrollableText.textItemLeftMargin

    TextMetrics {
        id: textMetrics
        font: fadeScrollableText.font
        text: fadeScrollableText.text
    }

    ScrollableText {
        id: scrollableText
        anchors.fill: parent
    }

    LinearGradient {
        id: mask

        anchors.fill: scrollableText
        opacity: 0

        property real fadeStartPos: 1.0 - (parent.fadeWidth + parent.transparentWidth) / parent.width
        property real transparentStartPos: 1.0 - parent.transparentWidth / parent.width

        Gradient {
            id: solidGradient
        }

        Gradient {
            id: fadeGradient
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0.0
                color: "white"
            }
            GradientStop {
                position: mask.fadeStartPos
                color: "white"
            }
            GradientStop {
                position: mask.transparentStartPos
                color: "transparent"
            }
        }

        gradient: mask.fadeStartPos === 1.0 ? solidGradient : fadeGradient
    }

    OpacityMask {
        visible: false
        anchors.fill: parent
        source: scrollableText
        maskSource: mask
    }
}
