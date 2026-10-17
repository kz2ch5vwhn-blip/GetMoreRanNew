//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CryptoKit
import StosSign_API
import StosSign_Auth
import StosSign_Common

final class AnisetteDataHelper
{
    var socket: URLSessionWebSocketTask?
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    
    var mdLu: String?
    var deviceId: String?
    
    var menuAnisetteURL: String?
    
    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    
    var loggingFunc: ((String)->Void)?
    
    func resetClientInfo() {
        clientInfo = nil
        userAgent = nil
        mdLu = nil
        deviceId = nil
    }
    
    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData
    {
        self.url = AnisetteSettings.serverURL
        
        if url == nil {
            throw "No Anisette Server Found!"
        }
        
        self.printOut("Anisette URL: \(self.url!.absoluteString)")
        
        // Ensure identity resolution executes before any check or token fetching
        await self.resolveIdentity()
        
        let ans : AnisetteData
        if let identifier = Keychain.shared.identifier,
           let adiPb = Keychain.shared.adiPb, !refresh {
            do {
                ans = try await self.fetchAnisetteV3(identifier, adiPb)
                return ans
            } catch {
                self.printOut("Cached Anisette V3 failed with error: \(error). Re-provisioning...")
                Keychain.shared.adiPb = nil
                ans = try await self.provision()
                return ans
            }
        } else {
            ans = try await self.provision()
        }
        return ans
    }
    
    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] {
            if v3 {
                if json["result"] == "GetHeadersError" {
                    let message = json["message"]
                    self.printOut("Error getting V3 headers: \(message ?? "no message")")
                    if let message = message,
                       message.contains("-45061") || message.contains("-80045") || message.contains("Code: 23") {
                        self.printOut("Error message indicates invalid provisioning state, resetting adi.pb and retrying")
                        Keychain.shared.adiPb = nil
                        return try await provision()
                    } else { throw message ?? "Unknown error" }
                }
            }
            
            var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
            if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
            if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
            if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
            
            if v3 {
                formattedJSON["deviceDescription"] = self.clientInfo!
                formattedJSON["localUserID"] = self.mdLu!
                formattedJSON["deviceUniqueIdentifier"] = self.deviceId!
                
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                let dateString = formatter.string(from: Date())
                self.printOut("Client time (UTC): \(dateString)")
                formattedJSON["date"] = dateString
                formattedJSON["locale"] = Locale.current.identifier
                formattedJSON["timeZone"] = TimeZone.current.abbreviation()
            } else {
                if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
                if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
                if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
                
                if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
                if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
                if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
            }
            
            if let response = response,
               let version = response.value(forHTTPHeaderField: "Implementation-Version") {
                self.printOut("Implementation-Version: \(version)")
            } else { self.printOut("No Implementation-Version header") }
            
            self.printOut("Anisette used: \(formattedJSON)")
            do {
                let jsonData = try JSONEncoder().encode(formattedJSON)
                let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
                self.printOut("Anisette is valid!")
                return anisette
            } catch {
                self.printOut("Anisette is invalid!!!!")
                throw "Invalid anisette (missing fields or serialization failure)"
            }
        } else {
            throw "Invalid anisette (response is not JSON)"
        }
    }
    
    // MARK: - V3: PROVISIONING
    
    func provision() async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Getting provisioning URLs")
        var request = self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString) {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.printOut("startProvisioningURL: \(self.startProvisioningURL!.absoluteString)")
            self.printOut("endProvisioningURL: \(self.endProvisioningURL!.absoluteString)")
            self.printOut("Starting a provisioning session")
            return try await self.startProvisioningSession()
        } else {
            self.printOut("Apple didn't give valid URLs! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid URLs. Please try again later"
        }
    }
    
    func startProvisioningSession() async throws -> AnisetteData {
        let provisioningSessionURL = self.webSocketURL(from: self.url!.appendingPathComponent("v3").appendingPathComponent("provisioning_session"))
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()
        try await self.receiveProvisioningMessages(from: socket)
        return try await self.fetchAnisetteV3(Keychain.shared.identifier!, Keychain.shared.adiPb!)
    }

    private func receiveProvisioningMessages(from socket: URLSessionWebSocketTask) async throws {
        self.printOut("Connected")
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket {
                self.socket = nil
            }
        }
        
        while true {
            let message = try await socket.receive()
            switch message {
            case .string(let string):
                if try await handleProvisioningMessage(string, socket: socket) {
                    return
                }
            case .data:
                throw "The server sent binary data instead of text"
            @unknown default:
                throw "The server sent an unknown WebSocket message"
            }
        }
    }
    
    private func handleProvisioningMessage(_ string: String, socket: URLSessionWebSocketTask) async throws -> Bool {
        guard let data = string.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw "The server didn't give valid JSON"
        }
        
        guard let result = json["result"] as? String else {
            self.printOut("The server didn't give us a result")
            throw "The server didn't give us a result"
        }
        
        self.printOut("Received result: \(result)")
        switch result {
        case "GiveIdentifier":
            self.printOut("Giving identifier")
            try await socket.sendJSON(["identifier": Keychain.shared.identifier!])
            
        case "GiveStartProvisioningData":
            self.printOut("Getting start provisioning data")
            let spim = try await self.fetchStartProvisioningData()
            self.printOut("Giving start provisioning data")
            try await socket.sendJSON(["spim": spim])
            
        case "GiveEndProvisioningData":
            self.printOut("Getting end provisioning data")
            guard let cpim = json["cpim"] as? String else {
                self.printOut("The server didn't give us a cpim")
                throw "The server didn't give us a cpim"
            }
            let endProvisioningData = try await self.fetchEndProvisioningData(cpim: cpim)
            self.printOut("Giving end provisioning data")
            try await socket.sendJSON(endProvisioningData)
            
        case "ProvisioningSuccess":
            self.printOut("Provisioning succeeded!")
            guard let adiPb = json["adi_pb"] as? String else {
                self.printOut("The server didn't give us an adi.pb file")
                throw "The server didn't give us an adi.pb file"
            }
            Keychain.shared.adiPb = adiPb
            return true
            
        default:
            if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                self.printOut("Failing because of \(result)")
                throw result + (json["message"] as? String ?? "")
            }
        }
        
        return false
    }
    
    private func fetchStartProvisioningData() async throws -> String {
        let body = [
            "Header": [String: Any](),
            "Request": [String: Any](),
        ]
        var request = self.buildAppleRequest(url: self.startProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let spim = plist["Response"]?["spim"] as? String {
            return spim
        } else {
            self.printOut("Apple didn't give valid start provisioning data!")
            throw "Apple didn't give valid start provisioning data. Please try again later"
        }
    }
    
    private func fetchEndProvisioningData(cpim: String) async throws -> [String: String] {
        let body = [
            "Header": [String: Any](),
            "Request": [
                "cpim": cpim,
            ],
        ]
        var request = self.buildAppleRequest(url: self.endProvisioningURL!)
        request.httpMethod = "POST"
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? Dictionary<String, Dictionary<String, Any>>,
           let ptm = plist["Response"]?["ptm"] as? String,
           let tk = plist["Response"]?["tk"] as? String {
            return ["ptm": ptm, "tk": tk]
        } else {
            self.printOut("Apple didn't give valid end provisioning data!")
            throw "Apple didn't give valid end provisioning data. Please try again later"
        }
    }
    
    private func webSocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        return components.url ?? url
    }
    
    func buildAppleRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(self.clientInfo!, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(self.userAgent!, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(self.mdLu!, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(self.deviceId!, forHTTPHeaderField: "X-Mme-Device-Id")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let dateString = formatter.string(from: Date())
        request.setValue(dateString, forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation(), forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
    
    // MARK: - V3: FETCHING
    
    func fetchClientInfo() async throws {
        if self.clientInfo == nil || self.userAgent == nil {
            await self.resolveIdentity()
        }
        
        if Keychain.shared.identifier == nil {
            self.printOut("Generating identifier")
            var bytes = [Int8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess {
                throw "Couldn't generate identifier"
            }
            Keychain.shared.identifier = Data(bytes: &bytes, count: bytes.count).base64EncodedString()
        }
        
        let decoded = Data(base64Encoded: Keychain.shared.identifier!)!
        self.mdLu = decoded.sha256().hexEncodedString()
        let uuid: UUID = decoded.object()
        self.deviceId = uuid.uuidString.uppercased()
    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Fetching anisette V3")
        var request = URLRequest(url: self.url!.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.httpBody = try! JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ], options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }
    
    // MARK: - Identity
    
    var identityOverride: AnisetteIdentity?
    
    func resolveIdentity() async {
        let identity: AnisetteIdentity
        
        if let forced = identityOverride {
            identity = forced
        } else {
            switch AnisetteSettings.mode {
            case .windows:
                identity = AnisetteIdentity.windows
            case .custom:
                let customInfo = AnisetteSettings.customClientInfo
                let customAgent = AnisetteSettings.customUserAgent
                if customInfo.isEmpty || customAgent.isEmpty {
                    identity = AnisetteIdentity.windows
                } else {
                    identity = AnisetteIdentity(clientInfo: customInfo, userAgent: customAgent)
                }
            case .auto:
                if let reported = await self.fetchServerIdentity() {
                    identity = reported
                } else {
                    identity = AnisetteIdentity.windows
                }
            }
        }
        
        self.clientInfo = identity.clientInfo
        self.userAgent = identity.userAgent
        
        let defaults = UserDefaults.standard
        defaults.set(identity.userAgent, forKey: AnisetteSettings.stosSignUserAgentKey)
        
        let fingerprint = "\(self.url?.absoluteString ?? "")|\(identity.clientInfo)|\(identity.userAgent)"
        let previous = defaults.string(forKey: AnisetteSettings.fingerprintKey)
        if previous != fingerprint {
            self.printOut("Anisette server or identity changed, clearing old provisioning data")
            Keychain.shared.adiPb = nil
            Keychain.shared.identifier = nil
            self.mdLu = nil
            self.deviceId = nil
            defaults.set(fingerprint, forKey: AnisetteSettings.fingerprintKey)
        }
    }
    
    func fetchServerIdentity() async -> AnisetteIdentity? {
        guard let baseURL = self.url else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("v3").appendingPathComponent("client_info"))
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let clientInfo = (json["client_info"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let userAgent = (json["user_agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clientInfo.isEmpty, !userAgent.isEmpty else {
                return nil
            }
            return AnisetteIdentity(clientInfo: clientInfo, userAgent: userAgent)
        } catch {
            return nil
        }
    }
    
    func testServer() async -> String {
        guard let serverURL = AnisetteSettings.serverURL else {
            return "The Anisette server URL is not valid."
        }
        self.url = serverURL
        if let identity = await self.fetchServerIdentity() {
            return "Server: \(serverURL.absoluteString)\n\nClient info:\n\(identity.clientInfo)\n\nUser agent:\n\(identity.userAgent)"
        }
        return "Server: \(serverURL.absoluteString)\n\nThe server did not report a client info / user agent. Windows identity will be used as fallback."
    }
    
    private func printOut(_ text: String?){
        if let text = text {
            print(text)
        }
    }
}

extension URLSessionWebSocketTask {
    func sendJSON(_ dictionary: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [])
        try await self.send(.string(String(data: data, encoding: .utf8)!))
    }
}

extension Data {
    func sha256() -> Data {
        Data(SHA256.hash(data: self))
    }
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    func object<T>() -> T { self.withUnsafeBytes { $0.load(as: T.self) } }
}

enum AnisetteIdentityMode: String, CaseIterable, Identifiable {
    case auto, windows, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto (from server)"
        case .windows: return "Windows (iTunes)"
        case .custom: return "Custom"
        }
    }
}

struct AnisetteIdentity: Equatable {
    var clientInfo: String
    var userAgent: String
    static let windows = AnisetteIdentity(
        clientInfo: "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>",
        userAgent: "akd/1.0 CFNetwork/808.1.4"
    )
}

enum AnisetteSettings {
    static let defaultServer = "https://mac-ani.jkcoxson.com"
    static let serverKey = "AnisetteServer"
    static let modeKey = "AnisetteIdentityMode"
    static let customClientInfoKey = "AnisetteCustomClientInfo"
    static let customUserAgentKey = "AnisetteCustomUserAgent"
    static let fingerprintKey = "AnisetteIdentityFingerprint"
    static let stosSignUserAgentKey = "GetMoreRam.GSAUserAgent"
    
    static var serverString: String {
        let stored = UserDefaults.standard.string(forKey: serverKey) ?? defaultServer
        var trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed.isEmpty ? defaultServer : trimmed
    }
    
    static var serverURL: URL? {
        return URL(string: serverString)
    }
}
