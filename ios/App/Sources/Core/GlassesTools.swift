import Foundation
import RealtimeVoice

/// Camera actions Gemini Live may request while talking to the wearer.
/// These are deliberately narrow: Gemini can inspect/capture the glasses view,
/// but cannot access unrelated photos or device data.
enum GlassesTools {
    static let all: [RealtimeTool] = [look, takePhoto, startCamera, stopCamera, endSession]

    static let instructionsAddendum = """
    You control the wearer's Ray-Ban Meta glasses camera by voice:
    - When the wearer asks to turn on the camera, start the camera, open the camera, or use the glasses camera, IMMEDIATELY call glasses_start_camera.
    - When the wearer asks to turn off the camera, stop the camera, or close the camera, IMMEDIATELY call glasses_stop_camera.
    - For visual questions such as "what is in front of me?", "what do you see?", "look at this", or "read this", call glasses_look first, then answer from the image.
    - Call glasses_take_photo when the wearer explicitly asks to take a photo or snapshot.
    - When the wearer says "stop listening", "end session", "goodbye", or "go to sleep", call glasses_end_session.
    """

    static let look = RealtimeTool(
        name: "glasses_look",
        description: "Capture a fresh image from the wearer's glasses camera and inspect it before answering a visual question.",
        parametersJSON: #"{"type":"object","properties":{"question":{"type":"string","description":"What the wearer wants identified or described"}}}"#
    )

    static let takePhoto = RealtimeTool(
        name: "glasses_take_photo",
        description: "Take a fresh photo from the wearer's glasses camera when explicitly requested.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )

    static let startCamera = RealtimeTool(
        name: "glasses_start_camera",
        description: "Turn ON and start streaming the wearer's live glasses camera when the wearer asks to turn on, start, open, or use the camera.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )

    static let stopCamera = RealtimeTool(
        name: "glasses_stop_camera",
        description: "Turn OFF and stop the wearer's live glasses camera stream when the wearer asks to turn off, stop, or close the camera.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )

    static let endSession = RealtimeTool(
        name: "glasses_end_session",
        description: "End the current Live AI voice session and return to wake-word standby when the wearer asks to stop listening, end the session, or says goodbye.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )
}
