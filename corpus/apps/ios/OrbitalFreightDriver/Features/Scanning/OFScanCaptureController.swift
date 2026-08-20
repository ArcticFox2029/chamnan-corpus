//
//  OFScanCaptureController.swift
//  OrbitalFreightDriver
//
//  Copyright (c) 2026 ORBITALFREIGHT. Uso interno.
//

import AVFoundation
import CoreLocation
import UIKit
import Vision
import os

/// Controla la cámara y convierte lo que ve en un contenedor identificado.
///
/// Lee dos cosas distintas que en el muelle van siempre juntas: el código BIC de once caracteres
/// pintado en la puerta del contenedor (reconocimiento de texto, porque muchos no llevan etiqueta) y
/// el código de barras del precinto. La validación del dígito de control del BIC no está aquí: se
/// delega en `OFLegacyContainerCodeValidator`, el módulo de Objective-C que arrastramos desde la
/// primera versión y que sigue siendo el que mejor tolera las lecturas sucias.
public final class OFScanCaptureController: NSObject {

    /// Resultado de una lectura aceptada.
    public struct Capture: Sendable {
        /// Código BIC normalizado, once caracteres, ya con dígito de control verificado.
        public let isoCode: String
        /// Número de precinto, si se leyó en la misma sesión.
        public let sealNumber: String?
        /// Posición del terminal en el momento de la lectura. Va a `position` del escaneo, y de ahí
        /// al payload de `shipment.scanned`.
        public let position: OFGeoPoint?
        /// Reloj del terminal en el instante de la lectura. Es el `occurred_at` del escaneo y no
        /// se recalcula al enviarlo, por muchas horas que pase en la cola.
        public let occurredAt: Date
        /// Confianza del reconocimiento, entre 0 y 1. Por debajo del umbral pedimos confirmación
        /// manual en vez de rechazar: un conductor bajo la lluvia prefiere confirmar a repetir.
        public let confidence: Float
    }

    public enum CaptureError: Error, Sendable {
        case cameraUnavailable
        case cameraPermissionDenied
        case checkDigitMismatch(read: String)
    }

    /// Se invoca en el hilo principal con cada lectura válida.
    public var onCapture: ((Capture) -> Void)?
    /// Se invoca cuando se lee algo que parece un BIC pero no cuadra el dígito de control.
    public var onRejected: ((CaptureError) -> Void)?

    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.orbitalfreight.driver.capture")
    private let locationProvider: OFLocationProvider
    private let log = Logger(subsystem: "com.orbitalfreight.driver", category: "scanner")

    private var lastAcceptedCode: String?
    private var lastAcceptedAt: Date = .distantPast
    private var pendingSealNumber: String?

    /// Ventana antirrebote. La cámara entrega treinta cuadros por segundo y el mismo contenedor
    /// aparece en todos; sin esto, un solo gesto del conductor generaba veinte escaneos idénticos
    /// y veinte entradas en la cola.
    private static let duplicateWindow: TimeInterval = 3.0

    public init(locationProvider: OFLocationProvider) {
        self.locationProvider = locationProvider
        super.init()
    }

    // MARK: - Sesión de captura

    /// Prepara la sesión de cámara.
    ///
    /// - Throws: `CaptureError.cameraPermissionDenied` si el conductor denegó el permiso, que en
    ///   este app es terminal: sin cámara no hay escaneo y no hay nada más que ofrecerle.
    public func configure() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .denied, .restricted: throw CaptureError.cameraPermissionDenied
        case .notDetermined: break
        @unknown default: break
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.cameraUnavailable
        }
        session.addInput(input)

        // Enfoque continuo con prioridad al centro: el conductor apunta al código desde metro y
        // medio y no va a mantener el pulso.
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.unlockForConfiguration()

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: videoQueue)
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }

        let metadata = AVCaptureMetadataOutput()
        if session.canAddOutput(metadata) {
            session.addOutput(metadata)
            metadata.setMetadataObjectsDelegate(self, queue: videoQueue)
            // Los precintos de la flota son Code 128; los de algunos transitarios, Code 39. QR no
            // se usa en ninguna terminal con la que trabajamos, y activarlo sólo servía para leer
            // carteles de la pared.
            metadata.metadataObjectTypes = [.code128, .code39]
        }

        session.commitConfiguration()
    }

    public func start() {
        videoQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    public func stop() {
        videoQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    public func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    // MARK: - Reconocimiento

    private func handleRecognizedText(_ observations: [VNRecognizedTextObservation]) {
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let normalized = candidate.string
                .uppercased()
                .filter { $0.isLetter || $0.isNumber }

            guard normalized.count == 11 else { continue }

            // El validador de Objective-C aplica el algoritmo de ISO 6346 completo. Aceptar el
            // código sin comprobarlo significaba mandar un `iso_code` inexistente a
            // `container-registry`, que devolvía `404` cuando el conductor ya estaba en la
            // siguiente puerta.
            guard OFLegacyContainerCodeValidator.isValidISO6346(normalized) else {
                log.debug("rejected BIC candidate with bad check digit")
                DispatchQueue.main.async { [weak self] in
                    self?.onRejected?(.checkDigitMismatch(read: normalized))
                }
                continue
            }

            emit(isoCode: normalized, confidence: candidate.confidence)
            return
        }
    }

    private func emit(isoCode: String, confidence: Float) {
        let now = Date()
        if isoCode == lastAcceptedCode, now.timeIntervalSince(lastAcceptedAt) < Self.duplicateWindow {
            return
        }
        lastAcceptedCode = isoCode
        lastAcceptedAt = now

        let capture = Capture(
            isoCode: isoCode,
            sealNumber: pendingSealNumber,
            position: locationProvider.currentPoint(),
            occurredAt: now,
            confidence: confidence
        )
        pendingSealNumber = nil

        log.info("captured container \(isoCode, privacy: .public) confidence=\(confidence)")
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(capture)
        }
    }
}

// MARK: - Vídeo

extension OFScanCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            self?.handleRecognizedText(observations)
        }
        // `.accurate` sobre un código de once caracteres en alto contraste no aporta nada y triplica
        // el consumo; medido en un iPhone 12 con el terminal en el salpicadero, `.fast` bastaba.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        // Los BIC no llevan minúsculas ni signos, así que restringimos el alfabeto para que el
        // reconocedor no proponga variantes imposibles.
        request.customWords = []

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
        try? handler.perform([request])
    }
}

// MARK: - Códigos de barras

extension OFScanCaptureController: AVCaptureMetadataOutputObjectsDelegate {

    public func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue else { continue }
            // El precinto se guarda a la espera del BIC: en la pareja envío-contenedor el número
            // de precinto pertenece al emparejamiento, no al contenedor suelto, así que no sirve
            // de nada mandarlo sin saber de qué contenedor hablamos.
            pendingSealNumber = OFLegacySealReader.normalizeSealNumber(value)
        }
    }
}

/// Fuente de posición para los escaneos. Se abstrae para poder inyectar una fija en las pruebas de
/// muelle, donde el GPS interior no sirve de nada.
public protocol OFLocationProvider: AnyObject, Sendable {
    /// Última posición conocida, o `nil` si no hay fijación reciente.
    ///
    /// Devolver `nil` es perfectamente válido: la columna `position` de
    /// `freight.shipment_scan_events` admite nulos, y un almacén cubierto es exactamente el caso
    /// para el que los admite.
    func currentPoint() -> OFGeoPoint?
}
