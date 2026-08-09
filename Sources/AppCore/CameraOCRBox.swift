import AVFoundation
import AppDomain
import Foundation
import ReactiveConcurrency
import Vision

/// The camera and the text recognizer, in one box behind the World.
///
/// Nothing past the World knows AVFoundation or Vision exist: the app subscribes to a stream of
/// `[String]` — whatever text the camera can read in each analysed frame — and the domain's own
/// arithmetic decides which frames contain a pump and which an odometer. Subscribing starts the
/// session (after asking permission); cancelling the subscription stops it, so the camera runs
/// exactly as long as someone is watching and not a frame longer.
///
/// Frames are analysed at ~4 per second rather than every one of the 30 the camera offers:
/// seven-segment digits do not change faster than that, and `.accurate` recognition on every
/// frame would cook the phone in a jacket pocket's worth of battery.
final class CameraOCRBox: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var listeners: [UUID: AsyncStream<[AppDomain.RecognizedText]>.Continuation] = [:]
    private var lastAnalysis = Date.distantPast
    private let analysisQueue = DispatchQueue(label: "camera-ocr")

    /// The recognized text of each analysed frame — string and position both, because "which
    /// grade label sits beside the winning price" is a geometric question — as a cold stream.
    /// The first subscriber starts the camera; the last one leaving stops it.
    var recognizedText: Publisher<[AppDomain.RecognizedText], Never> {
        Publisher { [weak self] continuation in
            guard let self else { return }
            let (stream, streamContinuation) = AsyncStream<[AppDomain.RecognizedText]>.makeStream()
            let id = UUID()
            let isFirst = self.lock.withLock {
                self.listeners[id] = streamContinuation
                return self.listeners.count == 1
            }
            if isFirst { self.start() }
            await continuation.yieldAll(stream)   // parks until cancelled
            let isLast = self.lock.withLock {
                self.listeners.removeValue(forKey: id)
                return self.listeners.isEmpty
            }
            if isLast { self.stop() }
        }
    }

    /// Ends every open stream, which unwinds each subscription and — once the last one is gone —
    /// stops the camera. The deterministic "the scan is over" switch, so the session's lifetime
    /// is a store decision rather than a view accident.
    func finishAll() {
        let current = lock.withLock { Array(listeners.values) }
        for continuation in current { continuation.finish() }
    }

    /// The live viewfinder, for the scan screen to embed. `nil` until the session exists.
    ///
    /// A `CALayer` is a view-layer handle and this is the one place the World hands one out —
    /// a viewfinder *is* pixels, and pretending otherwise would just move the layer behind a
    /// wrapper with the same shape.
    @MainActor
    func previewLayer() -> AVCaptureVideoPreviewLayer? {
        let layer = AVCaptureVideoPreviewLayer(session: ensureSession())
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    /// The session, the moment anyone needs it. Creating the object is synchronous and cheap;
    /// the expensive parts — permission, configuration, `startRunning` — stay on their queues.
    ///
    /// This is the first-open black screen, fixed: the viewfinder used to be handed `nil`
    /// whenever it asked before the async setup had finished, and a layer with no session stays
    /// black however long you stare at it. A layer attached to a not-yet-running session shows
    /// frames the instant they exist instead.
    private func ensureSession() -> AVCaptureSession {
        lock.withLock {
            if let session { return session }
            let fresh = AVCaptureSession()
            session = fresh
            return fresh
        }
    }

    private func start() {
        let session = ensureSession()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.analysisQueue.async {
                // A session configured by a previous scan just starts again — keeping it is what
                // makes the second open instant, and configuring twice would double the inputs.
                guard session.inputs.isEmpty else {
                    session.startRunning()
                    return
                }
                session.beginConfiguration()
                session.sessionPreset = .hd1280x720
                guard
                    let camera = AVCaptureDevice.default(
                        .builtInWideAngleCamera, for: .video, position: .back
                    ),
                    let input = try? AVCaptureDeviceInput(device: camera),
                    session.canAddInput(input)
                else {
                    session.commitConfiguration()
                    return
                }
                session.addInput(input)
                // Pump displays and odometers live in the forecourt's shade; the torch on auto
                // costs nothing in daylight and is the difference at dusk.
                if camera.hasTorch, (try? camera.lockForConfiguration()) != nil {
                    camera.torchMode = .auto
                    camera.unlockForConfiguration()
                }

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.analysisQueue)
                if session.canAddOutput(output) {
                    session.addOutput(output)
                }
                session.commitConfiguration()
                session.startRunning()
            }
        }
    }

    private func stop() {
        // The session outlives the scan — stopped, not discarded — so the next open reuses the
        // configured pipeline instead of racing a rebuild.
        let current = lock.withLock { session }
        analysisQueue.async {
            current?.stopRunning()
        }
    }
}

extension CameraOCRBox: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The throttle: the display being filmed does not change 30 times a second.
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= 0.25 else { return }
        lastAnalysis = now

        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self else { return }
            let texts = (request.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { observation -> AppDomain.RecognizedText? in
                    observation.topCandidates(1).first.map {
                        AppDomain.RecognizedText(
                            text: $0.string,
                            x: observation.boundingBox.midX,
                            y: observation.boundingBox.midY,
                            width: observation.boundingBox.width,
                            height: observation.boundingBox.height
                        )
                    }
                }
            let current = self.lock.withLock { Array(self.listeners.values) }
            for listener in current { listener.yield(texts) }
        }
        request.recognitionLevel = .accurate
        // Seven-segment digits are not words; correction "fixes" them into dates and phone numbers.
        request.usesLanguageCorrection = false

        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right)
            .perform([request])
    }
}
