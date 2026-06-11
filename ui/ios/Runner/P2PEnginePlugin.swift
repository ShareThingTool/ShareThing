import Flutter
import UIKit
import P2p

// MARK: - P2PEnginePlugin

class P2PEnginePlugin: NSObject {
    fileprivate static var eventSink: FlutterEventSink?
    fileprivate static let pendingEventsLock = NSLock()
    fileprivate static var pendingEvents: [[String: Any]] = []
    fileprivate static let maxPending = 64

    static func register(messenger: any FlutterBinaryMessenger) {
        let m = messenger as! NSObject & FlutterBinaryMessenger

        let commandChannel = FlutterMethodChannel(name: "engine/commands", binaryMessenger: m)
        commandChannel.setMethodCallHandler { call, result in
            guard call.method == "commandJson", let payload = call.arguments as? String else {
                result(FlutterMethodNotImplemented)
                return
            }
            handleJsonCommand(payload: payload, result: result)
        }

        let eventChannel = FlutterEventChannel(name: "engine/events", binaryMessenger: m)
        eventChannel.setStreamHandler(EventStreamHandler())
    }

    static func emitEvent(_ payload: [String: Any]) {
        DispatchQueue.main.async {
            if let sink = eventSink {
                sink(payload)
            } else {
                pendingEventsLock.lock()
                if pendingEvents.count >= maxPending {
                    pendingEvents.removeFirst()
                }
                pendingEvents.append(payload)
                pendingEventsLock.unlock()
            }
        }
    }

    // MARK: - Command dispatch

    private static func handleJsonCommand(payload: String, result: @escaping FlutterResult) {
        guard
            let data = payload.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let type = json["type"] as? String
        else {
            result(FlutterError(code: "INVALID_JSON", message: "Invalid JSON payload", details: nil))
            return
        }

        switch type {
        case "START_NODE":
            let nickname = json["nickname"] as? String ?? ""
            let discoveryServersArr = json["discoveryServers"] as? [String] ?? []
            let relayAddrsArr = json["relayAddrs"] as? [String] ?? []
            let discoveryServers = discoveryServersArr.joined(separator: ";")
            let relayAddrs = relayAddrsArr.joined(separator: ";")

            result(nil)

            DispatchQueue.global(qos: .default).async {
                let docsDir = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first!.path
                P2pSetDataDir(docsDir)
                P2pSetPlatform("ios")
                P2pSetEventListener(IOSEventListener())

                let deviceIP = detectDeviceIP()
                var error: NSError?
                P2pStart(nickname, discoveryServers, relayAddrs, deviceIP, &error)
                if let error = error {
                    emitEvent(["type": "ERROR", "message": error.localizedDescription])
                }
                // NODE_STARTED is emitted by the Go engine via IOSEventListener
                // and also re-emitted by watchAddressChanges when relay addresses arrive

                // Register a VoIP keep-alive so iOS doesn't kill the node
                // when the app is backgrounded. Handler fires every ~10 minutes.
                UIApplication.shared.setKeepAliveTimeout(600) {
                    // Ping the engine to keep the process alive
                    _ = P2pGetId()
                }
            }

        case "STOP_NODE":
            P2pStop()
            P2pSetEventListener(nil)
            result(nil)

        case "SEND_FILE":
            let targetPeerId = json["targetPeerId"] as? String ?? ""
            let filePath = json["filePath"] as? String ?? ""
            let addrsArr = json["knownAddresses"] as? [String] ?? []
            let knownAddresses = addrsArr.joined(separator: ";")
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSError?
                P2pSendFile(targetPeerId, filePath, knownAddresses, &error)
                DispatchQueue.main.async {
                    if let error = error {
                        result(FlutterError(code: "SEND_FILE_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "ACCEPT_FILE":
            let transferId = json["transferId"] as? String ?? ""
            let savePath = json["savePath"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSError?
                P2pAcceptFile(transferId, savePath, &error)
                DispatchQueue.main.async {
                    if let error = error {
                        result(FlutterError(code: "ACCEPT_FILE_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "REJECT_FILE":
            let transferId = json["transferId"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSError?
                P2pRejectFile(transferId, &error)
                DispatchQueue.main.async {
                    if let error = error {
                        result(FlutterError(code: "REJECT_FILE_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "SEND_TEXT":
            let targetPeerId = json["targetPeerId"] as? String ?? ""
            let text = json["text"] as? String ?? ""
            let addrsArr = json["knownAddresses"] as? [String] ?? []
            let knownAddresses = addrsArr.joined(separator: ";")
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSError?
                P2pSendText(targetPeerId, text, knownAddresses, &error)
                DispatchQueue.main.async {
                    if let error = error {
                        result(FlutterError(code: "SEND_TEXT_FAILED", message: error.localizedDescription, details: nil))
                    } else {
                        result(nil)
                    }
                }
            }

        case "OPEN_FILE_LOCATION":
            result(nil)

        default:
            result(FlutterError(code: "UNKNOWN_COMMAND", message: type, details: nil))
        }
    }

    // MARK: - Device IP detection

    private static func detectDeviceIP() -> String {
        var address = ""
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "" }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let interface = current.pointee
            guard interface.ifa_addr != nil else { continue }
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addrLen = socklen_t(interface.ifa_addr.pointee.sa_len)
            if getnameinfo(interface.ifa_addr, addrLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !ip.isEmpty {
                    address = ip
                    break
                }
            }
        }
        return address
    }
}

// MARK: - Go EventListener bridge

class IOSEventListener: NSObject, P2pEventListenerProtocol {
    func onEvent(_ eventJson: String?) {
        guard
            let eventJson,
            let data = eventJson.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        P2PEnginePlugin.emitEvent(json)
    }
}

// MARK: - FlutterStreamHandler

class EventStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        P2PEnginePlugin.eventSink = events
        P2PEnginePlugin.pendingEventsLock.lock()
        let buffered = P2PEnginePlugin.pendingEvents
        P2PEnginePlugin.pendingEvents.removeAll()
        P2PEnginePlugin.pendingEventsLock.unlock()
        for event in buffered {
            events(event)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        P2PEnginePlugin.eventSink = nil
        return nil
    }
}
