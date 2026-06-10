import ARKit

extension FlutterArkitView {
    func initalize(_ arguments: [String: Any], _: FlutterResult) {
        if let showStatistics = arguments["showStatistics"] as? Bool {
            sceneView.showsStatistics = showStatistics
        }

        if let autoenablesDefaultLighting = arguments["autoenablesDefaultLighting"] as? Bool {
            sceneView.autoenablesDefaultLighting = autoenablesDefaultLighting
        }

        if let forceUserTapOnCenter = arguments["forceUserTapOnCenter"] as? Bool {
            forceTapOnCenter = forceUserTapOnCenter
        }

        initalizeGesutreRecognizers(arguments)

        sceneView.debugOptions = parseDebugOptions(arguments)
        
        // Check for large sets of images to detect (World Tracking) or track (Image Tracking)
        let detectionImages = arguments["detectionImages"] as? [[String: Any]] ?? []
        let trackingImages = arguments["trackingImages"] as? [[String: Any]] ?? []
        
        let (allImages, key) = !detectionImages.isEmpty
            ? (detectionImages, "detectionImages")
            : (trackingImages, "trackingImages")

        let imageNames = allImages.compactMap { $0["name"] as? String }
        prefetchImagesIfNeeded(imageNames) { [weak self] in
            guard let self = self else { return }
            if allImages.count > 100 {
                let imageBatches = stride(from: 0, to: allImages.count, by: 100).map {
                    Array(allImages[$0..<min($0 + 100, allImages.count)])
                }
                self.runImageDetectionBatches(
                    baseArguments: arguments,
                    imageKey: key,
                    imageBatches: imageBatches,
                    sendInitialized: true
                )
            } else {
                self.runConfiguration(arguments, sendInitialized: true)
            }
        }
    }
    
    private func runConfiguration(_ arguments: [String: Any], sendInitialized: Bool) {
        guard !isDisposed else { return }
        
        configuration = parseConfiguration(arguments)
        
        guard let config = configuration else {
            logPluginError("Failed to create ARConfiguration", toChannel: channel)
            return
        }
        
        // Do NOT use .removeExistingAnchors to preserve the world state
        sceneView.session.run(config)
        
        if sendInitialized {
            sendToFlutter("onInitialized", arguments: nil)
        }
    }
    
    private func runImageDetectionBatches(
        baseArguments: [String: Any],
        imageKey: String,
        imageBatches: [[Any]],
        batchIndex: Int = 0,
        sendInitialized: Bool = false
    ) {
        guard !isDisposed else { return }
        
        var arguments = baseArguments
        arguments[imageKey] = imageBatches[batchIndex]
        
        runConfiguration(arguments, sendInitialized: sendInitialized)
        
        // Schedule next batch rotation
        let nextIndex = (batchIndex + 1) % imageBatches.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runImageDetectionBatches(
                baseArguments: baseArguments,
                imageKey: imageKey,
                imageBatches: imageBatches,
                batchIndex: nextIndex
            )
        }
    }

    func parseDebugOptions(_ arguments: [String: Any]) -> SCNDebugOptions {
        var options = ARSCNDebugOptions().rawValue
        if arguments["showFeaturePoints"] as? Bool == true {
            options |= ARSCNDebugOptions.showFeaturePoints.rawValue
        }
        if arguments["showWorldOrigin"] as? Bool == true {
            options |= ARSCNDebugOptions.showWorldOrigin.rawValue
        }
        return ARSCNDebugOptions(rawValue: options)
    }

    func parseConfiguration(_ arguments: [String: Any]) -> ARConfiguration? {
        let configurationType = arguments["configuration"] as! Int
        var configuration: ARConfiguration?

        switch configurationType {
        case 0:
            configuration = createWorldTrackingConfiguration(arguments)
        case 1:
            #if !DISABLE_TRUEDEPTH_API
                configuration = createFaceTrackingConfiguration(arguments)
            #else
                logPluginError("TRUEDEPTH_API disabled", toChannel: channel)
            #endif
        case 2:
            if #available(iOS 12.0, *) {
                configuration = createImageTrackingConfiguration(arguments)
            } else {
                logPluginError("configuration is not supported on this device", toChannel: channel)
            }
        case 3:
            if #available(iOS 13.0, *) {
                configuration = createBodyTrackingConfiguration(arguments)
            } else {
                logPluginError("configuration is not supported on this device", toChannel: channel)
            }
        case 4:
            if #available(iOS 14.0, *) {
                configuration = createDepthTrackingConfiguration(arguments)
            } else {
                logPluginError("configuration is not supported on this device", toChannel: channel)
            }
        default:
            break
        }
        configuration?.worldAlignment = parseWorldAlignment(arguments)
        return configuration
    }

    func parseWorldAlignment(_ arguments: [String: Any]) -> ARConfiguration.WorldAlignment {
        switch arguments["worldAlignment"] as? Int {
        case 0: return .gravity
        case 1: return .gravityAndHeading
        default: return .camera
        }
    }
}
