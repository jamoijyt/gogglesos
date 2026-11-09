import QtQuick 2.0;
import calamares.slideshow 1.0;

// Goggles OS installer slideshow (same layout as Kubuntu's)
Presentation
{
    id: presentation

    Timer {
        interval: 12000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }
    Slide {
        Image {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: - parent.y / 3.6
            height: parent.masterHeight * 0.95
            width: parent.masterWidth * 0.95
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: "slide-1.png"
        }
    }
    Slide {
        Image {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: - parent.y / 3.6
            height: parent.masterHeight * 0.95
            width: parent.masterWidth * 0.95
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: "slide-2.png"
        }
    }
    Slide {
        Image {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: - parent.y / 3.6
            height: parent.masterHeight * 0.95
            width: parent.masterWidth * 0.95
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: "slide-3.png"
        }
    }
    Slide {
        Image {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: - parent.y / 3.6
            height: parent.masterHeight * 0.95
            width: parent.masterWidth * 0.95
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: "slide-4.png"
        }
    }
    Slide {
        Image {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: - parent.y / 3.6
            height: parent.masterHeight * 0.95
            width: parent.masterWidth * 0.95
            fillMode: Image.PreserveAspectFit
            smooth: true
            source: "slide-5.png"
        }
    }
}
