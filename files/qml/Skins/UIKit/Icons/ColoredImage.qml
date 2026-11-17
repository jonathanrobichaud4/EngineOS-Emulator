import QtQuick 2.12

// Emulator version of UIKit/Icons/ColoredImage.qml. The root stays a ShaderEffect with the
// stock properties (Engine's precompiled QML expects that type), but Qt's software renderer
// can't run shaders, so the icon is drawn by a child Canvas: draw the PNG, then fill with
// `color` using source-in so the PNG's alpha is the mask.
ShaderEffect {
    id: coloredImage
    property url source
    property color color: "red"
    property bool useOriginal: false
    property alias fillMode: image.fillMode
    property alias imageStatus: image.status

    implicitWidth: src.implicitWidth
    implicitHeight: src.implicitHeight
    property variant src: Image {
        id: image
        source: coloredImage.source
    }

    Image {
        anchors.fill: parent
        source: coloredImage.source
        visible: coloredImage.useOriginal
        smooth: true
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        visible: !coloredImage.useOriginal
        property string url: coloredImage.source.toString()
        onUrlChanged: if (url !== "") loadImage(url)
        onImageLoaded: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Component.onCompleted: if (url !== "") loadImage(url)
        Connections {
            target: coloredImage
            function onColorChanged() { canvas.requestPaint() }
        }
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (url === "" || !isImageLoaded(url) || width <= 0 || height <= 0)
                return
            ctx.drawImage(url, 0, 0, width, height)
            ctx.globalCompositeOperation = "source-in"
            ctx.fillStyle = coloredImage.color
            ctx.fillRect(0, 0, width, height)
        }
    }
}
