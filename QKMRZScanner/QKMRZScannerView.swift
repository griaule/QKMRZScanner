//
//  QKMRZScannerView.swift
//  QKMRZScanner
//
//  Created by Matej Dorcak on 03/10/2018.
//

import UIKit
import AVFoundation
import SwiftyTesseract
import QKMRZParser
import AudioToolbox
import Vision

public typealias QKMRZQuickResult = (passportNumber: String, birthDate: String, expiryDate: String)

public protocol QKMRZScannerViewDelegate: AnyObject {
    func mrzScannerView(_ mrzScannerView: QKMRZScannerView, didFind scanResult: QKMRZScanResult)
    func mrzScannerView(_ mrzScannerView: QKMRZScannerView, didFind quickResult: QKMRZQuickResult)
}

extension QKMRZScannerViewDelegate {
    func mrzScannerView(_ mrzScannerView: QKMRZScannerView, didFind scanResult: QKMRZScanResult) {}
}

@IBDesignable
public class QKMRZScannerView: UIView {
    fileprivate let tesseract = SwiftyTesseract(language: .custom("ocrb"), dataSource: Bundle(for: QKMRZScannerView.self), engineMode: .tesseractOnly)
    fileprivate let mrzParser = QKMRZParser(ocrCorrection: true)
    fileprivate let captureSession = AVCaptureSession()
    fileprivate let videoOutput = AVCaptureVideoDataOutput()
    fileprivate let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    fileprivate let cutoutView = QKCutoutView()
    fileprivate var currentCamera: AVCaptureDevice! = nil
    fileprivate var isScanningPaused = false
    fileprivate var observer: NSKeyValueObservation?
    @objc public dynamic var isScanning = false
    public var vibrateOnResult = true
    public weak var delegate: QKMRZScannerViewDelegate?
    
    public var cutoutRect: CGRect {
        return cutoutView.cutoutRect
    }
    
    fileprivate var interfaceOrientation: UIInterfaceOrientation {
        return UIApplication.shared.statusBarOrientation
    }
    
    fileprivate var mrzWeights: [Int] = [7, 3, 1]
    
    // MARK: Initializers
    override public init(frame: CGRect) {
        super.init(frame: frame)
        initialize()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        initialize()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: Overriden methods
    override public func prepareForInterfaceBuilder() {
        setViewStyle()
        addCutoutView()
    }
    
    override public func layoutSubviews() {
        super.layoutSubviews()
        adjustVideoPreviewLayerFrame()
    }
    
    // MARK: Scanning
    public func startScanning() {
        guard !captureSession.inputs.isEmpty else {
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async { [weak self] in self?.adjustVideoPreviewLayerFrame() }
        }
    }
    
    public func stopScanning() {
        captureSession.stopRunning()
    }
    
    fileprivate func recognizeVisionTextHandler(completion: @escaping (([String]) -> Void)) -> VNRequestCompletionHandler {
        return { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            let recognizedStrings = observations.compactMap { observation in
                return observation.topCandidates(1).first?.string
            }
            completion(recognizedStrings)
        }
    }
    
    fileprivate func recognizeVisionText(from cgImage: CGImage, completion: @escaping (([String]) -> Void)) {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage)
        let request = VNRecognizeTextRequest(completionHandler: self.recognizeVisionTextHandler(completion: completion))
        do {
            try requestHandler.perform([request])
        } catch {
            print("Unable to perform the requests: \(error).")
        }
    }
    
    // MARK: MRZ
    fileprivate func mrz(from cgImage: CGImage, preprocessing: Bool = false, completion: @escaping (([String], QKMRZResult?) -> Void)) {
        let img = preprocessing ? preprocessImage(cgImage) : cgImage
        self.recognizeVisionText(from: img) { recognizedText in
            let result = self.mrzParser.parse(mrzLines: recognizedText)
            completion(recognizedText, result)
        }
    }
    
    fileprivate func quickMRZ(from cgImage: CGImage, preprocessing: Bool = false, completion: @escaping (([String], QKMRZQuickResult?) -> Void)) {
        let img = preprocessing ? preprocessImage(cgImage) : cgImage
        self.recognizeVisionText(from: img) { recognizedText in
            for line in recognizedText.reversed() {
                if let result = self.parseQuickMRZ(secondLine: line) {
                    completion(recognizedText, result)
                    return
                }
            }
            completion(recognizedText, nil)
        }
    }
    
