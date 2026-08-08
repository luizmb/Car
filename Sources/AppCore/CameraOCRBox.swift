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
        let current = lock.withLock { session }
        guard let current else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: current)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    private func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.analysisQueue.async {
                let session = AVCaptureSession()
                session.sessionPreset = .hd1280x720
                guard
                    let camera = AVCaptureDevice.default(
                        .builtInWideAngleCamera, for: .video, position: .back
                    ),
                    let input = try? AVCaptureDeviceInput(device: camera),
                    session.canAddInput(input)
                else { return }
                session.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.analysisQueue)
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)

                self.lock.withLock { self.session = session }
                session.startRunning()
            }
        }
    }

    private func stop() {
        let current = lock.withLock { session }
        analysisQueue.async {
            current?.stopRunning()
        }
        lock.withLock { session = nil }
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
