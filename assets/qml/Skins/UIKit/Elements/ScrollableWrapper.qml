import QtQuick
import Qt5Compat.GraphicalEffects

// Emulator version of UIKit/Elements/ScrollableWrapper.qml: the same, without the OpacityMask
// layer that fades the right edge. That's a shader, which the software renderer can't draw,
// so the whole wrapped item (the deck's title and artist) went missing.

Item {
    id: scrollableWrapper

    implicitWidth: 48
    implicitHeight: 48

    required property Component itemComponent

    property bool scroll: false

    property int horizontalAlignment: Qt.AlignLeft
    property int spacing: 32

    property int pauseDuration: 3000
    property real speedMultiplier: 7.8

    readonly property bool scrolling: sequentialAnimation.running
    readonly property bool overflow: itemLoader.width > width

    clip: visible && overflow

    SequentialAnimation {
        id: sequentialAnimation

        running: scrollableWrapper.visible && scrollableWrapper.scroll && scrollableWrapper.overflow
        loops: Animation.Infinite

        onRunningChanged: {
            if (!running) {
                completeAnimation()
            }
        }

        function completeAnimation() {
            complete()
            itemLoader.resetPosition()
        }

        PauseAnimation {
            duration: scrollableWrapper.pauseDuration
        }

        NumberAnimation {
            target: itemLoader
            property: "x"
            duration: Math.max(0, itemLoader.width * speedMultiplier)
            to: -(itemLoader.width + spacing)
        }

        ScriptAction {
            script: itemLoader.resetPosition()
        }

        PauseAnimation {
            duration: scrollableWrapper.pauseDuration
        }
    }

    Item {
        id: itemContainer
        anchors.fill: parent


        Loader {
            id: itemLoader

            height: parent.height
            sourceComponent: scrollableWrapper.itemComponent

            readonly property int xPosInitial: {
                if (scrollableWrapper.overflow) {
                    return 0
                }
                if (scrollableWrapper.horizontalAlignment === Qt.AlignHCenter) {
                    return (scrollableWrapper.width - itemLoader.width) / 2
                } else if (scrollableWrapper.horizontalAlignment === Qt.AlignRight) {
                    return scrollableWrapper.width - itemLoader.width
                } else {
                    return 0
                }
            }

            function resetPosition() {
                x = Qt.binding(_ => xPosInitial)
            }
            Component.onCompleted: resetPosition()
        }

        Loader {
            id: scrollingItemLoader

            height: itemLoader.height
            x: itemLoader.x + itemLoader.width + scrollableWrapper.spacing

            active: sequentialAnimation.running
            sourceComponent: scrollableWrapper.itemComponent
        }
    }

    LinearGradient {
        id: mask

        anchors.fill: itemContainer
        visible: false

        property real fadeStartPos: 1.0 - 32 / parent.width
        property real transparentStartPos: 1.0 - 16 / parent.width

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

        gradient: scrollableWrapper.visible && scrollableWrapper.overflow ? fadeGradient : solidGradient
    }
}