    public func parseQuickMRZ(secondLine: String) -> QKMRZQuickResult? {
        let str = secondLine
        let predicate = NSPredicate(format: "SELF MATCHES %@", "([A-Z0-9<]{9}[0-9][A-Z]{3}[0-9]{6}[0-9][MFX<][0-9]{6}[0-9][A-Z0-9<]{14}[0-9<][0-9])")
        
        guard predicate.evaluate(with: str),
              let passport = self.checkedSubstring(of: str, from: 0, to: 8)?.replacingOccurrences(of: "<", with: ""),
              let birthDate = self.checkedSubstring(of: str, from: 13, to: 18)?.replacingOccurrences(of: "<", with: ""),
              let expiryDate = self.checkedSubstring(of: str, from: 21, to: 26)?.replacingOccurrences(of: "<", with: "")
        else { return nil }
        
        let result = QKMRZQuickResult(passportNumber: passport, birthDate: birthDate, expiryDate: expiryDate)
        return result
    }
    
    fileprivate func charValue(char: Character) -> Int {
        if char == "<" {
            return  0
        }
        if let number = Int(String(char)), number < 10 {
            return number
        }
        guard let charValue = char.asciiValue else { return 0 }
        return Int(charValue) - 65 + 10
    }
    
    fileprivate func checkedSubstring(of str: String, from start: Int, to end: Int) -> String? {
        let sub = self.substring(of: str, from: start, to: end)
        guard let check = Int(self.substring(of: str, from: end + 1, to: end + 1)) else {
            return nil
        }
        
        var sum: Int = 0
        for (index, char) in sub.enumerated() {
            let value = self.charValue(char: char)
            let weight = self.mrzWeights[index % 3]
            sum += value * weight
        }
        
        return ((sum % 10) == check) ? sub : nil
    }
    
    fileprivate func substring(of str: String, from start: Int, to end: Int) -> String {
        return String(str[str.index(str.startIndex, offsetBy: start)...str.index(str.startIndex, offsetBy: end)])
    }
    
    fileprivate func mrzLines(from recognizedText: String) -> [String]? {
        let mrzString = recognizedText.replacingOccurrences(of: " ", with: "")
        var mrzLines = mrzString.components(separatedBy: "\n").filter({ !$0.isEmpty })
        
        // Remove garbage strings located at the beginning and at the end of the result
        if !mrzLines.isEmpty {
            let averageLineLength = (mrzLines.reduce(0, { $0 + $1.count }) / mrzLines.count)
            mrzLines = mrzLines.filter({ $0.count >= averageLineLength })
        }
        
        return mrzLines.isEmpty ? nil : mrzLines
    }
    
    // MARK: Document Image from Photo cropping
    fileprivate func cutoutRect(for cgImage: CGImage) -> CGRect {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let rect = videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: cutoutRect)
        let videoOrientation = videoPreviewLayer.connection!.videoOrientation
        
        if videoOrientation == .portrait || videoOrientation == .portraitUpsideDown {
            return CGRect(x: (rect.minY * imageWidth), y: (rect.minX * imageHeight), width: (rect.height * imageWidth), height: (rect.width * imageHeight))
        }
        else {
            return CGRect(x: (rect.minX * imageWidth), y: (rect.minY * imageHeight), width: (rect.width * imageWidth), height: (rect.height * imageHeight))
        }
    }
    
    fileprivate func documentImage(from cgImage: CGImage) -> CGImage {
        let croppingRect = cutoutRect(for: cgImage)
        return cgImage.cropping(to: croppingRect) ?? cgImage
    }
    
    fileprivate func enlargedDocumentImage(from cgImage: CGImage) -> UIImage {
        var croppingRect = cutoutRect(for: cgImage)
        let margin = (0.05 * croppingRect.height) // 5% of the height
        croppingRect = CGRect(x: (croppingRect.minX - margin), y: (croppingRect.minY - margin), width: croppingRect.width + (margin * 2), height: croppingRect.height + (margin * 2))
        return UIImage(cgImage: cgImage.cropping(to: croppingRect)!)
    }
    
    // MARK: UIApplication Observers
    @objc fileprivate func appWillEnterForeground() {
        if isScanningPaused {
            isScanningPaused = false
            startScanning()
        }
    }
    
    @objc fileprivate func appDidEnterBackground() {
        if isScanning {
            isScanningPaused = true
            stopScanning()
        }
    }
    
    // MARK: Init methods
    fileprivate func initialize() {
        FilterVendor.registerFilters()
        setViewStyle()
        addCutoutView()
        initCaptureSession()
        addAppObservers()
    }
    
    fileprivate func setViewStyle() {
        backgroundColor = .black
    }
    
    fileprivate func addCutoutView() {
        cutoutView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cutoutView)
        
        NSLayoutConstraint.activate([
            cutoutView.topAnchor.constraint(equalTo: topAnchor),
            cutoutView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cutoutView.leftAnchor.constraint(equalTo: leftAnchor),
            cutoutView.rightAnchor.constraint(equalTo: rightAnchor)
        ])
    }
    
    fileprivate func initCaptureSession() {
        captureSession.sessionPreset = .hd1920x1080
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("Camera not accessible")
            return
        }
        self.currentCamera = camera
        
        guard let deviceInput = try? AVCaptureDeviceInput(device: camera) else {
            print("Capture input could not be initialized")
            return
        }
        
        observer = captureSession.observe(\.isRunning, options: [.new]) { [unowned self] (model, change) in
            // CaptureSession is started from the global queue (background). Change the `isScanning` on the main
            // queue to avoid triggering the change handler also from the global queue as it may affect the UI.
            DispatchQueue.main.async { [weak self] in self?.isScanning = change.newValue! }
        }
        
        if captureSession.canAddInput(deviceInput) && captureSession.canAddOutput(videoOutput) {
            captureSession.addInput(deviceInput)
            captureSession.addOutput(videoOutput)
            
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "video_frames_queue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem))
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as [String : Any]
            videoOutput.connection(with: .video)!.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
            
            videoPreviewLayer.session = captureSession
            videoPreviewLayer.videoGravity = .resizeAspectFill
            
            layer.insertSublayer(videoPreviewLayer, at: 0)
        }
        else {
            print("Input & Output could not be added to the session")
        }
    }
    
    fileprivate func addAppObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    // MARK: Misc
    fileprivate func adjustVideoPreviewLayerFrame() {
        videoOutput.connection(with: .video)?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.connection?.videoOrientation = AVCaptureVideoOrientation(orientation: interfaceOrientation)
        videoPreviewLayer.frame = bounds
        self.updateFocus()
    }
    
    fileprivate func updateFocus() {
        DispatchQueue.main.async {
            self.focus(at: self.cutoutView.cutoutRelativeCenter)
        }
    }
    
    fileprivate func focus(at point: CGPoint) {
        if let device = self.currentCamera {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported == true {
                    device.focusPointOfInterest = point
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            }
            catch {
                print("Error while setting device focus: \(error)")
            }
        } else {
            print("No camera for focus updating")
        }
    }
    
    fileprivate func preprocessImage(_ image: CGImage) -> CGImage {
        var inputImage = CIImage(cgImage: image)
        let averageLuminance = inputImage.averageLuminance
        var exposure = 0.5
        let threshold = (1 - pow(1 - averageLuminance, 0.2))
        
        if averageLuminance > 0.8 {
            exposure -= ((averageLuminance - 0.5) * 2)
        }
        
        if averageLuminance < 0.35 {
            exposure += pow(2, (0.5 - averageLuminance))
        }
        
        inputImage = inputImage.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
                               .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2])
                               .applyingFilter("LuminanceThresholdFilter", parameters: ["inputThreshold": threshold])
        
        return CIContext.shared.createCGImage(inputImage, from: inputImage.extent)!
    }
    
    var finished: Bool = false
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension QKMRZScannerView: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cgImage = CMSampleBufferGetImageBuffer(sampleBuffer)?.cgImage else {
            return
        }
        self.updateFocus()
        
        let documentImage = self.documentImage(from: cgImage)
        let imageRequestHandler = VNImageRequestHandler(cgImage: documentImage, options: [:])
        
        let detectTextRectangles = VNDetectTextRectanglesRequest { [unowned self] request, error in
            guard error == nil else {
                return
            }
            
            guard let results = request.results as? [VNTextObservation] else {
                return
            }
            
            let imageWidth = CGFloat(documentImage.width)
            let imageHeight = CGFloat(documentImage.height)
            let transform = CGAffineTransform.identity.scaledBy(x: imageWidth, y: -imageHeight).translatedBy(x: 0, y: -1)
            let mrzTextRectangles = results.map({ $0.boundingBox.applying(transform) }).filter({ $0.width > (imageWidth * 0.8) })
            let mrzRegionRect = mrzTextRectangles.reduce(into: CGRect.null, { $0 = $0.union($1) })
            
            if let mrzTextImage = documentImage.cropping(to: mrzRegionRect) {
                self.quickMRZ(from: mrzTextImage) { lines, result in
                    //let text = lines.joined(separator: "\n")
                    if let mrzResult = result {
                        guard !self.finished else { return }
                        self.finished = true
                        self.stopScanning()

                        DispatchQueue.main.async {
                            self.delegate?.mrzScannerView(self, didFind: mrzResult)
                            if self.vibrateOnResult {
                                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                            }
                        }
                    }
                }
            }
        }
        
        try? imageRequestHandler.perform([detectTextRectangles])
    }
}
